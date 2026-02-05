#define AEROSPACE_H

#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

// Reconnect the socket every N commands to prevent staleness
#define AEROSPACE_RECONNECT_INTERVAL 50

typedef struct aerospace aerospace;

aerospace* aerospace_new(const char* socketPath);

// Ensure the socket is connected. Reconnects if broken or stale.
// Returns 1 if connected, 0 if not (will retry next call).
int aerospace_ensure_connected(aerospace* client);

void aerospace_close(aerospace* client);

char* aerospace_switch(aerospace* client, const char* direction);

char* aerospace_workspace(aerospace* client, int wrap_around, const char* ws_command, const char* stdin_payload);

char* aerospace_list_workspaces(aerospace* client, bool include_empty);
