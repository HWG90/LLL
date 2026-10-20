/* Lua-loadable Windows filesystem transport for Steam's Lua 5.1 VM.
 * Exports are Lua C functions returning zero results. They deliberately never
 * dereference lua_State or call a Lua ABI: request/reply bytes use normal files.
 * No process hooks, code patches, input hooks, worker threads or memory access.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define MAX_WATCHES 256
#define MAX_REQUEST (64u * 1024u * 1024u)
static const char EXE_SHA[] = "2ce8b3d74c5573088e4211b060ced0963f1fc1e74526e2645399780b8fb13ff7";
static const char GAME_SHA[] = "a457433f0eb766fbe15a6de5a16f0fbbb1fd3c840c5607a5f0b2ebf53b112949";
static wchar_t home[MAX_PATH], request_file[MAX_PATH], response_file[MAX_PATH], events_file[MAX_PATH];
static wchar_t executable[32768], game_root[32768];
static int initialized, supported;
typedef struct { wchar_t *path; HANDLE handle; uint32_t generation; int ancestor; } Watch;
static Watch watches[MAX_WATCHES];
static uint32_t watch_count;
static DWORD session_pid;
static int inline_events;

static uint64_t resource_hash(const unsigned char *bytes, size_t length) {
    const uint64_t mix = UINT64_C(0xc6a4a7935bd1e995);
    uint64_t value = (uint64_t)length * mix, word = 0;
    size_t offset = 0;
    while (offset + 8 <= length) {
        memcpy(&word, bytes + offset, 8);
        word *= mix; word ^= word >> 47; word *= mix;
        value = (value ^ word) * mix; offset += 8;
    }
    word = 0;
    for (size_t index = 0; index < length - offset; ++index) word |= (uint64_t)bytes[offset + index] << (index * 8);
    if (offset < length) value = (value ^ word) * mix;
    value ^= value >> 47; value *= mix; return value ^ (value >> 47);
}

static int hash_file(const wchar_t *path, char output[65]) {
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    HANDLE file = INVALID_HANDLE_VALUE;
    unsigned char buffer[65536], value[32];
    DWORD count;
    int ok = 0;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0) goto done;
    if (BCryptCreateHash(algorithm, &hash, NULL, 0, NULL, 0, 0) < 0) goto done;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) goto done;
    for (;;) {
        if (!ReadFile(file, buffer, sizeof(buffer), &count, NULL)) goto done;
        if (!count) break;
        if (BCryptHashData(hash, buffer, count, 0) < 0) goto done;
    }
    if (BCryptFinishHash(hash, value, sizeof(value), 0) < 0) goto done;
    for (count = 0; count < 32; ++count) sprintf_s(output + count * 2, 3, "%02x", value[count]);
    ok = 1;
done:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok;
}

static void initialize(void) {
    wchar_t module[32768], *end;
    char hash[65];
    DWORD length;
    if (initialized) return;
    initialized = 1;
    length = GetEnvironmentVariableW(L"LOCALAPPDATA", home, MAX_PATH);
    if (!length || length + 48 >= MAX_PATH) return;
    wcscat_s(home, MAX_PATH, L"\\LLL"); CreateDirectoryW(home, NULL);
    wcscat_s(home, MAX_PATH, L"\\Helldivers2"); CreateDirectoryW(home, NULL);
    wcscat_s(home, MAX_PATH, L"\\Steam"); CreateDirectoryW(home, NULL);
    swprintf_s(request_file, MAX_PATH, L"%s\\request.bin", home);
    swprintf_s(response_file, MAX_PATH, L"%s\\response.bin", home);
    swprintf_s(events_file, MAX_PATH, L"%s\\events.bin", home);
    length = GetModuleFileNameW(NULL, executable, 32768);
    if (!length || length >= 32768) return;
    wcscpy_s(game_root, 32768, executable);
    end = wcsrchr(game_root, L'\\'); if (!end) return; *end = 0;
    end = wcsrchr(game_root, L'\\'); if (!end || _wcsicmp(end, L"\\bin")) return; *end = 0;
    if (!hash_file(executable, hash) || strcmp(hash, EXE_SHA)) return;
    if (!GetModuleHandleW(L"game.dll") || !GetModuleFileNameW(GetModuleHandleW(L"game.dll"), module, 32768)) return;
    if (!hash_file(module, hash) || strcmp(hash, GAME_SHA)) return;
    supported = 1;
}

static FILE *reply_begin(const wchar_t *destination) {
    FILE *stream = NULL;
    wchar_t temporary[MAX_PATH];
    if (!destination[0]) return NULL;
    swprintf_s(temporary, MAX_PATH, L"%s.tmp", destination);
    if (_wfopen_s(&stream, temporary, L"wb")) return NULL;
    return stream;
}
static void reply_end(FILE *stream, const wchar_t *destination) {
    wchar_t temporary[MAX_PATH];
    if (!stream) return;
    swprintf_s(temporary, MAX_PATH, L"%s.tmp", destination);
    /* Protocol replies are transient, acknowledged on the pipe. Persisting each
     * reply to physical media stalls every stat/list request on the game thread. */
    if (fclose(stream) == 0) MoveFileExW(temporary, destination, MOVEFILE_REPLACE_EXISTING);
}
static void integer(FILE *stream, uint32_t value) { fwrite(&value, 4, 1, stream); }
static void text(FILE *stream, const wchar_t *value) {
    int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, NULL, 0, NULL, NULL);
    char *buffer;
    if (length <= 0) { integer(stream, 0); return; }
    buffer = malloc((size_t)length);
    if (!buffer) { integer(stream, 0); return; }
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, buffer, length, NULL, NULL);
    integer(stream, (uint32_t)length - 1); fwrite(buffer, 1, (size_t)length - 1, stream); free(buffer);
}
static void events(void) {
    if (inline_events) return; /* Pipe service returns generations directly. */
    FILE *stream = reply_begin(events_file);
    uint32_t index;
    if (!stream) return;
    integer(stream, session_pid ? session_pid : GetCurrentProcessId());
    integer(stream, watch_count);
    for (index = 0; index < watch_count; ++index) integer(stream, watches[index].generation);
    reply_end(stream, events_file);
}
static void start_watch(Watch *watch) {
    wchar_t path[32768], *end;
    watch->ancestor = 0;
    wcscpy_s(path, 32768, watch->path);
    for (;;) {
        /* A missing root needs only direct child directory creation events.
         * Recursive parent watches otherwise observe our own protocol replies
         * and unrelated AppData writes, continuously invalidating discovery. */
        watch->handle = FindFirstChangeNotificationW(path, watch->ancestor ? FALSE : TRUE,
            watch->ancestor ? FILE_NOTIFY_CHANGE_DIR_NAME :
            (FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE));
        if (watch->handle != INVALID_HANDLE_VALUE) return;
        end = wcsrchr(path, L'\\'); if (!end || end - path < 3) return; *end = 0; watch->ancestor = 1;
    }
}

