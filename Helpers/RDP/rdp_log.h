#ifndef TERMSTEAD_RDP_LOG_H
#define TERMSTEAD_RDP_LOG_H

#include <stdbool.h>

/// One of FreeRDP's log lines, to the unified log under
/// com.pavelkhorenyan.Termstead.rdp.
void tsr_log_line(bool error, const char* function, const char* text);

#endif
