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
    void (*clipboard)(void *, const char *, int, bool);
} tsv_callbacks;
/* Owns socket, including when initialization fails. All calls run on one thread. */
tsv_session *tsv_new(int socket, const char *user, const char *password, bool allow_none,
                     bool view_only, bool clipboard, tsv_callbacks callbacks);
bool tsv_connect(tsv_session *);
int tsv_poll(tsv_session *);
void tsv_key(tsv_session *, uint32_t keysym, bool down);
void tsv_pointer(tsv_session *, int x, int y, int buttons);
void tsv_clipboard(tsv_session *, const char *utf8, int utf8_length,
                   const char *latin1, int latin1_length);
const char *tsv_error(tsv_session *);
int tsv_error_code(tsv_session *);
void tsv_free(tsv_session *);
#endif
