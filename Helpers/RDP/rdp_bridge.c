#include "rdp_bridge.h"
#include "rdp_log.h"

// FreeRDP's headers warn about their own deprecated types and more; that is
// theirs to fix, and must not break a build that allows no warnings.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <freerdp/channels/disp.h>
#include <freerdp/client.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/codec/color.h>
#include <freerdp/event.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/transport_io.h>
#include <freerdp/utils/cliprdr_utils.h>
#include <winpr/shell.h>
#include <winpr/string.h>
#include <winpr/synch.h>
#include <winpr/user.h>
#include <winpr/wlog.h>
#pragma clang diagnostic pop

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static BOOL tsr_log(const wLogMessage* message)
{
	tsr_log_line(message->Level >= WLOG_ERROR, message->FunctionName, message->TextString);
	return TRUE;
}

struct tsr_session {
	tsr_callbacks callbacks;
	rdpContext* context;
	int socket;
	/// The channels, and what is on offer through the clipboard one. Used
	/// from XPC's queues and dropped on the session's thread as it ends, so
	/// both happen under `channel_lock`: a channel used just as the session
	/// ended was used after it was freed.
	pthread_mutex_t channel_lock;
	DispClientContext* disp;
	CliprdrClientContext* cliprdr;
	char* local_text;
	FILEDESCRIPTORW* local_files;
	uint32_t local_file_count;
	/// The server's id for its file list format, and which format the
	/// data asked for last is: a data response does not say. On the
	/// clipboard channel's thread only.
	UINT32 server_file_format;
	UINT32 pending_format;
	/// Copied again before the answer to the last request came: that answer
	/// belongs to the copy before, and `next_format` (0 for none) is asked
	/// for once it is in. Taken as this copy's, a file list became text.
	bool pending_stale;
	UINT32 next_format;
	char* reason;
	/// The last pointer id given out; on the session's thread only.
	int32_t last_pointer;
	volatile bool stopping;
};

typedef struct {
	rdpClientContext common;
	tsr_session* session;
} tsrContext;

static tsr_session* session_of(rdpContext* context)
{
	return ((tsrContext*)context)->session;
}

// MARK: - Connection

/// FreeRDP connects by calling this; the socket is the app's, opened
/// directly or to an ssh tunnel. FreeRDP closes what it is given, so it
/// gets a copy.
static int tsr_tcp_connect(rdpContext* context, rdpSettings* settings, const char* hostname,
                           int port, DWORD timeout)
{
	(void)settings;
	(void)hostname;
	(void)port;
	(void)timeout;
	tsr_session* session = session_of(context);
	return session->socket >= 0 ? dup(session->socket) : -1;
}

static int tsr_verify_x509(freerdp* instance, const BYTE* data, size_t length, const char* hostname,
                           UINT16 port, DWORD flags)
{
	(void)flags;
	tsr_session* session = session_of(instance->context);
	if (!session->callbacks.verify_certificate)
		return 0;
	// 2: for this session only. The app keeps its own record of what the
	// user trusted; FreeRDP's store is never written.
	return session->callbacks.verify_certificate(session->callbacks.user, (const char*)data, length,
	                                             hostname, port)
	           ? 2
	           : 0;
}

static char* nonempty(char* value)
{
	if (value && !value[0]) {
		free(value);
		return NULL;
	}
	return value;
}

/// Credentials still missing: the app asks the user, in the tab. Anything
/// but the desktop's own login (a gateway, a smartcard PIN) goes on without,
/// which this build does not support anyway.
static BOOL tsr_authenticate(freerdp* instance, char** username, char** password, char** domain,
                             rdp_auth_reason reason)
{
	tsr_session* session = session_of(instance->context);
	if ((reason != AUTH_NLA && reason != AUTH_TLS && reason != AUTH_RDP) ||
	    !session->callbacks.authenticate)
		return TRUE;
	char* user = NULL;
	char* realm = NULL;
	char* secret = NULL;
	if (!session->callbacks.authenticate(session->callbacks.user, *username, *domain, &user, &realm,
	                                     &secret))
		return FALSE;
	// Empty is none: an empty password would still be sent as one, and
	// xrdp then tries to log in with it instead of showing its own screen.
	free(*username);
	*username = nonempty(user);
	free(*domain);
	*domain = nonempty(realm);
	free(*password);
	*password = nonempty(secret);
	return TRUE;
}

// MARK: - Clipboard (MS-RDPECLIP), text only

/// The id this client gives its file list. Any registered format id does;
/// the server goes by the name.
#define TSR_FILE_FORMAT 0xC0F1
#define TSR_FILE_FORMAT_NAME "FileGroupDescriptorW"
/// Between 1601 and 1970, in seconds: FILETIME counts from 1601.
#define TSR_FILETIME_EPOCH 11644473600LL

