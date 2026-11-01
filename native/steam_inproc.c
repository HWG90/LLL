/* In-process LLL Steam service for the LuaJIT boot runtime (Proton). It answers the external service's exact byte
 * protocol (steam_service.c) through a direct call from LLL's Lua transport (src/steam/transport_inproc.lua) on the
 * game thread, so platform.lua and every API built on it stay unchanged. No process is started and no code is patched.
 *  - Files (ops 0-9): steam_files.c and steam_service.c's operations, written to a reply buffer instead of the
 *    request/response files and pipes. The handshake checks the same two stock hashes.
 *  - Keyboard leases (16-18): steam_keyboard.c, included unchanged; its worker thread lives in the game process.
 *  - Pointer (10-12): steam_pointer.c's snapshots. RawInput allows one mouse target per process, and inside the game
 *    that target is normally the game's own. A lease then reads the packets the game already receives through a
 *    read-only WH_GETMESSAGE hook on the target window's thread: it never changes the registration and never swallows
 *    input. When the process has no mouse registration, steam_pointer.c's own sink runs as in the helper.
 *  - Screenshots (13-15): Wine has no Windows.Graphics.Capture (its graphicscapture.dll is a stub), so a request is
 *    refused with ERROR_NOT_SUPPORTED, the result the helper gives on Proton. No job ever exists.
 * Include in one translation unit (the runtime's lll_host.c). It defines no exports: the host hands
 * lll_inproc_exchange, lll_inproc_read_memory and lll_inproc_module_base to Lua. Only the game thread calls them;
 * the lease workers keep their own locks. */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <bcrypt.h>
#include <share.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "steam_pointer.c"
#include "steam_keyboard.c"

#define LLL_INPROC_MAX_WATCHES 256u
#define LLL_INPROC_MAX_REQUEST (64u * 1024u * 1024u)
/* The service build's pins (steam_files.c EXE_SHA/GAME_SHA); test_steam_inproc.c checks they agree. */
static const char lll_inproc_exe_sha[] = "257fd7de21a04e8668e02e5c820edf3435176fbde3569765255cc52a5ea20f9d";
static const char lll_inproc_game_sha[] = "61dcfcd201dacbf3545c97beb8a5a6186e9850d2670bf60b0e058320b477f6df";

typedef struct LLLInprocWatch { wchar_t *path; HANDLE handle; uint32_t generation; int ancestor; } LLLInprocWatch;
static LLLInprocWatch lll_inproc_watches[LLL_INPROC_MAX_WATCHES];
static uint32_t lll_inproc_watch_count;
static wchar_t lll_inproc_executable[32768], lll_inproc_root[32768];
static int lll_inproc_started, lll_inproc_supported, lll_inproc_broken, lll_inproc_screenshot_noted;
static DWORD lll_inproc_pid;
static unsigned char *lll_inproc_reply;
static uint32_t lll_inproc_capacity, lll_inproc_length;
static FILE *lll_inproc_log;
static HHOOK lll_inproc_hook;

static void lll_inproc_note(const char *format, ...) {
    va_list arguments;
    if (!lll_inproc_log) return;
    va_start(arguments, format); vfprintf(lll_inproc_log, format, arguments); va_end(arguments);
    fputc('\n', lll_inproc_log); fflush(lll_inproc_log);
}

