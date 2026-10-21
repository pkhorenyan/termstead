#include "rdp_log.h"

#include <dispatch/dispatch.h>
#include <os/log.h>

// Apart from rdp_bridge.c: os/log.h brings the system's TRUE and FALSE,
// and next to WinPR's own they made every use of either ambiguous.
void tsr_log_line(bool error, const char* function, const char* text)
{
	static os_log_t log;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		log = os_log_create("com.pavelkhorenyan.Termstead.rdp", "freerdp");
	});
	os_log_with_type(log, error ? OS_LOG_TYPE_ERROR : OS_LOG_TYPE_DEFAULT, "%{public}s %{public}s",
	                 function ? function : "", text ? text : "");
}