/// What may be on offer: the general flags this client asks for. FreeRDP
/// keeps only what the server also has.
static const UINT32 tsr_clipboard_flags = CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED |
                                          CB_FILECLIP_NO_FILE_PATHS |
                                          CB_HUGE_FILE_SUPPORT_ENABLED;

/// Tells the server what this Mac's clipboard holds: files, text, both or
/// nothing.
static UINT tsr_send_format_list(CliprdrClientContext* cliprdr, bool text, bool files)
{
	CLIPRDR_FORMAT formats[2] = { 0 };
	UINT32 count = 0;
	if (files) {
		formats[count].formatId = TSR_FILE_FORMAT;
		formats[count].formatName = (char*)TSR_FILE_FORMAT_NAME;
		count++;
	}
	if (text) {
		formats[count].formatId = CF_UNICODETEXT;
		count++;
	}
	CLIPRDR_FORMAT_LIST list = { 0 };
	list.common.msgType = CB_FORMAT_LIST;
	list.numFormats = count;
	list.formats = count ? formats : NULL;
	return cliprdr->ClientFormatList(cliprdr, &list);
}

static UINT tsr_send_current_format_list(tsr_session* session, CliprdrClientContext* cliprdr)
{
	pthread_mutex_lock(&session->channel_lock);
	const bool text = session->local_text != NULL;
	const bool files = session->local_file_count > 0;
	pthread_mutex_unlock(&session->channel_lock);
	return tsr_send_format_list(cliprdr, text, files);
}

static UINT tsr_monitor_ready(CliprdrClientContext* cliprdr, const CLIPRDR_MONITOR_READY* ready)
{
	(void)ready;
	CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
	general.capabilitySetType = CB_CAPSTYPE_GENERAL;
	general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
	general.version = CB_CAPS_VERSION_2;
	general.generalFlags = tsr_clipboard_flags;
	CLIPRDR_CAPABILITIES capabilities = { 0 };
	capabilities.common.msgType = CB_CLIP_CAPS;
	capabilities.cCapabilitiesSets = 1;
	capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
	const UINT rc = cliprdr->ClientCapabilities(cliprdr, &capabilities);
	if (rc != CHANNEL_RC_OK)
		return rc;
	return tsr_send_current_format_list((tsr_session*)cliprdr->custom, cliprdr);
}

static UINT tsr_server_capabilities(CliprdrClientContext* cliprdr,
                                    const CLIPRDR_CAPABILITIES* capabilities)
{
	(void)cliprdr;
	(void)capabilities;
	return CHANNEL_RC_OK;
}

static UINT tsr_request_format(tsr_session* session, CliprdrClientContext* cliprdr, UINT32 format)
{
	session->pending_format = format;
	CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
	request.common.msgType = CB_FORMAT_DATA_REQUEST;
	request.requestedFormatId = format;
	return cliprdr->ClientFormatDataRequest(cliprdr, &request);
}

/// Something was copied on the server: take its files if it has any, else
/// its text. Files come with their names as text too, and the names are
/// not what the user wants pasted on the Mac.
static UINT tsr_server_format_list(CliprdrClientContext* cliprdr, const CLIPRDR_FORMAT_LIST* list)
{
	tsr_session* session = (tsr_session*)cliprdr->custom;
	CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
	response.common.msgType = CB_FORMAT_LIST_RESPONSE;
	response.common.msgFlags = CB_RESPONSE_OK;
	UINT rc = cliprdr->ClientFormatListResponse(cliprdr, &response);
	if (rc != CHANNEL_RC_OK)
		return rc;
	session->server_file_format = 0;
	bool text = false;
	for (UINT32 i = 0; i < list->numFormats; i++) {
		const CLIPRDR_FORMAT* format = &list->formats[i];
		if (format->formatId == CF_UNICODETEXT)
			text = true;
		else if (format->formatName && strcmp(format->formatName, TSR_FILE_FORMAT_NAME) == 0)
			session->server_file_format = format->formatId;
	}
	UINT32 wanted = 0;
	if (session->server_file_format && session->callbacks.server_files)
		wanted = session->server_file_format;
	else if (text)
		wanted = CF_UNICODETEXT;
	if (session->pending_format) {
		session->pending_stale = true;
		session->next_format = wanted;
		return CHANNEL_RC_OK;
	}
	return wanted ? tsr_request_format(session, cliprdr, wanted) : CHANNEL_RC_OK;
}

static UINT tsr_server_format_list_response(CliprdrClientContext* cliprdr,
                                            const CLIPRDR_FORMAT_LIST_RESPONSE* response)
{
	(void)cliprdr;
	(void)response;
	return CHANNEL_RC_OK;
}

