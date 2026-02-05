#include <errno.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>

#include "aerospace.h"
#include "yyjson.h"

#define READ_BUFFER_SIZE 8192
#define SOCKET_TIMEOUT_SECS 2

static const char* ERROR_SOCKET_RECEIVE = "Failed to receive data from socket";
static const char* ERROR_SOCKET_CLOSE = "Failed to close socket connection";
static const char* ERROR_JSON_PRINT = "Failed to print JSON to string";

struct aerospace {
	int fd;
	char* socket_path;
	char read_buf[READ_BUFFER_SIZE];
	size_t read_buf_len;
	unsigned int command_count;
};

static void fatal_error(const char* fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	fprintf(stderr, "Fatal Error: ");
	vfprintf(stderr, fmt, args);
	if (errno != 0)
		fprintf(stderr, ": %s (errno %d)", strerror(errno), errno);
	fprintf(stderr, "\n");
	va_end(args);
	exit(EXIT_FAILURE);
}

static char* get_default_socket_path(void)
{
	uid_t uid = getuid();
	struct passwd* pw = getpwuid(uid);

	if (uid == 0) {
		const char* sudo_user = getenv("SUDO_USER");
		if (sudo_user) {
			struct passwd* pw_temp = getpwnam(sudo_user);
			if (pw_temp)
				pw = pw_temp;
		} else {
			const char* user_env = getenv("USER");
			if (user_env && strcmp(user_env, "root") != 0) {
				struct passwd* pw_temp = getpwnam(user_env);
				if (pw_temp)
					pw = pw_temp;
			}
		}
	}

	if (!pw)
		fatal_error("Unable to determine user information for default socket path");

	const char* username = pw->pw_name;
	size_t len = snprintf(NULL, 0, "/tmp/bobko.aerospace-%s.sock", username);
	char* path = malloc(len + 1);
	snprintf(path, len + 1, "/tmp/bobko.aerospace-%s.sock", username);
	return path;
}

// Connect to the AeroSpace Unix socket.
// Returns fd on success, -1 on failure.
static int connect_socket(const char* socket_path)
{
	errno = 0;
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;

	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(struct sockaddr_un));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);
	addr.sun_path[sizeof(addr.sun_path) - 1] = '\0';

	errno = 0;
	if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
		close(fd);
		return -1;
	}

	// Set read timeout to prevent indefinite hangs on stale sockets
	struct timeval timeout;
	timeout.tv_sec = SOCKET_TIMEOUT_SECS;
	timeout.tv_usec = 0;
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

	return fd;
}

// Reconnect the socket. Closes existing fd and opens a fresh connection.
// Returns 1 on success, 0 on failure.
static int reconnect(aerospace* client)
{
	if (!client || !client->socket_path)
		return 0;

	if (client->fd >= 0) {
		close(client->fd);
		client->fd = -1;
	}
	client->read_buf_len = 0;
	client->command_count = 0;

	client->fd = connect_socket(client->socket_path);
	if (client->fd < 0) {
		fprintf(stderr, "Reconnect failed: %s (errno %d)\n", strerror(errno), errno);
		return 0;
	}

	return 1;
}

