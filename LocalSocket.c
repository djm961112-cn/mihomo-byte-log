#include "LocalSocket.h"
#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>

struct buffer {
    unsigned char *bytes;
    size_t length;
};

static size_t append(char *source, size_t size, size_t count, void *context) {
    struct buffer *result = context;
    size_t length = size * count;
    if (length > 8 * 1024 * 1024 - result->length) return 0;
    unsigned char *next = realloc(result->bytes, result->length + length);
    if (!next) return 0;
    memcpy(next + result->length, source, length);
    result->bytes = next;
    result->length += length;
    return length;
}

int read_connections(const char *path, unsigned char **bytes, size_t *length) {
    CURL *client = curl_easy_init();
    if (!client) return -1;
    struct buffer result = {0};
    // Fail closed if Unix socket support is unavailable. Never fall back to TCP.
    if (curl_easy_setopt(client, CURLOPT_UNIX_SOCKET_PATH, path) != CURLE_OK) {
        curl_easy_cleanup(client);
        return -1;
    }
    curl_easy_setopt(client, CURLOPT_URL, "http://localhost/connections");
    curl_easy_setopt(client, CURLOPT_PROXY, "");
    curl_easy_setopt(client, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(client, CURLOPT_TIMEOUT_MS, 1500L);
    curl_easy_setopt(client, CURLOPT_FAILONERROR, 1L);
    curl_easy_setopt(client, CURLOPT_WRITEFUNCTION, append);
    curl_easy_setopt(client, CURLOPT_WRITEDATA, &result);
    CURLcode status = curl_easy_perform(client);
    curl_easy_cleanup(client);
    if (status != CURLE_OK || !result.length) {
        free(result.bytes);
        return -1;
    }
    *bytes = result.bytes;
    *length = result.length;
    return 0;
}