/// The server's file list, as the app takes it: UTF-8 names, `/` between
/// folders.
static void tsr_hand_over_server_files(tsr_session* session, const BYTE* data, UINT32 length)
{
	FILEDESCRIPTORW* descriptors = NULL;
	UINT32 count = 0;
	if (cliprdr_parse_file_list(data, length, &descriptors, &count) != CHANNEL_RC_OK)
		return;
	tsr_file* files = calloc(count ? count : 1, sizeof(tsr_file));
	if (!files) {
		free(descriptors);
		return;
	}
	for (UINT32 i = 0; i < count; i++) {
		const FILEDESCRIPTORW* d = &descriptors[i];
		char* name = ConvertWCharNToUtf8Alloc(d->cFileName, ARRAYSIZE(d->cFileName), NULL);
		if (name) {
			for (char* c = name; *c; c++) {
				if (*c == '\\')
					*c = '/';
			}
		}
		files[i].name = name ? name : strdup("");
		files[i].directory = (d->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
		files[i].size = (d->dwFlags & FD_FILESIZE)
		                    ? ((uint64_t)d->nFileSizeHigh << 32) | d->nFileSizeLow
		                    : UINT64_MAX;
		if (d->dwFlags & FD_WRITESTIME) {
			const uint64_t ticks = ((uint64_t)d->ftLastWriteTime.dwHighDateTime << 32) |
			                       d->ftLastWriteTime.dwLowDateTime;
			files[i].modified = (int64_t)(ticks / 10000000ULL) - TSR_FILETIME_EPOCH;
		}
	}
	session->callbacks.server_files(session->callbacks.user, files, count);
	for (UINT32 i = 0; i < count; i++)
		free((char*)files[i].name);
	free(files);
	free(descriptors);
}

static UINT tsr_server_format_data_response(CliprdrClientContext* cliprdr,
                                            const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
	tsr_session* session = (tsr_session*)cliprdr->custom;
	const UINT32 format = session->pending_format;
	session->pending_format = 0;
	if (session->pending_stale) {
		session->pending_stale = false;
		const UINT32 next = session->next_format;
		session->next_format = 0;
		return next ? tsr_request_format(session, cliprdr, next) : CHANNEL_RC_OK;
	}
	if ((response->common.msgFlags & CB_RESPONSE_FAIL) || !response->requestedFormatData)
		return CHANNEL_RC_OK;
	if (format && format == session->server_file_format) {
		if (session->callbacks.server_files)
			tsr_hand_over_server_files(session, response->requestedFormatData,
			                           response->common.dataLen);
		return CHANNEL_RC_OK;
	}
	if (format != CF_UNICODETEXT || !session->callbacks.clipboard)
		return CHANNEL_RC_OK;
	const size_t units = response->common.dataLen / sizeof(WCHAR);
	char* text = ConvertWCharNToUtf8Alloc((const WCHAR*)response->requestedFormatData, units, NULL);
	if (text) {
		session->callbacks.clipboard(session->callbacks.user, text);
		free(text);
	}
	return CHANNEL_RC_OK;
}

/// The server pastes: it gets this Mac's text, NUL-terminated UTF-16, or
/// the list of its files.
static UINT tsr_server_format_data_request(CliprdrClientContext* cliprdr,
                                           const CLIPRDR_FORMAT_DATA_REQUEST* request)
{
	tsr_session* session = (tsr_session*)cliprdr->custom;
	CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
	response.common.msgType = CB_FORMAT_DATA_RESPONSE;
	response.common.msgFlags = CB_RESPONSE_FAIL;
	BYTE* data = NULL;
	UINT32 length = 0;
	pthread_mutex_lock(&session->channel_lock);
	if (request->requestedFormatId == CF_UNICODETEXT && session->local_text) {
		size_t units = 0;
		data = (BYTE*)ConvertUtf8ToWCharAlloc(session->local_text, &units);
		length = (UINT32)((units + 1) * sizeof(WCHAR));
	} else if (request->requestedFormatId == TSR_FILE_FORMAT && session->local_file_count > 0) {
		if (cliprdr_serialize_file_list_ex(tsr_clipboard_flags, session->local_files,
		                                   session->local_file_count, &data,
		                                   &length) != CHANNEL_RC_OK) {
			data = NULL;
		}
	}
	pthread_mutex_unlock(&session->channel_lock);
	if (data) {
		response.common.msgFlags = CB_RESPONSE_OK;
		response.common.dataLen = length;
		response.requestedFormatData = data;
	}
	const UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
	free(data);
	return rc;
}

static UINT tsr_send_file_contents(CliprdrClientContext* cliprdr, UINT32 stream, const BYTE* data,
                                   UINT32 length)
{
	CLIPRDR_FILE_CONTENTS_RESPONSE response = { 0 };
	response.common.msgType = CB_FILECONTENTS_RESPONSE;
	response.common.msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
	response.common.dataLen = 4 + (data ? length : 0);
	response.streamId = stream;
	response.cbRequested = data ? length : 0;
	response.requestedData = data;
	return cliprdr->ClientFileContentsResponse(cliprdr, &response);
}

/// The server pastes files: their sizes are known here, their contents
/// are the app's to read.
static UINT tsr_server_file_contents_request(CliprdrClientContext* cliprdr,
                                             const CLIPRDR_FILE_CONTENTS_REQUEST* request)
{
	tsr_session* session = (tsr_session*)cliprdr->custom;
	pthread_mutex_lock(&session->channel_lock);
	const bool known = request->listIndex < session->local_file_count;
	uint64_t size = 0;
	if (known) {
		const FILEDESCRIPTORW* d = &session->local_files[request->listIndex];
		size = ((uint64_t)d->nFileSizeHigh << 32) | d->nFileSizeLow;
	}
	pthread_mutex_unlock(&session->channel_lock);
	if (!known)
		return tsr_send_file_contents(cliprdr, request->streamId, NULL, 0);
	if (request->dwFlags & FILECONTENTS_SIZE) {
		BYTE bytes[8];
		for (int i = 0; i < 8; i++)
			bytes[i] = (BYTE)(size >> (8 * i));
		return tsr_send_file_contents(cliprdr, request->streamId, bytes, sizeof(bytes));
	}
	if (!session->callbacks.read_file)
		return tsr_send_file_contents(cliprdr, request->streamId, NULL, 0);
	const uint64_t offset = ((uint64_t)request->nPositionHigh << 32) | request->nPositionLow;
	session->callbacks.read_file(session->callbacks.user, request->streamId, request->listIndex,
	                             offset, request->cbRequested);
	return CHANNEL_RC_OK;
}

static UINT tsr_server_file_contents_response(CliprdrClientContext* cliprdr,
                                              const CLIPRDR_FILE_CONTENTS_RESPONSE* response)
{
	tsr_session* session = (tsr_session*)cliprdr->custom;
	if (session->callbacks.file_data) {
		const bool ok = !(response->common.msgFlags & CB_RESPONSE_FAIL);
		session->callbacks.file_data(session->callbacks.user, response->streamId,
		                             ok ? response->requestedData : NULL,
		                             ok ? response->cbRequested : 0);
	}
	return CHANNEL_RC_OK;
}

static void tsr_attach_clipboard(tsr_session* session, CliprdrClientContext* cliprdr)
{
	cliprdr->custom = session;
	cliprdr->MonitorReady = tsr_monitor_ready;
	cliprdr->ServerCapabilities = tsr_server_capabilities;
	cliprdr->ServerFormatList = tsr_server_format_list;
	cliprdr->ServerFormatListResponse = tsr_server_format_list_response;
	cliprdr->ServerFormatDataRequest = tsr_server_format_data_request;
	cliprdr->ServerFormatDataResponse = tsr_server_format_data_response;
	cliprdr->ServerFileContentsRequest = tsr_server_file_contents_request;
	cliprdr->ServerFileContentsResponse = tsr_server_file_contents_response;
	pthread_mutex_lock(&session->channel_lock);
	session->cliprdr = cliprdr;
	pthread_mutex_unlock(&session->channel_lock);
}

/// A file as the server's Explorer takes it. False for a name too long for
/// its 260 characters.
static bool tsr_describe(const tsr_file* file, FILEDESCRIPTORW* d)
{
	memset(d, 0, sizeof(*d));
	if (ConvertUtf8ToWChar(file->name, d->cFileName, ARRAYSIZE(d->cFileName)) < 0)
		return false;
	for (size_t i = 0; i < ARRAYSIZE(d->cFileName) && d->cFileName[i]; i++) {
		if (d->cFileName[i] == '/')
			d->cFileName[i] = '\\';
	}
	d->dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_WRITESTIME | FD_PROGRESSUI;
	d->dwFileAttributes = file->directory ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
	const uint64_t size = file->directory ? 0 : file->size;
	d->nFileSizeHigh = (DWORD)(size >> 32);
	d->nFileSizeLow = (DWORD)size;
	const uint64_t ticks = (uint64_t)(file->modified + TSR_FILETIME_EPOCH) * 10000000ULL;
	d->ftLastWriteTime.dwHighDateTime = (DWORD)(ticks >> 32);
	d->ftLastWriteTime.dwLowDateTime = (DWORD)ticks;
	return true;
}

bool tsr_set_clipboard(tsr_session* session, const char* text, const tsr_file* files, size_t count)
{
	FILEDESCRIPTORW* descriptors = NULL;
	if (count > 0) {
		descriptors = calloc(count, sizeof(FILEDESCRIPTORW));
		if (!descriptors)
			return false;
		for (size_t i = 0; i < count; i++) {
			if (!tsr_describe(&files[i], &descriptors[i])) {
				free(descriptors);
				return false;
			}
		}
	}
	pthread_mutex_lock(&session->channel_lock);
	free(session->local_text);
	session->local_text = text ? strdup(text) : NULL;
	free(session->local_files);
	session->local_files = descriptors;
	session->local_file_count = (uint32_t)count;
	if (session->cliprdr)
		(void)tsr_send_format_list(session->cliprdr, text != NULL, count > 0);
	pthread_mutex_unlock(&session->channel_lock);
	return true;
}

void tsr_file_data_reply(tsr_session* session, uint32_t stream, const uint8_t* data, size_t length)
{
	pthread_mutex_lock(&session->channel_lock);
	if (session->cliprdr)
		(void)tsr_send_file_contents(session->cliprdr, stream, data, (UINT32)length);
	pthread_mutex_unlock(&session->channel_lock);
}

bool tsr_request_file_data(tsr_session* session, uint32_t stream, uint32_t index, uint64_t offset,
                           uint32_t length, bool size_only)
{
	CLIPRDR_FILE_CONTENTS_REQUEST request = { 0 };
	request.common.msgType = CB_FILECONTENTS_REQUEST;
	request.streamId = stream;
	request.listIndex = index;
	request.dwFlags = size_only ? FILECONTENTS_SIZE : FILECONTENTS_RANGE;
	request.nPositionLow = size_only ? 0 : (UINT32)offset;
	request.nPositionHigh = size_only ? 0 : (UINT32)(offset >> 32);
	request.cbRequested = size_only ? 8 : length;
	pthread_mutex_lock(&session->channel_lock);
	const bool sent = session->cliprdr &&
	                  session->cliprdr->ClientFileContentsRequest(session->cliprdr, &request) ==
	                      CHANNEL_RC_OK;
	pthread_mutex_unlock(&session->channel_lock);
	return sent;
}

static void tsr_channel_connected(void* context, const ChannelConnectedEventArgs* e)
{
	tsr_session* session = session_of((rdpContext*)context);
	if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
		pthread_mutex_lock(&session->channel_lock);
		session->disp = (DispClientContext*)e->pInterface;
		pthread_mutex_unlock(&session->channel_lock);
	} else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
		tsr_attach_clipboard(session, (CliprdrClientContext*)e->pInterface);
	else
		freerdp_client_OnChannelConnectedEventHandler(context, e);
}

