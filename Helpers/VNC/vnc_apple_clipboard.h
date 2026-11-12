#ifndef TERMSTEAD_VNC_APPLE_CLIPBOARD_H
#define TERMSTEAD_VNC_APPLE_CLIPBOARD_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define TSV_CLIPBOARD_TEXT_LIMIT 1048576
#define TSV_APPLE_ARCHIVE_LIMIT (8 * TSV_CLIPBOARD_TEXT_LIMIT)

/* Apple ClipboardSend (0x1f): a bounded zlib pasteboard archive, not
   ClientCutText's legacy TEXT flavor. Buffers returned here are owned. */
bool tsv_apple_clipboard_pack(const char *text, size_t length, uint8_t **packet, size_t *size);
bool tsv_apple_clipboard_unpack(const uint8_t *compressed, size_t length, size_t expanded,
                                char **text, int *text_length);
#endif