/* steam_files.c resource_hash and hash_file, unchanged. */
static uint64_t lll_inproc_resource_hash(const unsigned char *bytes, size_t length) {
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
static int lll_inproc_hash_file(const wchar_t *path, char output[65]) {
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    HANDLE file = INVALID_HANDLE_VALUE;
    static unsigned char buffer[65536];
    unsigned char value[32];
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

/* The running executable and game.dll. Tests substitute fixed paths at compilation. */
#ifndef LLL_INPROC_PATHS
static int lll_inproc_paths(wchar_t executable[32768], wchar_t game[32768]) {
    HMODULE module = GetModuleHandleW(L"game.dll");
    DWORD length = GetModuleFileNameW(NULL, executable, 32768);
    if (!length || length >= 32768 || !module) return 0;
    length = GetModuleFileNameW(module, game, 32768);
    return length && length < 32768;
}
#define LLL_INPROC_PATHS lll_inproc_paths
#endif

/* Once, at the handshake: the log, the paths and the hash check (steam_files.c initialize() and the service's
 * wWinMain, with this process as the client). */
static void lll_inproc_start(void) {
    wchar_t game[32768], log_path[MAX_PATH], *end;
    char hash[65];
    DWORD length;
    if (lll_inproc_started) return;
    lll_inproc_started = 1;
    lll_inproc_pid = GetCurrentProcessId();
    length = GetEnvironmentVariableW(L"LOCALAPPDATA", log_path, MAX_PATH);
    if (length && length + 64 < MAX_PATH) {
        wcscat_s(log_path, MAX_PATH, L"\\LLL"); CreateDirectoryW(log_path, NULL);
        wcscat_s(log_path, MAX_PATH, L"\\Helldivers2"); CreateDirectoryW(log_path, NULL);
        wcscat_s(log_path, MAX_PATH, L"\\Steam"); CreateDirectoryW(log_path, NULL);
        wcscat_s(log_path, MAX_PATH, L"\\inprocess.log");
        lll_inproc_log = _wfsopen(log_path, L"wb", _SH_DENYNO);
    }
    if (!LLL_INPROC_PATHS(lll_inproc_executable, game)) goto refused;
    wcscpy_s(lll_inproc_root, 32768, lll_inproc_executable);
    end = wcsrchr(lll_inproc_root, L'\\'); if (!end) goto refused; *end = 0;
    end = wcsrchr(lll_inproc_root, L'\\'); if (!end || _wcsicmp(end, L"\\bin")) goto refused; *end = 0;
    lll_inproc_supported = lll_inproc_hash_file(lll_inproc_executable, hash) && !strcmp(hash, lll_inproc_exe_sha) &&
                           lll_inproc_hash_file(game, hash) && !strcmp(hash, lll_inproc_game_sha);
    lll_inproc_note(lll_inproc_supported ? "Stock game hashes verified; in-process filesystem, keyboard and pointer service ready (LuaJIT runtime, no helper process)"
                                         : "Refused: installed game hashes do not match this service build");
    return;
refused:
    lll_inproc_root[0] = 0;
    lll_inproc_note("Refused: game paths unavailable");
}

static int lll_inproc_reserve(uint32_t needed) {
    uint32_t capacity;
    unsigned char *larger;
    if (needed > LLL_INPROC_MAX_REQUEST) return ERROR_MORE_DATA;
    if (needed <= lll_inproc_capacity) return 0;
    capacity = lll_inproc_capacity ? lll_inproc_capacity : 4096;
    while (capacity < needed) capacity = capacity > LLL_INPROC_MAX_REQUEST / 2 ? LLL_INPROC_MAX_REQUEST : capacity * 2;
    larger = realloc(lll_inproc_reply, capacity);
    if (!larger) return ERROR_NOT_ENOUGH_MEMORY;
    lll_inproc_reply = larger;
    lll_inproc_capacity = capacity;
    return 0;
}
/* A whole reply of fixed fields; 0 when the buffer cannot grow (the caller's request then fails like a lost pipe). */
static int lll_inproc_words(const uint32_t *words, uint32_t count) {
    if (lll_inproc_reserve(count * 4)) return 0;
    memcpy(lll_inproc_reply, words, count * 4); lll_inproc_length = count * 4;
    return 1;
}
static int lll_inproc_status(uint32_t nonce, uint32_t status) {
    uint32_t reply[2]; reply[0] = nonce; reply[1] = status;
    return lll_inproc_words(reply, 2);
}
/* steam_files.c text(): a length and UTF-8 bytes; an unencodable name is empty. */
static int lll_inproc_text(uint32_t *at, const wchar_t *value) {
    int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, NULL, 0, NULL, NULL);
    uint32_t size = length > 0 ? (uint32_t)length - 1 : 0;
    if (lll_inproc_reserve(*at + 4 + size + 1)) return 0;
    memcpy(lll_inproc_reply + *at, &size, 4); *at += 4;
    if (size) WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, (char *)lll_inproc_reply + *at, (int)size + 1, NULL, NULL);
    *at += size;
    return 1;
}

