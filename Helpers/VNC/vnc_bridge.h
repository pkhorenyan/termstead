#ifndef TERMSTEAD_VNC_BRIDGE_H
#define TERMSTEAD_VNC_BRIDGE_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
typedef struct tsv_session tsv_session;
typedef struct {
    void *context;
    bool (*resize)(void *, int, int);
    void (*pixels)(void *, const uint8_t *, int, int, int, int, int);
    void (*frame)(void *);
    /* Revision is the app's pasteboard generation for an Apple request;
       -1 denotes a standard server-pushed clipboard message. */
    void (*clipboard)(void *, const char *, int, bool, int64_t);
    void (*cursor)(void *, const uint8_t *, int, int, int, int);
    bool (*certificate)(void *, const char *);
    void (*resize_support)(void *, bool);
    /* Called only on the worker, also while a partial message waits for data. */
    void (*input)(void *, tsv_session *);
    void (*files)(void *, const char *, int64_t);
    void (*file_message)(void *, const uint8_t *, size_t);
} tsv_callbacks;
/* Owns socket, including when initialization fails. All calls run on one thread. */
tsv_session *tsv_new(int socket, const char *host, const char *user, const char *password, bool allow_none,
                     bool view_only, bool clipboard, bool receive_clipboard, int quality,
                     bool require_tls, tsv_callbacks callbacks);
bool tsv_connect(tsv_session *);
/* Borrowed nonblocking pipe: the worker drains it; its owner writes on input. */
void tsv_set_wakeup(tsv_session *, int descriptor);
int tsv_poll(tsv_session *);
void tsv_key(tsv_session *, uint32_t keysym, bool down);
void tsv_pointer(tsv_session *, int x, int y, int buttons);
void tsv_resize(tsv_session *, int width, int height);
void tsv_clipboard(tsv_session *, const char *utf8, int utf8_length,
                   const char *latin1, int latin1_length);
void tsv_clipboard_focus(tsv_session *, bool active, int64_t revision, bool fetch);
bool tsv_is_apple(tsv_session *);
bool tsv_file_message(tsv_session *, const uint8_t *, size_t, bool sending);
void tsv_clipboard_files(tsv_session *, const char *urls, size_t length);
const char *tsv_error(tsv_session *);
int tsv_error_code(tsv_session *);
void tsv_free(tsv_session *);
#endif
