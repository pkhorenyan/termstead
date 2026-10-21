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
/// Text copied on this Mac, UTF-8, offered to the server; NULL for none.
void tsr_set_clipboard(tsr_session* session, const char* text);

#endif