/* steam_service.c decode_path: a request carrying exactly one path. */
static int lll_inproc_decode_path(const unsigned char *bytes, uint32_t size, uint32_t path_size, wchar_t path[32768]) {
    int count = 0;
    if (path_size && path_size <= 32760 && size == 12 + path_size && !memchr(bytes + 12, 0, path_size))
        count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)bytes + 12, (int)path_size, path, 32767);
    if (count <= 0) return 0;
    path[count] = 0;
    for (int index = 0; index < count; ++index) if (path[index] == L'/') path[index] = L'\\';
    return 1;
}
/* steam_files.c lll_steam_request's path rule: a path followed by an optional body. */
static int lll_inproc_request_path(const unsigned char *bytes, uint32_t size, uint32_t path_size, wchar_t path[32768]) {
    int count;
    if (!path_size || path_size > 32760 || path_size > size - 12 || memchr(bytes + 12, 0, path_size)) return 0;
    count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)bytes + 12, (int)path_size, path, 32767);
    if (count <= 0) return 0;
    path[count] = 0;
    for (int index = 0; index < count; ++index) if (path[index] == L'/') path[index] = L'\\';
    return 1;
}

static int lll_inproc_handshake(void) {
    uint32_t header[3], at = 12;
    lll_inproc_start();
    header[0] = 0; header[1] = lll_inproc_supported ? 0 : ERROR_REVISION_MISMATCH; header[2] = lll_inproc_pid;
    if (lll_inproc_reserve(at)) return 0;
    memcpy(lll_inproc_reply, header, sizeof(header));
    if (!lll_inproc_text(&at, lll_inproc_executable) || !lll_inproc_text(&at, lll_inproc_root)) return 0;
    lll_inproc_length = at;
    return 1;
}

/* steam_service.c send_listing. */
static int lll_inproc_listing(uint32_t nonce, const wchar_t *path) {
    uint32_t header[2] = {nonce, ERROR_INVALID_DATA}, length = 8, count = 0;
    WIN32_FIND_DATAW data;
    HANDLE handle;
    static wchar_t pattern[32768];
    DWORD status;
    if (!path) return lll_inproc_words(header, 2);
    status = lll_inproc_reserve(length);
    if (status) { header[1] = status; return lll_inproc_words(header, 2); }
    swprintf_s(pattern, 32768, L"%s\\*", path);
    handle = FindFirstFileW(pattern, &data);
    if (handle == INVALID_HANDLE_VALUE) { header[1] = GetLastError(); return lll_inproc_words(header, 2); }
    do {
        uint32_t fields[6], name_size;
        char name[4 * MAX_PATH];
        int encoded;
        if (!wcscmp(data.cFileName, L".") || !wcscmp(data.cFileName, L"..")) continue;
        if (++count > 100000) { status = ERROR_MORE_DATA; goto finished; }
        encoded = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, data.cFileName, -1, name, (int)sizeof(name), NULL, NULL);
        name_size = encoded > 0 ? (uint32_t)encoded - 1 : 0;
        status = lll_inproc_reserve(length + 24 + name_size);
        if (status) goto finished;
        fields[0] = data.dwFileAttributes;
        fields[1] = data.nFileSizeHigh; fields[2] = data.nFileSizeLow;
        fields[3] = data.ftLastWriteTime.dwHighDateTime; fields[4] = data.ftLastWriteTime.dwLowDateTime;
        fields[5] = name_size;
        memcpy(lll_inproc_reply + length, fields, sizeof(fields)); length += 24;
        memcpy(lll_inproc_reply + length, name, name_size); length += name_size;
    } while (FindNextFileW(handle, &data));
    status = GetLastError() == ERROR_NO_MORE_FILES ? 0 : ERROR_MORE_DATA;
