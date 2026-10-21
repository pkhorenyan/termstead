// A small C face on FreeRDP for the engine's Swift side. FreeRDP's own
// headers do not import into Swift cleanly (macros, attributes, opaque
// callback tables), so Swift sees only this: one session, plain values in,
// plain callbacks out.
#ifndef TERMSTEAD_RDP_BRIDGE_H
#define TERMSTEAD_RDP_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct tsr_session tsr_session;

/// A file or folder on the clipboard, either side's. `name` is relative to
/// where it was copied from, `/` between folders, UTF-8.
typedef struct {
	const char* name;
	/// UINT64_MAX when the server did not say.
	uint64_t size;
	bool directory;
	/// Seconds since 1970; 0 when unknown.
	int64_t modified;
} tsr_file;

/// Called on the session's own thread, the one running `tsr_run`.
typedef struct {
	void* user;
	/// A buffer for the desktop at this size, BGRA, `*stride` bytes a row.
	/// Asked for at login and on every resize; it must stay valid until the
	/// next call or the end of the session.
	uint8_t* (*surface)(void* user, uint32_t width, uint32_t height, uint32_t* stride);
	/// Drawing into the buffer is about to start, and has finished; `end`
	/// gets the rectangle that changed (width 0 when nothing did).
	void (*begin_paint)(void* user);
	void (*end_paint)(void* user, int32_t x, int32_t y, int32_t width, int32_t height);
	/// The certificate chain as PEM. Returns whether to go on.
	bool (*verify_certificate)(void* user, const char* pem, size_t length, const char* host,
	                           uint16_t port);
	/// Credentials the server wants and the session lacks. Fills the three
	/// with strings from malloc, or returns false to give up.
	bool (*authenticate)(void* user, const char* username, const char* domain, char** out_username,
	                     char** out_domain, char** out_password);
	void (*connected)(void* user);
	/// Text copied on the server, UTF-8. Called on a channel's thread.
	void (*clipboard)(void* user, const char* text);
	/// Files copied on the server, in its order: folders before what is in
	/// them. On a channel's thread; the list is valid during the call.
	void (*server_files)(void* user, const tsr_file* files, size_t count);
	/// The server pastes files this Mac offered, and wants `length` bytes of
	/// file `index` from `offset`. Answer with `tsr_file_data_reply` and the
	/// same `stream`, from any thread.
	void (*read_file)(void* user, uint32_t stream, uint32_t index, uint64_t offset, uint32_t length);
	/// What `tsr_request_file_data` asked for; NULL when the server refused.
	void (*file_data)(void* user, uint32_t stream, const uint8_t* data, size_t length);
	/// A pointer shape from the server, kept under `id` (from 1) until
	/// `pointer_free`: RGBA with straight alpha, in desktop pixels, and the
	/// hot spot in the same pixels.
	void (*pointer_new)(void* user, int32_t id, const uint8_t* rgba, uint32_t width,
	                    uint32_t height, uint32_t hot_x, uint32_t hot_y);
	void (*pointer_free)(void* user, int32_t id);
	/// The pointer to show: an id from `pointer_new`, 0 for the system's
	/// arrow, -1 for none.
	void (*pointer_set)(void* user, int32_t id);
} tsr_callbacks;

typedef struct {
	const char* host;
	uint16_t port;
	const char* username;
	const char* domain;
	const char* password;
	uint32_t width;
	uint32_t height;
	uint32_t desktop_scale;
	uint32_t keyboard_layout;
	bool clipboard;
	bool sound;
	/// Connected to the server already; the session takes it over.
	int socket;
} tsr_params;

tsr_session* tsr_new(const tsr_params* params, const tsr_callbacks* callbacks);
/// Logs in and runs the session until it ends. Returns an empty string when
/// it ended as asked, else why it ended; valid until `tsr_free`.
const char* tsr_run(tsr_session* session);
/// Ends `tsr_run` from any thread.
void tsr_stop(tsr_session* session);
/// FreeRDP's last error, once `tsr_run` has returned.
uint32_t tsr_last_error(tsr_session* session);
void tsr_free(tsr_session* session);

bool tsr_send_scancode(tsr_session* session, uint16_t scancode, bool extended, bool down);
bool tsr_send_unicode(tsr_session* session, uint16_t character, bool down);
bool tsr_send_sync(tsr_session* session, bool caps_lock);
bool tsr_send_mouse(tsr_session* session, uint16_t flags, uint16_t x, uint16_t y);
bool tsr_resize(tsr_session* session, uint32_t width, uint32_t height, uint32_t desktop_scale);
/// What was copied on this Mac, offered to the server: text (UTF-8, or
/// NULL) and files (`count` 0 for none). Names longer than Windows takes
/// fail the offer.
bool tsr_set_clipboard(tsr_session* session, const char* text, const tsr_file* files, size_t count);
/// An answer to `read_file`: the bytes read, or NULL when the file could not
/// be read.
void tsr_file_data_reply(tsr_session* session, uint32_t stream, const uint8_t* data, size_t length);
/// Asks the server for part of a file it copied, by its index in the list
/// `server_files` gave; `size_only` asks for its size instead (8 bytes,
/// little-endian). The answer comes to `file_data` with this `stream`.
bool tsr_request_file_data(tsr_session* session, uint32_t stream, uint32_t index, uint64_t offset,
                           uint32_t length, bool size_only);

#endif
