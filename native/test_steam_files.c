/* Standalone filesystem contracts. The production DLL keeps its exact build gate.
 * Tests access implementation statics only in this separate executable. */
#include "steam_files.c"
#include <assert.h>

static uint32_t serial;
static unsigned char response[4096];
static size_t response_size;
static uint32_t send_request(uint32_t operation, const wchar_t *path, const char *data) {
    char encoded[32768];
    uint32_t size;
    FILE *stream = NULL;
    int length = WideCharToMultiByte(CP_UTF8, 0, path, -1, encoded, sizeof(encoded), NULL, NULL);
    assert(length > 0); size = (uint32_t)length - 1; ++serial;
    assert(!_wfopen_s(&stream, request_file, L"wb"));
    fwrite(&serial, 4, 1, stream); fwrite(&operation, 4, 1, stream); fwrite(&size, 4, 1, stream);
    fwrite(encoded, 1, size, stream); if (data) fwrite(data, 1, strlen(data), stream); fclose(stream);
    lll_steam_request(NULL);
    assert(!_wfopen_s(&stream, response_file, L"rb"));
    response_size = fread(response, 1, sizeof(response), stream); fclose(stream);
    assert(response_size >= 8 && !memcmp(response, &serial, 4));
    memcpy(&size, response + 4, 4); return size;
}

int main(void) {
    wchar_t temp[MAX_PATH], folder[MAX_PATH], file[MAX_PATH];
    FILE *stream = NULL;
    WIN32_FILE_ATTRIBUTE_DATA before, after;
    uint64_t expected;
    assert(GetTempPathW(MAX_PATH, temp));
    assert(GetTempFileNameW(temp, L"lls", 0, folder));
    assert(DeleteFileW(folder) && CreateDirectoryW(folder, NULL));
    swprintf_s(request_file, MAX_PATH, L"%s\\request.bin", folder);
    swprintf_s(response_file, MAX_PATH, L"%s\\response.bin", folder);
    swprintf_s(events_file, MAX_PATH, L"%s\\events.bin", folder);
    /* Unit-test-only host. This code is not linked into the production DLL. */
    initialized = supported = 1;
    assert(send_request(6, L"hash", "core/wwise/lua/wwise_flow_callbacks") == 0);
    expected = UINT64_C(0x7251fdd9bb62480a);
    assert(response_size == 16 && !memcmp(response + 8, &expected, 8));
    assert(send_request(4, folder, NULL) == 0 && watch_count == 1);
    assert(send_request(4, folder, NULL) == 0 && watch_count == 1);
    assert(send_request(7, folder, NULL) == 0 && watches[0].path == NULL);
    assert(send_request(4, folder, NULL) == 0 && watch_count == 1 && watches[0].path != NULL);
    swprintf_s(file, MAX_PATH, L"%s\\unicode-\x03a9.lua", folder);
    assert(send_request(5, file, "return 'first'") == 0);
    assert(send_request(5, file, "return 'second'") == 0);
    assert(!_wfopen_s(&stream, file, L"rb"));
    assert(fread(response, 1, 15, stream) == 15); fclose(stream);
    assert(!memcmp(response, "return 'second'", 15));
    assert(send_request(2, file, NULL) == 0 && response_size == 28);
    assert(send_request(1, folder, NULL) == 0 && response_size > 28);
    assert(WaitForSingleObject(watches[0].handle, 2000) == WAIT_OBJECT_0);
    lll_steam_poll(NULL);
    assert(watches[0].generation == 2);
    /* Watch a separate directory so transport replies cannot notify themselves. */
    lll_steam_close(NULL);
    swprintf_s(file, MAX_PATH, L"%s\\watched", folder); assert(CreateDirectoryW(file, NULL));
    assert(send_request(4, file, NULL) == 0);
    assert(GetFileAttributesExW(events_file, GetFileExInfoStandard, &before));
    for (int index = 0; index < 100; ++index) lll_steam_poll(NULL);
    assert(GetFileAttributesExW(events_file, GetFileExInfoStandard, &after));
    assert(!memcmp(&before.ftLastWriteTime, &after.ftLastWriteTime, sizeof(FILETIME)));
    lll_steam_close(NULL); assert(!watch_count); assert(RemoveDirectoryW(file));
    /* Missing roots ignore protocol writes to their ancestor, then rebase as
     * each directory in the missing path appears. */
    swprintf_s(file, MAX_PATH, L"%s\\missing\\mods", folder);
    assert(send_request(4, file, NULL) == 0 && watches[0].ancestor);
    for (int index = 0; index < 10; ++index) {
        assert(send_request(2, file, NULL) != 0);
        lll_steam_poll(NULL);
    }
    assert(watches[0].generation == 1);
    swprintf_s(file, MAX_PATH, L"%s\\missing", folder); assert(CreateDirectoryW(file, NULL));
    assert(WaitForSingleObject(watches[0].handle, 2000) == WAIT_OBJECT_0);
    lll_steam_poll(NULL); assert(watches[0].ancestor);
    swprintf_s(file, MAX_PATH, L"%s\\missing\\mods", folder); assert(CreateDirectoryW(file, NULL));
    assert(WaitForSingleObject(watches[0].handle, 2000) == WAIT_OBJECT_0);
    lll_steam_poll(NULL); assert(!watches[0].ancestor);
    lll_steam_close(NULL); assert(RemoveDirectoryW(file));
    swprintf_s(file, MAX_PATH, L"%s\\missing", folder); assert(RemoveDirectoryW(file));
    swprintf_s(file, MAX_PATH, L"%s\\unicode-\x03a9.lua", folder); assert(DeleteFileW(file));
    assert(DeleteFileW(request_file)); assert(DeleteFileW(response_file)); assert(DeleteFileW(events_file));
    assert(RemoveDirectoryW(folder));
    puts("PASS: native hash, Unicode atomic replace, metadata, event notifications, idle silence, cleanup");
    return 0;
}