finished:
    FindClose(handle);
    header[1] = status;
    memcpy(lll_inproc_reply, header, sizeof(header));
    lll_inproc_length = length;
    return 1;
}

static int lll_inproc_stat(uint32_t nonce, const wchar_t *path) {
    uint32_t reply[7] = {0};
    WIN32_FILE_ATTRIBUTE_DATA data;
    reply[0] = nonce; reply[1] = ERROR_INVALID_DATA;
    if (path) {
        if (GetFileAttributesExW(path, GetFileExInfoStandard, &data)) {
            reply[1] = 0; reply[2] = data.dwFileAttributes;
            reply[3] = data.nFileSizeHigh; reply[4] = data.nFileSizeLow;
            reply[5] = data.ftLastWriteTime.dwHighDateTime; reply[6] = data.ftLastWriteTime.dwLowDateTime;
            return lll_inproc_words(reply, 7);
        }
        reply[1] = GetLastError();
    }
    return lll_inproc_words(reply, 2);
}

/* steam_files.c start_watch. */
static void lll_inproc_start_watch(LLLInprocWatch *watch) {
    static wchar_t path[32768];
    wchar_t *end;
    watch->ancestor = 0;
    wcscpy_s(path, 32768, watch->path);
    for (;;) {
        watch->handle = FindFirstChangeNotificationW(path, watch->ancestor ? FALSE : TRUE,
            watch->ancestor ? FILE_NOTIFY_CHANGE_DIR_NAME :
            (FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE));
        if (watch->handle != INVALID_HANDLE_VALUE) return;
        end = wcsrchr(path, L'\\'); if (!end || end - path < 3) return; *end = 0; watch->ancestor = 1;
    }
}
static void lll_inproc_close_watches(void) {
    for (uint32_t index = 0; index < lll_inproc_watch_count; ++index) {
        if (lll_inproc_watches[index].handle != INVALID_HANDLE_VALUE && lll_inproc_watches[index].handle)
            FindCloseChangeNotification(lll_inproc_watches[index].handle);
        free(lll_inproc_watches[index].path);
        ZeroMemory(&lll_inproc_watches[index], sizeof(lll_inproc_watches[index]));
    }
    lll_inproc_watch_count = 0;
}

