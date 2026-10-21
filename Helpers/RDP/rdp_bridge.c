#include "rdp_bridge.h"
#include "rdp_log.h"

// FreeRDP's headers warn about their own deprecated types and more; that is
// theirs to fix, and must not break a build that allows no warnings.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <freerdp/channels/disp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/disp.h>
#include <freerdp/event.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/input.h>
#include <freerdp/transport_io.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#pragma clang diagnostic pop

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
	DispClientContext* disp;
	char* reason;
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

/// Credentials still missing: go on with what there is. A server that has
/// its own login screen (xrdp) shows it; one that needs NLA refuses, and
/// the app says so.
static BOOL tsr_authenticate(freerdp* instance, char** username, char** password, char** domain,
                             rdp_auth_reason reason)
{
	(void)instance;
	(void)username;
	(void)password;
	(void)domain;
	(void)reason;
	return TRUE;
}

static void tsr_channel_connected(void* context, const ChannelConnectedEventArgs* e)
{
	tsr_session* session = session_of((rdpContext*)context);
	if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
		session->disp = (DispClientContext*)e->pInterface;
	else
		freerdp_client_OnChannelConnectedEventHandler(context, e);
}

static void tsr_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e)
{
	tsr_session* session = session_of((rdpContext*)context);
	if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
		session->disp = NULL;
	else
		freerdp_client_OnChannelDisconnectedEventHandler(context, e);
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

tsr_session* tsr_new(const tsr_params* params, const tsr_callbacks* callbacks)
{
	// Warnings and errors to the unified log: an XPC service's stderr goes
	// nowhere, and the sandbox keeps the old syslog out.
	// `log show --predicate 'subsystem == "com.pavelkhorenyan.Termstead.rdp"'`
	wLog* root = WLog_GetRoot();
	if (WLog_SetLogAppenderType(root, WLOG_APPENDER_CALLBACK)) {
		wLogCallbacks forward = { 0 };
		forward.message = tsr_log;
		(void)WLog_ConfigureAppender(WLog_GetLogAppender(root), "callbacks", &forward);
	}
	WLog_SetLogLevel(root, WLOG_WARN);

	tsr_session* session = calloc(1, sizeof(tsr_session));
	if (!session)
		return NULL;
	session->callbacks = *callbacks;
	session->socket = params->socket;

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
	          // Until the clipboard is handled here, the channel stays away:
	          // a server waits on a client that never answers it.
	          freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, FALSE);
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

void tsr_free(tsr_session* session)
{
	if (!session)
		return;
	if (session->context)
		freerdp_client_context_free(session->context);
	if (session->socket >= 0)
		close(session->socket);
	free(session->reason);
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
	DispClientContext* disp = session->disp;
	if (!disp)
		return false;
	DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
	layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
	// Even, and within what the protocol allows.
	layout.Width = (width < 200 ? 200 : width > 8192 ? 8192 : width) & ~1u;
	layout.Height = height < 200 ? 200 : height > 8192 ? 8192 : height;
	layout.Orientation = ORIENTATION_LANDSCAPE;
	layout.DesktopScaleFactor = desktop_scale >= 100 ? desktop_scale : 100;
	layout.DeviceScaleFactor = desktop_scale >= 180 ? 180 : desktop_scale >= 140 ? 140 : 100;
	return disp->SendMonitorLayout(disp, 1, &layout) == CHANNEL_RC_OK;
}
