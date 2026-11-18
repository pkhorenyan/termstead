#include "vnc_apple_clipboard.h"
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static const char utf8_type[] = "public.utf8-plain-text";
static void put32(uint8_t *p, uint32_t value) {
    p[0] = value >> 24; p[1] = value >> 16; p[2] = value >> 8; p[3] = value;
}
static bool pack_archive(const uint8_t *raw, size_t raw_length, uint8_t **packet, size_t *size) {
    *packet = NULL; *size = 0;
    size_t capacity = compressBound(raw_length) + 16;
    uint8_t *out = calloc(16 + capacity, 1);
    z_stream stream = {0};
    bool initialized = false, okay = false;
    if (!out || deflateInit(&stream, Z_DEFAULT_COMPRESSION) != Z_OK) goto done;
    initialized = true;
    stream.next_in = (Bytef *)raw; stream.avail_in = (uInt)raw_length;
    stream.next_out = out + 16; stream.avail_out = (uInt)capacity;
    if (deflate(&stream, Z_SYNC_FLUSH) != Z_OK || stream.avail_in || !stream.avail_out) goto done;
    out[0] = 0x1f;
    put32(out + 8, (uint32_t)raw_length);
    put32(out + 12, (uint32_t)stream.total_out);
    *packet = out; *size = 16 + stream.total_out;
    okay = true;
done:
    if (initialized) deflateEnd(&stream);
    if (!okay) free(out);
    return okay;
}

bool tsv_apple_clipboard_pack(const char *text, size_t length, uint8_t **packet, size_t *size) {
    *packet = NULL; *size = 0;
    if (length > TSV_CLIPBOARD_TEXT_LIMIT || (!text && length)) return false;
    const size_t type_length = sizeof(utf8_type) - 1;
    size_t raw_length = 20 + type_length + length;
    uint8_t *raw = malloc(raw_length);
    if (!raw) return false;
    put32(raw, 1); put32(raw + 4, (uint32_t)type_length);
    memcpy(raw + 8, utf8_type, type_length);
    put32(raw + 8 + type_length, 0); /* Reserved. */
    put32(raw + 12 + type_length, 0); /* No aliases. */
    put32(raw + 16 + type_length, (uint32_t)length);
    if (length) memcpy(raw + 20 + type_length, text, length);
    bool okay = pack_archive(raw, raw_length, packet, size);
    free(raw);
    return okay;
}

typedef struct { const uint8_t *next; size_t remaining; } reader;
static bool take32(reader *r, uint32_t *value) {
    if (r->remaining < 4) return false;
    const uint8_t *p = r->next;
    *value = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
    r->next += 4; r->remaining -= 4;
    return true;
}
static bool blob(reader *r, const uint8_t **bytes, uint32_t *length) {
    if (!take32(r, length) || *length > r->remaining) return false;
    *bytes = r->next;
    r->next += *length; r->remaining -= *length;
    return true;
}
static bool is_type(const uint8_t *bytes, size_t length, const char *type) {
    return length == strlen(type) && memcmp(bytes, type, length) == 0;
}
static void decode_text(const uint8_t *bytes, size_t length, CFStringEncoding encoding,
                        char **text, int *text_length) {
    CFStringRef value = CFStringCreateWithBytes(NULL, bytes, (CFIndex)length, encoding, false);
    if (!value) return;
    CFRange range = CFRangeMake(0, CFStringGetLength(value));
    CFIndex count = 0;
    CFStringGetBytes(value, range, kCFStringEncodingUTF8, 0, false, NULL, 0, &count);
    if (count <= TSV_CLIPBOARD_TEXT_LIMIT) {
        char *buffer = malloc((size_t)count + 1);
        if (buffer) {
            CFStringGetBytes(value, range, kCFStringEncodingUTF8, 0, false, (UInt8 *)buffer, count, NULL);
            buffer[count] = 0;
            *text = buffer; *text_length = (int)count;
        }
    }
    CFRelease(value);
}
bool tsv_apple_clipboard_unpack(const uint8_t *compressed, size_t length, size_t expanded,
                                char **text, int *text_length) {
    *text = NULL; *text_length = 0;
    if (!length || length > TSV_APPLE_ARCHIVE_LIMIT || expanded > TSV_APPLE_ARCHIVE_LIMIT) return false;
    uint8_t *raw = malloc(expanded + 1);
    if (!raw) return false;
    z_stream stream = {0};
    bool okay = false;
    if (inflateInit(&stream) != Z_OK) { free(raw); return false; }
    stream.next_in = (Bytef *)compressed; stream.avail_in = (uInt)length;
    stream.next_out = raw; stream.avail_out = (uInt)expanded + 1;
    int status = inflate(&stream, Z_SYNC_FLUSH);
    bool flushed = length >= 4 && memcmp(compressed + length - 4, "\0\0\xff\xff", 4) == 0;
    bool complete = status == Z_STREAM_END || (status == Z_OK && flushed);
    bool exact = !stream.avail_in && stream.total_out == expanded;
    inflateEnd(&stream);
    if (!complete || !exact) goto done;
    if (!expanded) { okay = true; goto done; } /* Empty clipboard. */
    reader r = {raw, expanded};
    const uint8_t *best = NULL;
    uint32_t best_length = 0;
    int priority = 0;
    CFStringEncoding encoding = kCFStringEncodingUTF8;
    uint32_t groups = 0;
    while (r.remaining) {
        uint32_t items;
        if (++groups > 64 || !take32(&r, &items) || items > 64) goto done;
        for (uint32_t i = 0; i < items; ++i) {
            const uint8_t *type, *data, *ignored;
            uint32_t type_length, data_length, reserved, aliases, ignored_length;
            if (!blob(&r, &type, &type_length) || !take32(&r, &reserved) ||
                !take32(&r, &aliases) || aliases > 32) goto done;
            for (uint32_t alias = 0; alias < aliases; ++alias) {
                if (!blob(&r, &ignored, &ignored_length) || !blob(&r, &ignored, &ignored_length)) goto done;
            }
            if (!blob(&r, &data, &data_length)) goto done;
            int rank = 0;
            CFStringEncoding candidate = kCFStringEncodingUTF8;
            if (is_type(type, type_length, utf8_type)) rank = 3;
            else if (is_type(type, type_length, "public.utf16-plain-text") ||
                     is_type(type, type_length, "public.utf16-external-plain-text")) {
                rank = 2;
                candidate = data_length >= 2 && data[0] == 0xff && data[1] == 0xfe
                    ? kCFStringEncodingUTF16LE : kCFStringEncodingUTF16BE;
                if (data_length >= 2 && ((data[0] == 0xff && data[1] == 0xfe) || (data[0] == 0xfe && data[1] == 0xff))) {
                    data += 2; data_length -= 2;
                }
            } else if (is_type(type, type_length, "com.apple.traditional-mac-plain-text")) {
                rank = 1; candidate = kCFStringEncodingMacRoman;
            }
            if (rank > priority) {
                best = data; best_length = data_length; priority = rank; encoding = candidate;
            }
        }
    }
    if (r.remaining) goto done;
    if (best) decode_text(best, best_length, encoding, text, text_length);
    okay = true;
done:
    free(raw);
    return okay;
}