/* steam_files.c lll_steam_request: mkdir, watch, atomic write, hash, unwatch; no transport files. */
static int lll_inproc_request(uint32_t nonce, uint32_t operation, const unsigned char *bytes, uint32_t size, uint32_t path_size) {
    static wchar_t path[32768], temporary[32768];
    uint32_t reply[4] = {nonce, ERROR_INVALID_DATA, 0, 0}, status;
    if (!lll_inproc_supported) { reply[1] = ERROR_REVISION_MISMATCH; return lll_inproc_words(reply, 2); }
    if (!lll_inproc_request_path(bytes, size, path_size, path)) return lll_inproc_words(reply, 2);
    if (operation == 3) {
        status = CreateDirectoryW(path, NULL) ? 0 : GetLastError();
        reply[1] = status == ERROR_ALREADY_EXISTS ? 0 : status;
    } else if (operation == 4) {
        uint32_t index;
        for (index = 0; index < lll_inproc_watch_count; ++index)
            if (lll_inproc_watches[index].path && !_wcsicmp(lll_inproc_watches[index].path, path)) break;
        if (index == lll_inproc_watch_count) {
            for (index = 0; index < lll_inproc_watch_count; ++index) if (!lll_inproc_watches[index].path) break;
        }
        if (index < LLL_INPROC_MAX_WATCHES && (index == lll_inproc_watch_count || !lll_inproc_watches[index].path)) {
            lll_inproc_watches[index].path = _wcsdup(path);
            if (lll_inproc_watches[index].path) {
                lll_inproc_watches[index].generation = 1; lll_inproc_start_watch(&lll_inproc_watches[index]);
                if (index == lll_inproc_watch_count) ++lll_inproc_watch_count;
            }
        }
        reply[1] = index < lll_inproc_watch_count && lll_inproc_watches[index].path ? 0 : ERROR_TOO_MANY_OPEN_FILES;
        reply[2] = index + 1;
        return lll_inproc_words(reply, 3);
    } else if (operation == 5) {
        HANDLE file;
        DWORD written, length = size - 12 - path_size;
        swprintf_s(temporary, 32768, L"%s.lll-steam.tmp", path);
        file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
        if (file == INVALID_HANDLE_VALUE) { reply[1] = GetLastError(); return lll_inproc_words(reply, 2); }
        status = WriteFile(file, bytes + 12 + path_size, length, &written, NULL) && written == length ? 0 : ERROR_WRITE_FAULT;
        CloseHandle(file);
        if (!status && !MoveFileExW(temporary, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) status = GetLastError();
        if (status) DeleteFileW(temporary);
        reply[1] = status;
    } else if (operation == 6) {
        uint64_t value = lll_inproc_resource_hash(bytes + 12 + path_size, (size_t)size - 12 - path_size);
        reply[1] = 0; memcpy(reply + 2, &value, 8);
        return lll_inproc_words(reply, 4);
    } else if (operation == 7) {
        for (uint32_t index = 0; index < lll_inproc_watch_count; ++index) {
            if (lll_inproc_watches[index].path && !_wcsicmp(lll_inproc_watches[index].path, path)) {
                if (lll_inproc_watches[index].handle != INVALID_HANDLE_VALUE) FindCloseChangeNotification(lll_inproc_watches[index].handle);
                lll_inproc_watches[index].handle = INVALID_HANDLE_VALUE;
                free(lll_inproc_watches[index].path); lll_inproc_watches[index].path = NULL; ++lll_inproc_watches[index].generation;
                break;
            }
        }
        reply[1] = 0;
    } else reply[1] = ERROR_INVALID_FUNCTION;
    return lll_inproc_words(reply, 2);
}

/* steam_files.c lll_steam_poll with inline events, then the service's op 8 reply. */
static int lll_inproc_poll(uint32_t nonce) {
    uint32_t reply[LLL_INPROC_MAX_WATCHES + 4];
    if (lll_inproc_supported) {
        for (uint32_t index = 0; index < lll_inproc_watch_count; ++index) {
            LLLInprocWatch *watch = &lll_inproc_watches[index];
            DWORD result;
            if (!watch->path || watch->handle == INVALID_HANDLE_VALUE) continue;
            result = WaitForSingleObject(watch->handle, 0);
            if (result == WAIT_TIMEOUT) continue;
            ++watch->generation;
            if (result != WAIT_OBJECT_0 || !FindNextChangeNotification(watch->handle) || watch->ancestor) {
                FindCloseChangeNotification(watch->handle); watch->handle = INVALID_HANDLE_VALUE;
                lll_inproc_start_watch(watch);
            }
        }
    }
    reply[0] = nonce; reply[1] = 0; reply[2] = lll_inproc_pid; reply[3] = lll_inproc_watch_count;
    for (uint32_t index = 0; index < lll_inproc_watch_count; ++index) reply[index + 4] = lll_inproc_watches[index].generation;
    return lll_inproc_words(reply, 4 + lll_inproc_watch_count);
}

/* ---- Pointer ----
 * Runs on the game window's thread while a lease is active. Only packets the game has already been handed are read;
 * CallNextHookEx passes every message on unchanged. */
static LRESULT CALLBACK lll_inproc_observe(int code, WPARAM wp, LPARAM lp) {
    if (code == HC_ACTION && wp == PM_REMOVE && lp && InterlockedCompareExchange(&lll_pointer_state.active, 0, 0)) {
        const MSG *message = (const MSG *)lp;
        if (message->message == WM_INPUT) {
            HWND foreground;
            DWORD pid = lll_pointer_foreground_pid(&foreground);
            if (lll_pointer_owner(lll_pointer_state.pid, pid)) {
                RAWINPUT input;
                UINT capacity = sizeof(input);
                UINT length = GetRawInputData((HRAWINPUT)message->lParam, RID_INPUT, &input, &capacity, sizeof(RAWINPUTHEADER));
                if (length != (UINT)-1) {
                    LLLSteamPointerMotion motion;
                    if (lll_pointer_decode_motion(&input, length, lll_pointer_state.pid, pid, &motion) &&
                        (motion.wheel || motion.dx || motion.dy)) lll_pointer_add_motion(&motion);
                }
            } else lll_pointer_take_motion();
        }
    }
    return CallNextHookEx(NULL, code, wp, lp);
}
/* Stands in for steam_pointer.c lll_pointer_start(session pid). The game's mouse registration decides the reader:
 * none, the helper's own sink; otherwise the read-only hook on the thread that receives the game's packets. */
static int lll_inproc_pointer_start(void) {
    RAWINPUTDEVICE mouse;
    HWND target;
    DWORD owner = 0, thread;
    int registered, ok;
    if (!lll_inproc_pid) return 0;
    if (lll_inproc_hook) {
        if (!InterlockedCompareExchange(&lll_pointer_state.active, 0, 0)) {
            lll_pointer_state.pid = lll_inproc_pid; InterlockedExchange(&lll_pointer_state.active, 1);
        }
        return 1;
    }
    if (lll_pointer_state.thread) return lll_pointer_start(lll_inproc_pid);
    registered = lll_pointer_registration(&mouse);
    if (registered < 0) return 0;
    if (!registered) {
        ok = lll_pointer_start(lll_inproc_pid);
        lll_inproc_note(ok ? "Pointer lease: own RawInput sink (this process had no mouse registration)"
                           : "Pointer lease unavailable: own RawInput sink did not start");
        return ok;
    }
    target = mouse.hwndTarget ? mouse.hwndTarget : GetForegroundWindow();
    thread = target ? GetWindowThreadProcessId(target, &owner) : 0;
    if (!thread || owner != lll_inproc_pid) return 0;
    AcquireSRWLockExclusive(&lll_pointer_lifecycle);
    lll_pointer_state.pid = lll_inproc_pid;
    lll_inproc_hook = SetWindowsHookExW(WH_GETMESSAGE, lll_inproc_observe, NULL, thread);
    if (lll_inproc_hook) InterlockedExchange(&lll_pointer_state.active, 1);
    else lll_pointer_state.pid = 0;
    ReleaseSRWLockExclusive(&lll_pointer_lifecycle);
    if (lll_inproc_hook) lll_inproc_note("Pointer lease: reading the game's RawInput (flags 0x%lx, %s target) through a WH_GETMESSAGE hook on thread %lu",
                                         (unsigned long)mouse.dwFlags, mouse.hwndTarget ? "window" : "focus", (unsigned long)thread);
    else lll_inproc_note("Pointer lease unavailable: WH_GETMESSAGE hook refused (%lu)", (unsigned long)GetLastError());
    return lll_inproc_hook != NULL;
}
/* Stands in for lll_pointer_release(). A hook that will not come off stays inert (inactive) and is retried later. */
static int lll_inproc_pointer_release(void) {
    if (!lll_inproc_hook) return lll_pointer_release();
    AcquireSRWLockExclusive(&lll_pointer_lifecycle);
    InterlockedExchange(&lll_pointer_state.active, 0);
    if (UnhookWindowsHookEx(lll_inproc_hook)) { lll_inproc_hook = NULL; lll_pointer_state.pid = 0; }
    ReleaseSRWLockExclusive(&lll_pointer_lifecycle);
    lll_pointer_take_motion();
    return 1;
}

static int lll_inproc_pointer(uint32_t nonce, uint32_t operation) {
    uint32_t reply[11] = {0}, count = 2;
    reply[0] = nonce;
    if (operation == 11) {
        if (!lll_inproc_pointer_release()) reply[1] = ERROR_BUSY;
    } else if (operation == 10) {
        LLLSteamPointerSnapshot snapshot;
        if (!lll_inproc_pointer_start() || !lll_pointer_snapshot(&snapshot)) reply[1] = ERROR_NOT_READY;
        else { memcpy(reply + 2, &snapshot, sizeof(snapshot)); count = 2 + (uint32_t)sizeof(snapshot) / 4; }
    } else {
        LLLSteamPointerSample snapshot;
        if (!lll_inproc_pointer_start() || !lll_pointer_snapshot_extended(&snapshot)) reply[1] = ERROR_NOT_READY;
        else { memcpy(reply + 2, &snapshot, sizeof(snapshot)); count = 2 + (uint32_t)sizeof(snapshot) / 4; }
    }
    return lll_inproc_words(reply, count);
}

/* steam_service.c send_keyboard, with this process as the session. */
static int lll_inproc_keyboard(uint32_t nonce, uint32_t operation, const unsigned char *bytes, uint32_t size, uint32_t path_size) {
    static const char path[] = "keyboard-v1";
    uint32_t reply[22] = {0}, fields[10] = {0}, count = 2, extra;
    reply[0] = nonce; reply[1] = ERROR_INVALID_DATA;
    if (path_size != sizeof(path) - 1 || size < 12 + path_size || memcmp(bytes + 12, path, sizeof(path) - 1)) goto done;
    extra = size - 12 - path_size;
    if ((operation == 16 && extra != 40) || (operation == 17 && extra != 12) || (operation == 18 && extra != 8)) goto done;
    memcpy(fields, bytes + 12 + path_size, extra);
    if (operation == 16) {
        LLLSteamKeyboardReply accepted;
        if (fields[0] != LLL_KEYBOARD_VERSION) { reply[1] = ERROR_REVISION_MISMATCH; goto done; }
        reply[1] = lll_keyboard_acquire(lll_inproc_pid, lll_inproc_executable, fields[1], fields + 2, &accepted);
        if (!reply[1]) { memcpy(reply + 2, &accepted, sizeof(accepted)); count = 14; }
    } else if (operation == 17) {
        LLLSteamKeyboardSample keyboard;
        LLLSteamPointerSample pointer;
        if (fields[2] > 1) { reply[1] = ERROR_INVALID_PARAMETER; goto done; }
        ZeroMemory(&pointer, sizeof(pointer));
        reply[1] = lll_keyboard_snapshot(lll_inproc_pid, fields[0], fields[1], &keyboard);
        if (reply[1]) goto done;
        if (keyboard.state == LLL_KEYBOARD_ACTIVE) {
            if (!lll_inproc_pointer_start() || !lll_pointer_snapshot_extended(&pointer)) { reply[1] = ERROR_NOT_READY; goto done; }
            if (!fields[2]) { pointer.dx = 0; pointer.dy = 0; }
            keyboard.state = lll_keyboard_confirm(lll_inproc_pid, fields[0], fields[1]);
            if (keyboard.state != LLL_KEYBOARD_ACTIVE) { ZeroMemory(&pointer, sizeof(pointer)); ZeroMemory(keyboard.keys, sizeof(keyboard.keys)); }
        }
        memcpy(reply + 2, &pointer, sizeof(pointer));
        memcpy(reply + 11, &keyboard, sizeof(keyboard));
        count = 22;
    } else {
        uint32_t generation = 0;
        reply[1] = lll_keyboard_release(lll_inproc_pid, lll_inproc_executable, fields[0], fields[1], &generation);
        if (!reply[1]) { reply[2] = LLL_KEYBOARD_VERSION; reply[3] = fields[0]; reply[4] = generation; count = 5; }
    }
done:
    return lll_inproc_words(reply, count);
}

/* Ops 13-15. The request's path rules and id format are the service's; no job is ever accepted. */
static int lll_inproc_screenshot(uint32_t nonce, uint32_t operation, const wchar_t *path) {
    uint32_t status = ERROR_INVALID_DATA;
    if (path && operation == 13) {
        status = ERROR_NOT_SUPPORTED;
        if (!lll_inproc_screenshot_noted) {
            lll_inproc_screenshot_noted = 1;
            lll_inproc_note("Screenshot requests refused: Windows.Graphics.Capture is not available under Wine");
        }
    } else if (path) {
        status = wcsnlen_s(path, 33) == 32 ? ERROR_NOT_FOUND : ERROR_INVALID_PARAMETER;
        for (unsigned index = 0; status == ERROR_NOT_FOUND && index < 32; ++index)
            if (!((path[index] >= L'0' && path[index] <= L'9') || (path[index] >= L'a' && path[index] <= L'f'))) status = ERROR_INVALID_PARAMETER;
    }
    return lll_inproc_status(nonce, status);
}

static void lll_inproc_stop_leases(void) {
    lll_keyboard_cancel_all();
    lll_inproc_pointer_release();
    lll_keyboard_shutdown();
    lll_inproc_close_watches();
}

/* steam_service.c dispatch: same order, same fatal cases (0 = the service would drop the connection). */
static int lll_inproc_dispatch(const unsigned char *bytes, uint32_t size) {
    static wchar_t path[32768];
    uint32_t nonce, operation, path_size;
    if (size < 12) return 0;
    memcpy(&nonce, bytes, 4); memcpy(&operation, bytes + 4, 4); memcpy(&path_size, bytes + 8, 4);
    if (operation == 0) {
        if (size != 12 || nonce != 0 || path_size != 0) return 0;
        return lll_inproc_handshake();
    }
    if (!lll_inproc_started) return 0; /* The service accepts nothing before its client's handshake. */
    if (operation == 10 || operation == 11 || operation == 12) return lll_inproc_pointer(nonce, operation);
    if (operation == 8) return lll_inproc_poll(nonce);
    if (operation == 9) {
        lll_inproc_stop_leases();
        lll_inproc_note("Closed by LLL");
        return lll_inproc_status(nonce, 0);
    }
    if (!nonce || path_size > size - 12) return 0;
    if (operation >= 16 && operation <= 18) return lll_inproc_keyboard(nonce, operation, bytes, size, path_size);
    if (operation == 13 || operation == 14 || operation == 15)
        return lll_inproc_screenshot(nonce, operation, lll_inproc_decode_path(bytes, size, path_size, path) ? path : NULL);
    if (operation == 1) return lll_inproc_listing(nonce, lll_inproc_decode_path(bytes, size, path_size, path) ? path : NULL);
    if (operation == 2) return lll_inproc_stat(nonce, lll_inproc_decode_path(bytes, size, path_size, path) ? path : NULL);
    return lll_inproc_request(nonce, operation, bytes, size, path_size);
}

/* The transport's call: request bytes in, reply bytes out (valid until the next call). 0 means the request broke the
 * protocol: like the service, the connection is then gone for good and every lease is released. */
static uint32_t lll_inproc_exchange(const unsigned char *request, uint32_t size, const unsigned char **reply) {
    if (reply) *reply = NULL;
    if (lll_inproc_broken) return 0;
    lll_inproc_length = 0;
    if (!request || !reply || size > LLL_INPROC_MAX_REQUEST || !lll_inproc_dispatch(request, size) || lll_inproc_length < 8) {
        lll_inproc_broken = 1;
        lll_inproc_stop_leases();
        lll_inproc_note("Refused a malformed request; service stopped");
        return 0;
    }
    *reply = lll_inproc_reply;
    return lll_inproc_length;
}

/* nativeinfo's read_memory and module_base for LLL's font: this process only, bad addresses give 0. */
static int lll_inproc_read_memory(uint64_t address, void *out, uint32_t size) {
    SIZE_T done = 0;
    if (!out || !size || size > 0x1000000u || address < 0x10000u || address >= UINT64_C(0x800000000000) - size) return 0;
    return ReadProcessMemory(GetCurrentProcess(), (LPCVOID)(uintptr_t)address, out, size, &done) && done == size;
}
static uint64_t lll_inproc_module_base(const char *name) {
    return name && name[0] ? (uint64_t)(uintptr_t)GetModuleHandleA(name) : 0;
}
