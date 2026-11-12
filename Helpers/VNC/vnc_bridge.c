#include "vnc_bridge.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#include <rfb/rfbclient.h>
#pragma clang diagnostic pop
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>

struct tsv_session {
    rfbClient *client;
    tsv_callbacks callbacks;
    char *user, *password;
    char error[1024];
    bool view_only, clipboard, needs_user;
};
static _Thread_local tsv_session *current;
static pthread_once_t log_once = PTHREAD_ONCE_INIT;
static char tag;

static void logger(const char *format, ...) {
    if (!current) return;
    va_list args;
    va_start(args, format);
    vsnprintf(current->error, sizeof(current->error), format, args);
    va_end(args);
}
static void setup_log(void) { rfbClientLog = logger; rfbClientErr = logger; }
static tsv_session *owner(rfbClient *client) { return rfbClientGetClientData(client, &tag); }
static char *password(rfbClient *client) { return strdup(owner(client)->password); }
static rfbCredential *credential(rfbClient *client, int type) {
    tsv_session *s = owner(client);
    if (type != rfbCredentialTypeUser || !s->user[0]) {
        s->needs_user = true;
        return NULL;
    }
    rfbCredential *result = calloc(1, sizeof(*result));
    if (!result) return NULL;
    result->userCredential.username = strdup(s->user);
    result->userCredential.password = strdup(s->password);
    return result;
}
static rfbBool resize(rfbClient *client) {
    tsv_session *s = owner(client);
    int w = client->width, h = client->height;
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192 || (size_t)w * h > 16777216) {
        snprintf(s->error, sizeof(s->error), "The VNC desktop exceeds the supported size (16 million pixels).");
        return FALSE;
    }
    uint8_t *buffer = calloc((size_t)w * h, 4);
    if (!buffer) return FALSE;
    free(client->frameBuffer);
    client->frameBuffer = buffer;
    return s->callbacks.resize(s->callbacks.context, w, h);
}
static void pixels(rfbClient *client, int x, int y, int w, int h) {
    tsv_session *s = owner(client);
    if (x < 0 || y < 0 || w < 0 || h < 0 || x > client->width - w || y > client->height - h) return;
    for (int row = y; row < y + h; ++row) {
        uint32_t *p = (uint32_t *)client->frameBuffer + (size_t)row * client->width + x;
        for (int col = 0; col < w; ++col) p[col] |= 0xff000000;
    }
    s->callbacks.pixels(s->callbacks.context, client->frameBuffer, client->width * 4, x, y, w, h);
}
static void frame(rfbClient *client) {
    tsv_session *s = owner(client);
    s->callbacks.frame(s->callbacks.context);
}
static void cursor(rfbClient *client, int hot_x, int hot_y, int width, int height, int bytes_per_pixel) {
    tsv_session *s = owner(client);
    if (width == 0 || height == 0) {
        s->callbacks.cursor(s->callbacks.context, NULL, 0, 0, 0, 0);
        return;
    }
    if (width < 0 || height < 0 || width > 1024 || height > 1024 || bytes_per_pixel != 4 ||
        !client->rcSource || !client->rcMask) return;
    size_t count = (size_t)width * height;
    uint8_t *rgba = malloc(count * 4);
    if (!rgba) return;
    for (size_t i = 0; i < count; ++i) {
        rgba[4 * i] = client->rcSource[4 * i + 2];
        rgba[4 * i + 1] = client->rcSource[4 * i + 1];
        rgba[4 * i + 2] = client->rcSource[4 * i];
        rgba[4 * i + 3] = client->rcMask[i] ? 255 : 0;
    }
    s->callbacks.cursor(s->callbacks.context, rgba, width, height, hot_x, hot_y);
    free(rgba);
}
static void cut_text(rfbClient *client, const char *text, int length) {
    tsv_session *s = owner(client);
    if (s->clipboard && length >= 0 && length <= 1048576)
        s->callbacks.clipboard(s->callbacks.context, text, length, false);
}
static void cut_utf8(rfbClient *client, const char *text, int length) {
    tsv_session *s = owner(client);
    /* Extended Clipboard text counts its trailing NUL in the payload. */
    if (length > 0 && text[length - 1] == '\0') --length;
    if (s->clipboard && length >= 0 && length <= 1048576)
        s->callbacks.clipboard(s->callbacks.context, text, length, true);
}
tsv_session *tsv_new(int socket, const char *user, const char *secret, bool allow_none,
                     bool view_only, bool clipboard, tsv_callbacks callbacks) {
    pthread_once(&log_once, setup_log);
    tsv_session *s = calloc(1, sizeof(*s));
    if (!s) { close(socket); return NULL; }
    current = s;
    s->callbacks = callbacks;
    s->view_only = view_only;
    s->clipboard = clipboard;
    s->user = strdup(user);
    s->password = strdup(secret);
    s->client = rfbGetClient(8, 3, 4);
    if (!s->client) { tsv_free(s); close(socket); return NULL; }
    rfbClient *c = s->client;
    rfbClientSetClientData(c, &tag, s);
    c->sock = socket;
    int no_sigpipe = 1;
    setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
    fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK);
    c->listenSpecified = TRUE;
    c->readTimeout = 15;
    c->appData.shareDesktop = TRUE;
    c->appData.viewOnly = view_only;
    c->appData.useRemoteCursor = TRUE; /* Shape from server, movement on the Mac. */
    c->GotCursorShape = cursor;
    c->appData.encodingsString = "zrle zlib hextile copyrect raw";
    c->format.redShift = 16; c->format.greenShift = 8; c->format.blueShift = 0;
    c->format.bigEndian = FALSE;
    c->GetPassword = password;
    c->GetCredential = credential;
    c->MallocFrameBuffer = resize;
    c->GotFrameBufferUpdate = pixels;
    c->FinishedFrameBufferUpdate = frame;
    c->GotXCutText = cut_text;
    c->GotXCutTextUTF8 = cut_utf8;
    c->canHandleNewFBSize = TRUE;
    /* TLS is deliberately not selected until certificate verification is
       integrated. Never silently accept anonymous TLS or an unverified cert. */
    uint32_t schemes[] = { rfbVncAuth, rfbARD, rfbNoAuth };
    SetClientAuthSchemes(c, schemes, allow_none ? 3 : 2);
    return s;
}
bool tsv_connect(tsv_session *s) {
    current = s;
    rfbClient *c = s->client;
    if (!InitialiseRFBConnection(c)) return false;
    c->width = c->si.framebufferWidth;
    c->height = c->si.framebufferHeight;
    if (!resize(c) || !SetFormatAndEncodings(c)) return false;
    c->updateRect.x = c->updateRect.y = 0;
    c->updateRect.w = c->width; c->updateRect.h = c->height;
    c->isUpdateRectManagedByLib = TRUE;
    return SendFramebufferUpdateRequest(c, 0, 0, c->width, c->height, FALSE);
}
int tsv_poll(tsv_session *s) {
    current = s;
    // ReadFromRFBServer reads ahead. Drain those bytes before select: a
    // complete update may already be buffered while the socket is idle.
    int result = s->client->buffered > 0 ? 1 : WaitForMessage(s->client, 10000);
    if (result <= 0) return result;
    return HandleRFBServerMessage(s->client) ? 1 : -1;
}
void tsv_key(tsv_session *s, uint32_t keysym, bool down) {
    if (!s->view_only) SendKeyEvent(s->client, keysym, down);
}
void tsv_pointer(tsv_session *s, int x, int y, int buttons) {
    if (!s->view_only) SendPointerEvent(s->client, x, y, buttons);
}
void tsv_clipboard(tsv_session *s, const char *utf8, int utf8_length, const char *latin1, int latin1_length) {
    if (!s->clipboard || s->view_only) return;
    if (!SendClientCutTextUTF8(s->client, (char *)utf8, utf8_length))
        SendClientCutText(s->client, (char *)latin1, latin1_length);
}
const char *tsv_error(tsv_session *s) { return s->error; }
int tsv_error_code(tsv_session *s) {
    if (s->needs_user) return 3;
    return strstr(s->error, "authentication failed") || strstr(s->error, "Authentication failed") ||
           strstr(s->error, "Authentication failure") ? 2 : 1;
}
void tsv_free(tsv_session *s) {
    if (!s) return;
    if (s->client) {
        free(s->client->frameBuffer);
        s->client->frameBuffer = NULL;
        rfbClientCleanup(s->client);
    }
    if (s->password) { memset(s->password, 0, strlen(s->password)); free(s->password); }
    free(s->user);
    if (current == s) current = NULL;
    free(s);
}