__declspec(dllexport) int lll_steam_boot(void *unused) {
    FILE *stream;
    (void)unused; initialize();
    stream = reply_begin(response_file);
    if (!stream) return 0;
    integer(stream, 0);
    integer(stream, supported ? 0 : ERROR_REVISION_MISMATCH);
    integer(stream, session_pid ? session_pid : GetCurrentProcessId());
    text(stream, executable); text(stream, game_root);
    reply_end(stream, response_file);
    return 0;
}

__declspec(dllexport) int lll_steam_poll(void *unused) {
    uint32_t index;
    int changed = 0;
    (void)unused;
    if (!supported) return 0;
    for (index = 0; index < watch_count; ++index) {
        Watch *watch = &watches[index];
        DWORD result;
        if (watch->handle == INVALID_HANDLE_VALUE) continue;
        result = WaitForSingleObject(watch->handle, 0);
        if (result == WAIT_TIMEOUT) continue;
        ++watch->generation; changed = 1;
        if (result != WAIT_OBJECT_0 || !FindNextChangeNotification(watch->handle)
            || watch->ancestor) {
            FindCloseChangeNotification(watch->handle); watch->handle = INVALID_HANDLE_VALUE;
            start_watch(watch);
        }
    }
    if (changed) events();
    return 0;
}

__declspec(dllexport) int lll_steam_close(void *unused) {
    uint32_t index;
    (void)unused;
    for (index = 0; index < watch_count; ++index) {
        if (watches[index].handle != INVALID_HANDLE_VALUE) FindCloseChangeNotification(watches[index].handle);
        free(watches[index].path); watches[index].path = NULL;
    }
    watch_count = 0;
    if (supported) events();
    return 0;
}