static void tsr_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e)
{
	tsr_session* session = session_of((rdpContext*)context);
	if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
		pthread_mutex_lock(&session->channel_lock);
		session->disp = NULL;
		pthread_mutex_unlock(&session->channel_lock);
	} else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
		pthread_mutex_lock(&session->channel_lock);
		session->cliprdr = NULL;
		pthread_mutex_unlock(&session->channel_lock);
	} else {
		freerdp_client_OnChannelDisconnectedEventHandler(context, e);
	}
}

// MARK: - Drawing

static BOOL tsr_begin_paint(rdpContext* context)
{
	tsr_session* session = session_of(context);
	HGDI_WND hwnd = context->gdi->primary->hdc->hwnd;
	if (hwnd) {
		hwnd->invalid->null = TRUE;
		hwnd->ninvalid = 0;
	}
	if (session->callbacks.begin_paint)
		session->callbacks.begin_paint(session->callbacks.user);
	return TRUE;
}

/// One rectangle around everything that changed: the app redraws a layer
/// region, and the parts in between cost less than a message each.
static BOOL tsr_end_paint(rdpContext* context)
{
	tsr_session* session = session_of(context);
	rdpGdi* gdi = context->gdi;
	HGDI_WND hwnd = gdi->primary->hdc->hwnd;
	int32_t left = 0, top = 0, right = 0, bottom = 0;
	if (hwnd && !hwnd->invalid->null && !gdi->suppressOutput) {
		for (INT32 i = 0; i < hwnd->ninvalid; i++) {
			const GDI_RGN* r = &hwnd->cinvalid[i];
			if (r->w <= 0 || r->h <= 0)
				continue;
			if (right == 0) {
				left = r->x;
				top = r->y;
				right = r->x + r->w;
				bottom = r->y + r->h;
			} else {
				left = r->x < left ? r->x : left;
				top = r->y < top ? r->y : top;
				right = r->x + r->w > right ? r->x + r->w : right;
				bottom = r->y + r->h > bottom ? r->y + r->h : bottom;
			}
		}
	}
	if (session->callbacks.end_paint)
		session->callbacks.end_paint(session->callbacks.user, left, top, right - left, bottom - top);
	return TRUE;
}