static char* execute_aerospace_command(aerospace* client, const char** args, int arg_count, const char* stdin_payload, const char* expected_output_field)
{
	if (!client || !args || arg_count == 0) {
		errno = EINVAL;
		fprintf(stderr, "execute_aerospace_command: Invalid arguments\n");
		return NULL;
	}

	if (client->fd < 0) {
		fprintf(stderr, "Socket not connected\n");
		return NULL;
	}

	yyjson_mut_doc* doc = yyjson_mut_doc_new(NULL);
	yyjson_mut_val* root = yyjson_mut_obj(doc);
	yyjson_mut_doc_set_root(doc, root);
	yyjson_mut_obj_add_str(doc, root, "command", args[0]);
	yyjson_mut_obj_add_str(doc, root, "stdin", stdin_payload ? stdin_payload : "");
	yyjson_mut_val* args_array = yyjson_mut_arr(doc);
	for (int i = 0; i < arg_count; i++) {
		yyjson_mut_arr_add_str(doc, args_array, args[i]);
	}
	yyjson_mut_obj_add_val(doc, root, "args", args_array);
	size_t len;
	const char* json_str = yyjson_mut_write(doc, 0, &len);
	yyjson_mut_doc_free(doc);
	if (!json_str) {
		fatal_error(ERROR_JSON_PRINT);
	}

	struct iovec iov[2];
	char newline = '\n';
	iov[0].iov_base = (void*)json_str;
	iov[0].iov_len = len;
	iov[1].iov_base = &newline;
	iov[1].iov_len = 1;

	if (writev(client->fd, iov, 2) < 0) {
		fprintf(stderr, "Socket write failed: %s (errno %d)\n", strerror(errno), errno);
		free((void*)json_str);
		close(client->fd);
		client->fd = -1;
		client->read_buf_len = 0;
		return NULL;
	}
	free((void*)json_str);

	client->command_count++;

	yyjson_doc* resp_doc = NULL;
	yyjson_read_err err;
	size_t parsed_bytes = 0;

	while (true) {
		if (client->read_buf_len > 0) {
			resp_doc = yyjson_read_opts(client->read_buf, client->read_buf_len, YYJSON_READ_STOP_WHEN_DONE, NULL, &err);
			if (resp_doc) {
				parsed_bytes = yyjson_doc_get_read_size(resp_doc);
				break;
			}
		}
		if (client->read_buf_len >= READ_BUFFER_SIZE) {
			fprintf(stderr, "Error: Read buffer overflow, clearing buffer.\n");
			client->read_buf_len = 0;
			return NULL;
		}
		ssize_t bytes_read = read(client->fd, client->read_buf + client->read_buf_len, READ_BUFFER_SIZE - client->read_buf_len);
		if (bytes_read <= 0) {
			if (bytes_read == 0) {
				fprintf(stderr, "%s: connection closed by AeroSpace\n", ERROR_SOCKET_RECEIVE);
			} else if (errno == EAGAIN || errno == EWOULDBLOCK) {
				fprintf(stderr, "%s: read timeout (%ds)\n", ERROR_SOCKET_RECEIVE, SOCKET_TIMEOUT_SECS);
			} else {
				fprintf(stderr, "%s: %s (errno %d)\n", ERROR_SOCKET_RECEIVE, strerror(errno), errno);
			}
			close(client->fd);
			client->fd = -1;
			client->read_buf_len = 0;
			return NULL;
		}
		client->read_buf_len += bytes_read;
	}

	if (client->read_buf_len > parsed_bytes) {
		memmove(client->read_buf, client->read_buf + parsed_bytes, client->read_buf_len - parsed_bytes);
	}
	client->read_buf_len -= parsed_bytes;

	yyjson_val* resp_root = yyjson_doc_get_root(resp_doc);
	char* result = NULL;
	int exitCode = -1;
	yyjson_val* exitCodeItem = yyjson_obj_get(resp_root, "exitCode");
	if (yyjson_is_int(exitCodeItem)) {
		exitCode = (int)yyjson_get_int(exitCodeItem);
	} else {
		fprintf(stderr, "Response does not contain valid exitCode field\n");
		yyjson_doc_free(resp_doc);
		return NULL;
	}

	if (exitCode != 0) {
		yyjson_val* output_item = yyjson_obj_get(resp_root, "stderr");
		if (yyjson_is_str(output_item)) {
			result = strdup(yyjson_get_str(output_item));
		}
	} else if (expected_output_field) {
		yyjson_val* output_item = yyjson_obj_get(resp_root, expected_output_field);
		if (yyjson_is_str(output_item)) {
			result = strdup(yyjson_get_str(output_item));
		}
	}

	yyjson_doc_free(resp_doc);
	return result;
}

aerospace* aerospace_new(const char* socketPath)
{
	aerospace* client = malloc(sizeof(aerospace));
	client->fd = -1;
	client->read_buf_len = 0;
	client->command_count = 0;

	if (socketPath)
		client->socket_path = strdup(socketPath);
	else
		client->socket_path = get_default_socket_path();

	client->fd = connect_socket(client->socket_path);
	if (client->fd < 0) {
		fprintf(stderr, "Warning: Could not connect to socket at %s: %s (errno %d). Will retry.\n",
			client->socket_path, strerror(errno), errno);
	}

	return client;
}

int aerospace_ensure_connected(aerospace* client)
{
	if (!client)
		return 0;

	// Socket is dead - reconnect
	if (client->fd < 0) {
		fprintf(stderr, "Socket disconnected, reconnecting...\n");
		if (reconnect(client))
			fprintf(stderr, "Reconnected to AeroSpace\n");
		return client->fd >= 0;
	}

	// Proactive: refresh socket every N commands to prevent staleness
	if (client->command_count >= AEROSPACE_RECONNECT_INTERVAL) {
		fprintf(stderr, "Proactive socket refresh after %u commands\n", client->command_count);
		reconnect(client);
	}

	return client->fd >= 0;
}

void aerospace_close(aerospace* client)
{
	if (client) {
		if (client->fd >= 0) {
			errno = 0;
			if (close(client->fd) < 0) {
				fprintf(stderr, "%s: %s (errno %d)\n", ERROR_SOCKET_CLOSE, strerror(errno), errno);
			}
			client->fd = -1;
		}
		free(client->socket_path);
		client->socket_path = NULL;
		free(client);
	}
}

char* aerospace_switch(aerospace* client, const char* direction)
{
	return aerospace_workspace(client, 0, direction, "");
}

char* aerospace_workspace(aerospace* client, int wrap_around, const char* ws_command,
	const char* stdin_payload)
{
	const char* args[3] = { "workspace", ws_command };
	int arg_count = 2;
	if (wrap_around) {
		args[arg_count++] = "--wrap-around";
	}
	return execute_aerospace_command(client, args, arg_count, stdin_payload, NULL);
}

char* aerospace_list_workspaces(aerospace* client, bool include_empty)
{
	if (include_empty) {
		const char* args[] = { "list-workspaces", "--monitor", "focused" };
		return execute_aerospace_command(client, args, 3, "", "stdout");
	} else {
		const char* args[] = { "list-workspaces", "--monitor", "focused", "--empty", "no" };
		return execute_aerospace_command(client, args, 5, "", "stdout");
	}
}
