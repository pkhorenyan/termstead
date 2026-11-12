#include "vnc_bridge.h"
#include "vnc_apple_clipboard.h"
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
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <time.h>
#include <sys/socket.h>
#include <openssl/ssl.h>
#include <openssl/provider.h>

struct tsv_session {
    rfbClient *client;
    tsv_callbacks callbacks;
    char *user, *password;
    char error[1024];
    bool view_only, clipboard, receive_clipboard, needs_user, certificate_rejected, resize_supported, dirty;
    uint8_t *display;
    int wake_descriptor;
    bool ready, handling_input;
    bool apple, clipboard_focused, fetch_pending, fetch_again, fetch_stale, apple_failed;
    int64_t clipboard_revision, requested_revision;
};
static _Thread_local tsv_session *current;
static pthread_once_t log_once = PTHREAD_ONCE_INIT;
static char tag;
static rfbBool apple_message(rfbClient *, rfbServerToClientMsg *);
static rfbClientProtocolExtension apple_extension = {.handleMessage = apple_message};

static void logger(const char *format, ...) {
    if (!current) return;
    va_list args;
    va_start(args, format);
    vsnprintf(current->error, sizeof(current->error), format, args);
    va_end(args);
}
static void setup_log(void) {
    rfbClientLog = logger; rfbClientErr = logger;
    rfbClientRegisterExtension(&apple_extension);
    /* Keep the default provider for this engine's lifetime. LibVNCClient's
       DES helpers explicitly load/unload providers, disabling OpenSSL's
       automatic fallback. Without a retained reference, TLS has no ciphers
       after the first classic VNC login in the same XPC process. */
    (void)OSSL_PROVIDER_load(NULL, "default");
}
static tsv_session *owner(rfbClient *client) { return rfbClientGetClientData(client, &tag); }
static char *password(rfbClient *client) { return strdup(owner(client)->password); }
static rfbCredential *credential(rfbClient *client, int type) {
    tsv_session *s = owner(client);
    if (type == rfbCredentialTypeX509) return calloc(1, sizeof(rfbCredential));
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
    free(s->display);
    s->display = calloc((size_t)w * h, 4);
    if (!s->display) return FALSE;
    return s->callbacks.resize(s->callbacks.context, w, h);
}
static uint8_t channel(uint32_t pixel, unsigned int shift, unsigned int maximum) {
    return (uint8_t)(((pixel >> shift) & maximum) * 255 / maximum);
}
static void pixels(rfbClient *client, int x, int y, int w, int h) {
    tsv_session *s = owner(client);
    if (x < 0 || y < 0 || w <= 0 || h <= 0 || x > client->width - w || y > client->height - h) return;
    for (int row = y; row < y + h; ++row) {
        uint32_t *p = (uint32_t *)client->frameBuffer + (size_t)row * client->width + x;
        uint8_t *out = s->display + ((size_t)row * client->width + x) * 4;
        if (client->format.redMax == 255 && client->format.greenMax == 255 && client->format.blueMax == 255) {
            uint32_t *destination = (uint32_t *)out;
            for (int col = 0; col < w; ++col) destination[col] = p[col] | 0xff000000;
            continue;
        }
        for (int col = 0; col < w; ++col) {
            out[col * 4] = channel(p[col], client->format.blueShift, client->format.blueMax);
            out[col * 4 + 1] = channel(p[col], client->format.greenShift, client->format.greenMax);
            out[col * 4 + 2] = channel(p[col], client->format.redShift, client->format.redMax);
            out[col * 4 + 3] = 255;
        }
    }
    s->callbacks.pixels(s->callbacks.context, s->display, client->width * 4, x, y, w, h);
    s->dirty = true;
}
static void frame(rfbClient *client) {
    tsv_session *s = owner(client);
    if (s->dirty) {
        s->dirty = false;
        s->callbacks.frame(s->callbacks.context);
    }
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
        uint32_t pixel;
        memcpy(&pixel, client->rcSource + 4 * i, 4);
        rgba[4 * i] = channel(pixel, client->format.redShift, client->format.redMax);
        rgba[4 * i + 1] = channel(pixel, client->format.greenShift, client->format.greenMax);
        rgba[4 * i + 2] = channel(pixel, client->format.blueShift, client->format.blueMax);
        rgba[4 * i + 3] = client->rcMask[i] ? 255 : 0;
    }
    s->callbacks.cursor(s->callbacks.context, rgba, width, height, hot_x, hot_y);
    free(rgba);
}
static void cut_text(rfbClient *client, const char *text, int length) {
    tsv_session *s = owner(client);
    if (s->receive_clipboard && length >= 0 && length <= 1048576)
        s->callbacks.clipboard(s->callbacks.context, text, length, false, -1);
}
static void cut_utf8(rfbClient *client, const char *text, int length) {
    tsv_session *s = owner(client);
    /* Extended Clipboard text counts its trailing NUL in the payload. */
    if (length > 0 && text[length - 1] == '\0') --length;
    if (s->receive_clipboard && length >= 0 && length <= 1048576)
        s->callbacks.clipboard(s->callbacks.context, text, length, true, -1);
}
static uint32_t apple_u32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static bool apple_write(tsv_session *s, const uint8_t *data, size_t length) {
    if (WriteToRFBServer(s->client, (const char *)data, (unsigned int)length)) return true;
    s->apple_failed = true;
    return false;
}
static void apple_fetch(tsv_session *s) {
    if (!s->apple || !s->receive_clipboard || !s->clipboard_focused || s->apple_failed) return;
    if (s->fetch_pending) { s->fetch_again = true; return; }
    s->fetch_pending = true; s->fetch_stale = false; s->fetch_again = false;
    s->requested_revision = s->clipboard_revision;
    /* Exactly eight bytes. A ninth byte would desynchronize the RFB stream. */
    const uint8_t fetch[8] = {0x0b};
    apple_write(s, fetch, sizeof(fetch));
}
void tsv_clipboard_focus(tsv_session *s, bool active, int64_t revision) {
    bool changed = s->clipboard_revision != revision;
    bool arrived = active && !s->clipboard_focused;
    s->clipboard_focused = active;
    s->clipboard_revision = revision;
    if (!active || changed) s->fetch_stale = true;
    if (arrived || (active && changed)) apple_fetch(s);
}
static rfbBool read_apple_message(rfbClient *client, rfbServerToClientMsg *message) {
    tsv_session *s = owner(client);
    if (!s || !s->apple) return FALSE;
    uint8_t header[16] = {message->type};
    if (message->type == 0x14) {
        if (!ReadFromRFBServer(client, (char *)header + 1, 3)) return FALSE;
        unsigned int length = (unsigned int)header[2] << 8 | header[3];
        uint8_t body[4096];
        if (length < 4 || length > sizeof(body) || !ReadFromRFBServer(client, (char *)body, length)) return FALSE;
        unsigned int command = (unsigned int)body[2] << 8 | body[3];
        if (command == 2) apple_fetch(s); /* Remote pasteboard changed. */
        return !s->apple_failed;
    }
    if (message->type != 0x1f) return FALSE;
    if (!ReadFromRFBServer(client, (char *)header + 1, 15)) return FALSE;
    size_t expanded = apple_u32(header + 8), length = apple_u32(header + 12);
    if (!length || length > TSV_APPLE_ARCHIVE_LIMIT || expanded > TSV_APPLE_ARCHIVE_LIMIT) return FALSE;
    uint8_t *data = malloc(length);
    if (!data) return FALSE;
    bool okay = ReadFromRFBServer(client, (char *)data, (unsigned int)length);
    char *text = NULL;
    int text_length = 0;
    if (okay && s->receive_clipboard && s->clipboard_focused)
        okay = tsv_apple_clipboard_unpack(data, length, expanded, &text, &text_length);
    free(data);
    if (!okay) { free(text); return FALSE; }
    int64_t revision = s->fetch_pending ? s->requested_revision : s->clipboard_revision;
    if (text && !s->fetch_stale && header[2] == 0 && s->clipboard_focused)
        s->callbacks.clipboard(s->callbacks.context, text, text_length, true, revision);
    free(text);
    s->fetch_pending = false;
    if (s->fetch_again) { s->fetch_again = false; apple_fetch(s); }
    return !s->apple_failed;
}
static rfbBool apple_message(rfbClient *client, rfbServerToClientMsg *message) {
    tsv_session *s = owner(client);
    if (!s || !s->apple || (message->type != 0x14 && message->type != 0x1f)) return FALSE;
    if (!read_apple_message(client, message)) {
        s->apple_failed = true;
        snprintf(s->error, sizeof(s->error), "Invalid Apple VNC clipboard message.");
    }
    /* This type was consumed, even when malformed. FALSE means unhandled to
       LibVNCClient, which would attempt another blocking diagnostic read. */
    return TRUE;
}
static bool apple_start(tsv_session *s) {
    s->apple = s->client->serverMajor == 3 && s->client->serverMinor == 889;
    if (!s->apple || !s->receive_clipboard) return true;
    /* ViewerInfo v1: declare only the MiscStatus command capability (bit 20).
       Version fields describe the Apple wire profile, not the app version.
       This enables change notifications without polling or Apple media codecs. */
    uint8_t viewer[66] = {0x21, 0, 0, 62, 0, 1};
    const uint8_t profile[28] = {0,0,0,2, 0,0,0,6, 0,0,0,1, 0,0,0,0,
                                0,0,0,15, 0,0,0,3, 0,0,0,0};
    memcpy(viewer + 6, profile, sizeof(profile));
    viewer[36] = 0x08;
    const uint8_t monitor[8] = {0x15, 0, 0, 1};
    return apple_write(s, viewer, sizeof(viewer)) && apple_write(s, monitor, sizeof(monitor));
}
static rfbBool certificate(rfbClient *client, const char *pem) {
    tsv_session *s = owner(client);
    bool ok = s->callbacks.certificate && s->callbacks.certificate(s->callbacks.context, pem);
    s->certificate_rejected = !ok;
    return ok;
}
static uint64_t monotonic_microseconds(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000000 + (uint64_t)time.tv_nsec / 1000;
}
static int wait_for_input(rfbClient *client, unsigned int usecs) {
    tsv_session *s = owner(client);
    bool infinite = usecs == UINT_MAX;
    uint64_t deadline = infinite ? 0 : monotonic_microseconds() + usecs;
    for (;;) {
        struct pollfd waiting[2] = {
            { .fd = client->sock, .events = POLLIN },
            { .fd = s->wake_descriptor, .events = POLLIN }
        };
        uint64_t now = monotonic_microseconds();
        int timeout = infinite ? -1 : (int)(((deadline > now ? deadline - now : 0) + 999) / 1000);
        int result = poll(waiting, 2, timeout);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) return result;
        if (waiting[1].revents & POLLIN) {
            char bytes[128];
            while (read(s->wake_descriptor, bytes, sizeof(bytes)) > 0) {}
            if (s->ready && !s->handling_input && s->callbacks.input) {
                s->handling_input = true;
                s->callbacks.input(s->callbacks.context, s);
                s->handling_input = false;
            }
        }
        if (waiting[0].revents || (client->tlsSession && SSL_pending(client->tlsSession) > 0)) return 1;
        if (waiting[1].revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
        if (infinite) return 0; /* Queued input was serviced; recheck stop state. */
        // An input wake must not consume a read-timeout retry. Continue waiting
        // for the remainder of the library's original timeout on this thread.
    }
}
void tsv_set_wakeup(tsv_session *s, int descriptor) {
    s->wake_descriptor = descriptor;
    s->client->WaitForInput = descriptor >= 0 ? wait_for_input : NULL;
}
tsv_session *tsv_new(int socket, const char *host, const char *user, const char *secret, bool allow_none,
                     bool view_only, bool clipboard, bool receive_clipboard, int quality,
                     bool require_tls, tsv_callbacks callbacks) {
    pthread_once(&log_once, setup_log);
    tsv_session *s = calloc(1, sizeof(*s));
    if (!s) { close(socket); return NULL; }
    current = s;
    s->wake_descriptor = -1;
    s->callbacks = callbacks;
    s->view_only = view_only;
    s->clipboard = clipboard;
    s->receive_clipboard = receive_clipboard;
    s->user = strdup(user);
    s->password = strdup(secret);
    s->client = rfbGetClient(8, 3, 4);
    if (!s->client) { tsv_free(s); close(socket); return NULL; }
    rfbClient *c = s->client;
    free(c->serverHost);
    c->serverHost = strdup(host);
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
    c->appData.compressLevel = quality == 1 ? 6 : quality == 2 ? 1 : 2;
    c->format.redShift = 16; c->format.greenShift = 8; c->format.blueShift = 0;
    c->format.bigEndian = FALSE;
    if (quality == 2) {
        c->format.depth = 16;
        c->format.redMax = c->format.blueMax = 31;
        c->format.greenMax = 63;
    }
    c->GetPassword = password;
    c->GetCredential = credential;
    c->MallocFrameBuffer = resize;
    c->GotFrameBufferUpdate = pixels;
    c->FinishedFrameBufferUpdate = frame;
    c->GotXCutText = cut_text;
    c->GotXCutTextUTF8 = cut_utf8;
    c->canHandleNewFBSize = TRUE;
    c->VerifyX509Certificate = certificate;
    if (require_tls) {
        uint32_t schemes[4] = { rfbVeNCrypt, rfbVeNCryptX509VNC };
        int count = 2;
        if (user[0]) schemes[count++] = rfbVeNCryptX509Plain;
        if (allow_none) schemes[count++] = rfbVeNCryptX509None;
        SetClientAuthSchemes(c, schemes, count);
    } else {
        uint32_t schemes[] = { rfbVncAuth, rfbARD, rfbNoAuth };
        SetClientAuthSchemes(c, schemes, allow_none ? 3 : 2);
    }
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
    s->ready = apple_start(s) && SendFramebufferUpdateRequest(c, 0, 0, c->width, c->height, FALSE);
    return s->ready;
}
int tsv_poll(tsv_session *s) {
    current = s;
    if (s->apple_failed) return -1;
    // ReadFromRFBServer reads ahead. Drain those bytes before select: a
    // complete update may already be buffered while the socket is idle.
    int result = s->client->buffered > 0 || (s->client->tlsSession && SSL_pending(s->client->tlsSession) > 0)
        ? 1 : WaitForMessage(s->client, s->wake_descriptor >= 0 ? UINT_MAX : 10000);
    if (result <= 0) return result;
    if (!HandleRFBServerMessage(s->client) || s->apple_failed) return -1;
    bool supported = s->client->screen.width != 0 && s->client->screen.height != 0;
    if (supported != s->resize_supported) {
        s->resize_supported = supported;
        s->callbacks.resize_support(s->callbacks.context, supported);
    }
    return 1;
}
void tsv_resize(tsv_session *s, int width, int height) {
    if (!s->view_only && s->resize_supported && width >= 320 && height >= 200 &&
        width <= 8192 && height <= 8192 && (size_t)width * height <= 16777216)
        SendExtDesktopSize(s->client, (uint16_t)width, (uint16_t)height);
}
void tsv_key(tsv_session *s, uint32_t keysym, bool down) {
    if (!s->view_only) SendKeyEvent(s->client, keysym, down);
}
void tsv_pointer(tsv_session *s, int x, int y, int buttons) {
    if (!s->view_only) SendPointerEvent(s->client, x, y, buttons);
}
void tsv_clipboard(tsv_session *s, const char *utf8, int utf8_length, const char *latin1, int latin1_length) {
    if (!s->clipboard || s->view_only) return;
    if (utf8_length < 0 || utf8_length > TSV_CLIPBOARD_TEXT_LIMIT) return;
    if (s->apple) {
        uint8_t *packet;
        size_t size;
        if (!tsv_apple_clipboard_pack(utf8, (size_t)utf8_length, &packet, &size)) return;
        if (s->fetch_pending) { s->fetch_stale = true; s->fetch_again = true; }
        apple_write(s, packet, size);
        free(packet);
        return;
    }
    if (!SendClientCutTextUTF8(s->client, (char *)utf8, utf8_length))
        SendClientCutText(s->client, (char *)latin1, latin1_length);
}
const char *tsv_error(tsv_session *s) { return s->error; }
int tsv_error_code(tsv_session *s) {
    if (s->needs_user) return 3;
    if (s->certificate_rejected) return 4;
    return strcasestr(s->error, "authentication failed") ||
           strcasestr(s->error, "authentication failure") ||
           strcasestr(s->error, "authentication or authorization failure") ? 2 : 1;
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
    free(s->display);
    if (current == s) current = NULL;
    free(s);
}