/// A buffer of the app's at the desktop's size, drawn into directly.
static BOOL tsr_attach_surface(rdpContext* context, BOOL resize)
{
	tsr_session* session = session_of(context);
	rdpSettings* settings = context->settings;
	const UINT32 width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
	const UINT32 height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
	uint32_t stride = 0;
	uint8_t* buffer = session->callbacks.surface(session->callbacks.user, width, height, &stride);
	if (!buffer)
		return FALSE;
	// No free function: the buffer belongs to the app's IOSurface.
	if (resize)
		return gdi_resize_ex(context->gdi, width, height, stride, PIXEL_FORMAT_BGRA32, buffer, NULL);
	return gdi_init_ex(context->instance, PIXEL_FORMAT_BGRA32, stride, buffer, NULL);
}

static BOOL tsr_desktop_resize(rdpContext* context)
{
	return tsr_attach_surface(context, TRUE);
}

// MARK: - Pointer

/// FreeRDP allocates every pointer at the prototype's size, so each one
/// carries the id the app knows it by.
typedef struct {
	rdpPointer pointer;
	int32_t id;
} tsrPointer;

static BOOL tsr_pointer_new(rdpContext* context, rdpPointer* pointer)
{
	tsr_session* session = session_of(context);
	tsrPointer* own = (tsrPointer*)pointer;
	own->id = 0;
	const UINT32 width = pointer->width;
	const UINT32 height = pointer->height;
	// Nothing to draw: shown as the system's arrow, id 0.
	if (!session->callbacks.pointer_new || width == 0 || height == 0)
		return TRUE;
	BYTE* rgba = calloc((size_t)width * height, 4);
	if (!rgba)
		return FALSE;
	const gdiPalette* palette = context->gdi ? &context->gdi->palette : NULL;
	if (!freerdp_image_copy_from_pointer_data(rgba, PIXEL_FORMAT_RGBA32, 0, 0, 0, width, height,
	                                          pointer->xorMaskData, pointer->lengthXorMask,
	                                          pointer->andMaskData, pointer->lengthAndMask,
	                                          pointer->xorBpp, palette)) {
		free(rgba);
		return FALSE;
	}
	own->id = ++session->last_pointer;
	session->callbacks.pointer_new(session->callbacks.user, own->id, rgba, width, height,
	                               pointer->xPos, pointer->yPos);
	free(rgba);
	return TRUE;
}