__declspec(dllexport) int lll_steam_request(void *unused) {
    FILE *input = NULL, *output = NULL;
    unsigned char *bytes = NULL;
    wchar_t *path = NULL;
    long length;
    uint32_t operation, nonce = 0, path_size, status = ERROR_INVALID_DATA;
    int path_length;
    (void)unused;
    if (!supported) return 0;
    if (_wfopen_s(&input, request_file, L"rb")) goto done;
    if (fseek(input, 0, SEEK_END) || (length = ftell(input)) < 12 || length > MAX_REQUEST || fseek(input, 0, SEEK_SET)) goto done;
    bytes = malloc((size_t)length);
    if (!bytes || fread(bytes, 1, (size_t)length, input) != (size_t)length) goto done;
    memcpy(&nonce, bytes, 4); memcpy(&operation, bytes + 4, 4); memcpy(&path_size, bytes + 8, 4);
    if (!path_size || path_size > 32760 || path_size > (uint32_t)length - 12 || memchr(bytes + 12, 0, path_size)) goto done;
    path_length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (char *)bytes + 12, (int)path_size, NULL, 0);
    if (path_length <= 0) goto done;
    path = calloc((size_t)path_length + 1, sizeof(wchar_t));
    if (!path) goto done;
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (char *)bytes + 12, (int)path_size, path, path_length);
    for (int index = 0; index < path_length; ++index) if (path[index] == L'/') path[index] = L'\\';
    output = reply_begin(response_file); if (!output) goto done;
    integer(output, nonce);
    if (operation == 1) { /* Directory listing: attribute bits, stamp and UTF-8 name. */
        WIN32_FIND_DATAW data;
        wchar_t pattern[32768];
        HANDLE handle;
        uint32_t count = 0;
        swprintf_s(pattern, 32768, L"%s\\*", path);
        handle = FindFirstFileW(pattern, &data);
        if (handle == INVALID_HANDLE_VALUE) { integer(output, GetLastError()); goto done; }
        integer(output, 0);
        do {
            if (!wcscmp(data.cFileName, L".") || !wcscmp(data.cFileName, L"..")) continue;
            if (++count > 100000) break;
            integer(output, data.dwFileAttributes);
            integer(output, data.nFileSizeHigh); integer(output, data.nFileSizeLow);
            integer(output, data.ftLastWriteTime.dwHighDateTime); integer(output, data.ftLastWriteTime.dwLowDateTime);
            text(output, data.cFileName);
        } while (FindNextFileW(handle, &data));
        status = GetLastError(); FindClose(handle);
        /* No partial directory can be mistaken for a complete listing. */
        if (count > 100000 || status != ERROR_NO_MORE_FILES) { fseek(output, 4, SEEK_SET); integer(output, ERROR_MORE_DATA); }
    } else if (operation == 2) { /* File identity stamp. */
        WIN32_FILE_ATTRIBUTE_DATA data;
        if (!GetFileAttributesExW(path, GetFileExInfoStandard, &data)) { integer(output, GetLastError()); goto done; }
        integer(output, 0); integer(output, data.dwFileAttributes);
        integer(output, data.nFileSizeHigh); integer(output, data.nFileSizeLow);
        integer(output, data.ftLastWriteTime.dwHighDateTime); integer(output, data.ftLastWriteTime.dwLowDateTime);
    } else if (operation == 3) {
        status = CreateDirectoryW(path, NULL) ? 0 : GetLastError();
        integer(output, status == ERROR_ALREADY_EXISTS ? 0 : status);
    } else if (operation == 4) {
        uint32_t index;
        for (index = 0; index < watch_count; ++index) if (watches[index].path && !_wcsicmp(watches[index].path, path)) break;
        if (index == watch_count) {
            for (index = 0; index < watch_count; ++index) if (!watches[index].path) break;
        }
        if (index < MAX_WATCHES && (index == watch_count || !watches[index].path)) {
            watches[index].path = _wcsdup(path);
            if (watches[index].path) {
                watches[index].generation = 1; start_watch(&watches[index]);
                if (index == watch_count) ++watch_count;
                events();
            }
        }
        integer(output, index < watch_count && watches[index].path ? 0 : ERROR_TOO_MANY_OPEN_FILES); integer(output, index + 1);
    } else if (operation == 5) { /* Atomic replacement; payload remains ordinary file data. */
        wchar_t temporary[32768];
        HANDLE file;
        DWORD written, size = (DWORD)length - 12 - path_size;
        swprintf_s(temporary, 32768, L"%s.lll-steam.tmp", path);
        file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
        if (file == INVALID_HANDLE_VALUE) { integer(output, GetLastError()); goto done; }
        status = WriteFile(file, bytes + 12 + path_size, size, &written, NULL) && written == size ? 0 : ERROR_WRITE_FAULT;
        CloseHandle(file);
        if (!status && !MoveFileExW(temporary, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) status = GetLastError();
        if (status) DeleteFileW(temporary);
        integer(output, status);
    } else if (operation == 6) {
        uint64_t value = resource_hash(bytes + 12 + path_size, (size_t)length - 12 - path_size);
        integer(output, 0); fwrite(&value, 8, 1, output);
    } else if (operation == 7) {
        uint32_t index;
        for (index = 0; index < watch_count; ++index) {
            if (watches[index].path && !_wcsicmp(watches[index].path, path)) {
                if (watches[index].handle != INVALID_HANDLE_VALUE) FindCloseChangeNotification(watches[index].handle);
                watches[index].handle = INVALID_HANDLE_VALUE;
                free(watches[index].path); watches[index].path = NULL; ++watches[index].generation;
                events(); break;
            }
        }
        integer(output, 0);
    } else integer(output, ERROR_INVALID_FUNCTION);
done:
    if (input) fclose(input);
    if (!output) { output = reply_begin(response_file); if (output) { integer(output, nonce); integer(output, status); } }
    reply_end(output, response_file);
    free(path); free(bytes);
    return 0;
}