static void tsr_pointer_free(rdpContext* context, rdpPointer* pointer)
{
	tsr_session* session = session_of(context);
	const int32_t id = ((tsrPointer*)pointer)->id;
	if (id > 0 && session->callbacks.pointer_free)
		session->callbacks.pointer_free(session->callbacks.user, id);
}

static BOOL tsr_show_pointer(rdpContext* context, int32_t id)
{
	tsr_session* session = session_of(context);
	if (session->callbacks.pointer_set)
		session->callbacks.pointer_set(session->callbacks.user, id);
	return TRUE;
}

static BOOL tsr_pointer_set(rdpContext* context, rdpPointer* pointer)
{
	return tsr_show_pointer(context, ((tsrPointer*)pointer)->id);
}

static BOOL tsr_pointer_set_null(rdpContext* context)
{
	return tsr_show_pointer(context, -1);
}

static BOOL tsr_pointer_set_default(rdpContext* context)
{
	return tsr_show_pointer(context, 0);
}

/// The server moving the pointer is not followed: the mouse is the
/// user's, and a Mac pointer that jumps by itself would only startle.
static BOOL tsr_pointer_set_position(rdpContext* context, UINT32 x, UINT32 y)
{
	(void)context;
	(void)x;
	(void)y;
	return TRUE;
}

static void tsr_register_pointer(rdpContext* context)
{
	rdpPointer pointer = { 0 };
	pointer.size = sizeof(tsrPointer);
	pointer.New = tsr_pointer_new;
	pointer.Free = tsr_pointer_free;
	pointer.Set = tsr_pointer_set;
	pointer.SetNull = tsr_pointer_set_null;
	pointer.SetDefault = tsr_pointer_set_default;
	pointer.SetPosition = tsr_pointer_set_position;
	graphics_register_pointer(context->graphics, &pointer);
}

// MARK: - Lifecycle

static BOOL tsr_pre_connect(freerdp* instance)
{
	rdpContext* context = instance->context;
	if (!freerdp_settings_set_uint32(context->settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH) ||
	    !freerdp_settings_set_uint32(context->settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH))
		return FALSE;
	if (PubSub_SubscribeChannelConnected(context->pubSub, tsr_channel_connected) < 0 ||
	    PubSub_SubscribeChannelDisconnected(context->pubSub, tsr_channel_disconnected) < 0)
		return FALSE;
	return TRUE;
}

static BOOL tsr_post_connect(freerdp* instance)
{
	rdpContext* context = instance->context;
	if (!tsr_attach_surface(context, FALSE))
		return FALSE;
	tsr_register_pointer(context);
	context->update->BeginPaint = tsr_begin_paint;
	context->update->EndPaint = tsr_end_paint;
	context->update->DesktopResize = tsr_desktop_resize;
	tsr_session* session = session_of(context);
	if (session->callbacks.connected)
		session->callbacks.connected(session->callbacks.user);
	return TRUE;
}

static void tsr_post_disconnect(freerdp* instance)
{
	if (instance->context && instance->context->gdi)
		gdi_free(instance);
}

static BOOL tsr_client_new(freerdp* instance, rdpContext* context)
{
	(void)context;
	instance->PreConnect = tsr_pre_connect;
	instance->PostConnect = tsr_post_connect;
	instance->PostDisconnect = tsr_post_disconnect;
	instance->AuthenticateEx = tsr_authenticate;
	instance->VerifyX509Certificate = tsr_verify_x509;
	return TRUE;
}

static bool set_string(rdpSettings* settings, FreeRDP_Settings_Keys_String key, const char* value)
{
	return freerdp_settings_set_string(settings, key, value && value[0] ? value : NULL);
}

/// Warnings and errors to the unified log: an XPC service's stderr goes
/// nowhere, and the sandbox keeps the old syslog out.
/// `log show --predicate 'subsystem == "com.pavelkhorenyan.Termstead.rdp"'`
/// Once per process: the root log is shared, and two desktops starting
/// together each replaced its appender under the other, which crashed the
/// engine.
static void tsr_setup_log(void)
{
	wLog* root = WLog_GetRoot();
	if (WLog_SetLogAppenderType(root, WLOG_APPENDER_CALLBACK)) {
		wLogCallbacks forward = { 0 };
		forward.message = tsr_log;
		(void)WLog_ConfigureAppender(WLog_GetLogAppender(root), "callbacks", &forward);
	}
	WLog_SetLogLevel(root, WLOG_WARN);
}

tsr_session* tsr_new(const tsr_params* params, const tsr_callbacks* callbacks)
{
	static pthread_once_t log_once = PTHREAD_ONCE_INIT;
	pthread_once(&log_once, tsr_setup_log);

	tsr_session* session = calloc(1, sizeof(tsr_session));
	if (!session)
		return NULL;
	session->callbacks = *callbacks;
	session->socket = params->socket;
	// Recursive: a write that fails can close a dynamic channel on the
	// writing thread, which already holds the lock, and the channel's
	// disconnect handler takes it again.
	pthread_mutexattr_t recursive;
	pthread_mutexattr_init(&recursive);
	pthread_mutexattr_settype(&recursive, PTHREAD_MUTEX_RECURSIVE);
	pthread_mutex_init(&session->channel_lock, &recursive);
	pthread_mutexattr_destroy(&recursive);

	RDP_CLIENT_ENTRY_POINTS entry = { 0 };
	entry.Version = RDP_CLIENT_INTERFACE_VERSION;
	entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	entry.ContextSize = sizeof(tsrContext);
	entry.ClientNew = tsr_client_new;
	rdpContext* context = freerdp_client_context_new(&entry);
	if (!context) {
		free(session);
		return NULL;
	}
	((tsrContext*)context)->session = session;
	session->context = context;

	rdpSettings* settings = context->settings;
	const UINT32 scale = params->desktop_scale >= 100 ? params->desktop_scale : 100;
	// The device scale is one of 100, 140 or 180 (MS-RDPBCGR).
	const UINT32 device = scale >= 180 ? 180 : scale >= 140 ? 140 : 100;
	bool ok = set_string(settings, FreeRDP_ServerHostname, params->host) &&
	          freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, params->port) &&
	          set_string(settings, FreeRDP_Username, params->username) &&
	          set_string(settings, FreeRDP_Domain, params->domain) &&
	          set_string(settings, FreeRDP_Password, params->password) &&
	          freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, params->width) &&
	          freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, params->height) &&
	          freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, scale) &&
	          freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, device) &&
	          freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) &&
	          freerdp_settings_set_uint32(settings, FreeRDP_KeyboardLayout, params->keyboard_layout) &&
	          // The app decides on certificates: macOS's trust, or the user.
	          freerdp_settings_set_bool(settings, FreeRDP_ExternalCertificateManagement, TRUE) &&
	          // TLS or nothing. Legacy RDP security has no certificate to
	          // decide on: whoever answered would get the stored password.
	          // Off, it is also refused when a server picks it unasked.
	          freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
	          // A reconnect needs a new socket, which only the app can open.
	          freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, FALSE) &&
	          freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) &&
	          // No H.264 decoder in this build.
	          freerdp_settings_set_bool(settings, FreeRDP_GfxH264, FALSE) &&
	          freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, FALSE) &&
	          freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, FALSE) &&
	          freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE) &&
	          freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE) &&
	          freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE) &&
	          freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, params->clipboard);
	if (ok && params->sound) {
		const char* const sound[] = { "rdpsnd", "sys:mac" };
		ok = freerdp_client_add_static_channel(settings, ARRAYSIZE(sound), sound) &&
		     freerdp_client_add_dynamic_channel(settings, ARRAYSIZE(sound), sound);
	} else if (ok) {
		// Played nowhere: not here, and not on the server either.
		ok = freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE) &&
		     freerdp_settings_set_bool(settings, FreeRDP_RemoteConsoleAudio, FALSE);
	}

	rdpTransportIo io = *freerdp_get_io_callbacks(context);
	io.TCPConnect = tsr_tcp_connect;
	if (!ok || !freerdp_set_io_callbacks(context, &io)) {
		tsr_free(session);
		return NULL;
	}
	return session;
}

static void set_reason(tsr_session* session, const char* reason)
{
	free(session->reason);
	session->reason = strdup(reason ? reason : "");
}

const char* tsr_run(tsr_session* session)
{
	rdpContext* context = session->context;
	freerdp* instance = context->instance;
	if (!freerdp_connect(instance)) {
		set_reason(session, session->stopping ? ""
		                                      : freerdp_get_last_error_string(
		                                            freerdp_get_last_error(context)));
		return session->reason;
	}

	while (!freerdp_shall_disconnect_context(context)) {
		HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
		const DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
		if (count == 0)
			break;
		if (WaitForMultipleObjects(count, handles, FALSE, 100) == WAIT_FAILED)
			break;
		if (!freerdp_check_event_handles(context))
			break;
	}

	const UINT32 error = freerdp_get_last_error(context);
	if (session->stopping)
		set_reason(session, "");
	else if (error == FREERDP_ERROR_SUCCESS)
		set_reason(session, "The server closed the connection.");
	else
		set_reason(session, freerdp_get_last_error_string(error));
	freerdp_disconnect(instance);
	return session->reason;
}

void tsr_stop(tsr_session* session)
{
	session->stopping = true;
	freerdp_abort_connect_context(session->context);
}

uint32_t tsr_last_error(tsr_session* session)
{
	return freerdp_get_last_error(session->context);
}

void tsr_free(tsr_session* session)
{
	if (!session)
		return;
	if (session->context)
		freerdp_client_context_free(session->context);
	if (session->socket >= 0)
		close(session->socket);
	free(session->reason);
	free(session->local_text);
	free(session->local_files);
	pthread_mutex_destroy(&session->channel_lock);
	free(session);
}

// MARK: - Input

bool tsr_send_scancode(tsr_session* session, uint16_t scancode, bool extended, bool down)
{
	UINT16 flags = down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
	if (extended)
		flags |= KBD_FLAGS_EXTENDED;
	return freerdp_input_send_keyboard_event(session->context->input, flags, (UINT8)scancode);
}

bool tsr_send_unicode(tsr_session* session, uint16_t character, bool down)
{
	return freerdp_input_send_unicode_keyboard_event(session->context->input,
	                                                 down ? 0 : KBD_FLAGS_RELEASE, character);
}

bool tsr_send_sync(tsr_session* session, bool caps_lock)
{
	return freerdp_input_send_synchronize_event(session->context->input,
	                                            caps_lock ? KBD_SYNC_CAPS_LOCK : 0);
}

bool tsr_send_mouse(tsr_session* session, uint16_t flags, uint16_t x, uint16_t y)
{
	return freerdp_input_send_mouse_event(session->context->input, flags, x, y);
}

bool tsr_resize(tsr_session* session, uint32_t width, uint32_t height, uint32_t desktop_scale)
{
	DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
	layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
	// Even, and within what the protocol allows.
	layout.Width = (width < 200 ? 200 : width > 8192 ? 8192 : width) & ~1u;
	layout.Height = height < 200 ? 200 : height > 8192 ? 8192 : height;
	layout.Orientation = ORIENTATION_LANDSCAPE;
	layout.DesktopScaleFactor = desktop_scale >= 100 ? desktop_scale : 100;
	layout.DeviceScaleFactor = desktop_scale >= 180 ? 180 : desktop_scale >= 140 ? 140 : 100;
	pthread_mutex_lock(&session->channel_lock);
	const bool sent = session->disp &&
	                  session->disp->SendMonitorLayout(session->disp, 1, &layout) == CHANNEL_RC_OK;
	pthread_mutex_unlock(&session->channel_lock);
	return sent;
}
