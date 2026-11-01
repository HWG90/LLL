/* Standalone contracts for the in-process service (steam_inproc.c), run under Wine:
 *   test_steam_inproc.exe <service exe> <game root>
 * 1. Its pins and resource hash are steam_files.c's; the font reader reads this process only.
 * 2. The same request sequence sent to the real external service (its pipes) and to lll_inproc_exchange gives
 *    byte-identical replies, except screenshot requests (in-process refuses with ERROR_NOT_SUPPORTED).
 * 3. Pointer: with no mouse registration the helper's own sink runs; with one, the read-only hook goes on the
 *    registering window's thread, the registration is unchanged, and release removes the hook.
 * 4. A malformed request stops the service for good.
 * Tests access implementation statics only in this separate executable. */
#define LLL_INPROC_PATHS test_paths
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
static wchar_t test_root[32768];
static int test_paths(wchar_t executable[32768], wchar_t game[32768]) {
    swprintf_s(executable, 32768, L"%s\\bin\\helldivers2.exe", test_root);
    swprintf_s(game, 32768, L"%s\\data\\game\\game.dll", test_root);
    return 1;
}
#include "steam_inproc.c"
#include "steam_files.c"

static int failures;
#define CHECK(condition, ...) do { if (!(condition)) { ++failures; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static HANDLE service_request = INVALID_HANDLE_VALUE, service_response = INVALID_HANDLE_VALUE;
static unsigned char request[70000], service_reply[1 << 20];
static uint32_t nonce;

static int io(HANDLE pipe, void *bytes, DWORD size, int writing) {
    unsigned char *at = bytes;
    while (size) {
        DWORD count = 0;
        if (!(writing ? WriteFile(pipe, at, size, &count, NULL) : ReadFile(pipe, at, size, &count, NULL)) || !count) return 0;
        at += count; size -= count;
    }
    return 1;
}
static uint32_t service_exchange(const unsigned char *bytes, uint32_t size) {
    uint32_t count = 0;
    if (!io(service_request, &size, 4, 1) || !io(service_request, (void *)bytes, size, 1) || !io(service_response, &count, 4, 0)) return 0;
    if (count > sizeof(service_reply) || !io(service_response, service_reply, count, 0)) return 0;
    return count;
}
static uint32_t build(uint32_t serial, uint32_t operation, const char *path, uint32_t path_size, const void *body, uint32_t body_size) {
    memcpy(request, &serial, 4); memcpy(request + 4, &operation, 4); memcpy(request + 8, &path_size, 4);
    if (path_size) memcpy(request + 12, path, path_size);
    if (body_size) memcpy(request + 12 + path_size, body, body_size);
    return 12 + path_size + body_size;
}
static void dump(const char *label, const unsigned char *bytes, uint32_t size) {
    printf("  %s (%u):", label, size);
    for (uint32_t index = 0; index < size && index < 96; ++index) printf(" %02x", bytes[index]);
    printf("\n");
}
/* Both answer; returns the in-process status (or 0xffffffff when either side failed). */
static uint32_t both(const char *label, uint32_t operation, const char *path, const void *body, uint32_t body_size, int compare) {
    uint32_t size, expected, actual, status = 0xffffffffu;
    const unsigned char *reply = NULL;
    uint32_t serial = operation == 0 ? 0 : ++nonce;
    size = build(serial, operation, path, path ? (uint32_t)strlen(path) : 0, body, body_size);
    expected = service_exchange(request, size);
    actual = lll_inproc_exchange(request, size, &reply);
    CHECK(expected >= 8, "%s: service gave no reply", label);
    CHECK(actual >= 8, "%s: in-process gave no reply", label);
    if (expected < 8 || actual < 8) return status;
    memcpy(&status, reply + 4, 4);
    if (compare && (expected != actual || memcmp(service_reply, reply, actual))) {
        ++failures; printf("FAIL %s: replies differ\n", label);
        dump("service", service_reply, expected); dump("inproc", reply, actual);
    } else printf("ok   %s (status %u, %u bytes)\n", label, status, actual);
    return status;
}
static uint32_t inproc(uint32_t serial, uint32_t operation, const char *path, const void *body, uint32_t body_size, const unsigned char **reply) {
    uint32_t size = build(serial, operation, path, path ? (uint32_t)strlen(path) : 0, body, body_size);
    return lll_inproc_exchange(request, size, reply);
}

static HWND game_window;
static HANDLE game_ready;
static volatile LONG game_messages;
static DWORD WINAPI game_thread(void *unused) {
    WNDCLASSW type;
    RAWINPUTDEVICE device;
    MSG message;
    (void)unused;
    ZeroMemory(&type, sizeof(type));
    type.lpfnWndProc = DefWindowProcW; type.hInstance = GetModuleHandleW(NULL); type.lpszClassName = L"LLLInprocTestGame";
    RegisterClassW(&type);
    game_window = CreateWindowExW(0, type.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, type.hInstance, NULL);
    device.usUsagePage = 1; device.usUsage = 2; device.dwFlags = RIDEV_INPUTSINK; device.hwndTarget = game_window;
    if (!game_window || !RegisterRawInputDevices(&device, 1, sizeof(device))) game_window = NULL;
    SetEvent(game_ready);
    while (GetMessageW(&message, NULL, 0, 0) > 0) { InterlockedIncrement(&game_messages); DispatchMessageW(&message); }
    device.dwFlags = RIDEV_REMOVE; device.hwndTarget = NULL;
    RegisterRawInputDevices(&device, 1, sizeof(device));
    if (game_window) DestroyWindow(game_window);
    return 0;
}

int wmain(int count, wchar_t **arguments) {
    wchar_t command[70000], ready[160], temp[MAX_PATH], folder[MAX_PATH];
    char base[4 * MAX_PATH], path[4 * MAX_PATH], token[64];
    unsigned char bytes[64];
    const unsigned char *reply;
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    HANDLE event = NULL, thread;
    RAWINPUTDEVICE registered;
    uint32_t status;
    uint64_t base_address;
    static const unsigned char mask[32] = {0x00,0x33,0x1f,0x08,0xff,0xe1,0xff,0x03,0xfe,0xff,0xff,0x27,0xff,0xff,0xff,0xf7,
                                           0xff,0x00,0x03,0x00,0x3f,0x00,0x00,0xfc,0x01,0x00,0x00,0xf8,0x04,0x00,0x00,0x00};
    if (count != 3) { printf("usage: test_steam_inproc.exe <service exe> <game root>\n"); return 2; }
    wcscpy_s(test_root, 32768, arguments[2]);

    /* 1. Pins, hash, font reader. */
    CHECK(!strcmp(EXE_SHA, lll_inproc_exe_sha) && !strcmp(GAME_SHA, lll_inproc_game_sha), "pins differ from steam_files.c");
    for (unsigned length = 0; length < 40; ++length) {
        for (unsigned index = 0; index < length; ++index) bytes[index] = (unsigned char)(index * 37 + length);
        CHECK(resource_hash(bytes, length) == lll_inproc_resource_hash(bytes, length), "resource hash differs at length %u", length);
    }
    CHECK(lll_inproc_resource_hash((const unsigned char *)"core/wwise/lua/wwise_flow_callbacks", 35) == UINT64_C(0x7251fdd9bb62480a), "known resource hash");
    base_address = lll_inproc_module_base("kernel32.dll");
    CHECK(base_address && lll_inproc_read_memory(base_address, bytes, 2) && bytes[0] == 'M' && bytes[1] == 'Z', "module_base/read_memory of kernel32");
    CHECK(!lll_inproc_module_base("no-such-module.dll") && !lll_inproc_module_base(""), "missing module gives 0");
    CHECK(!lll_inproc_read_memory(0x1000, bytes, 4) && !lll_inproc_read_memory(UINT64_C(0x7ffffffffff0), bytes, 32), "bad addresses give 0");

    /* 2. The real service. */
    sprintf_s(token, sizeof(token), "lll_inproc_test_%08lx%08lx", (unsigned long)GetCurrentProcessId(), (unsigned long)GetTickCount());
    swprintf_s(command, 70000, L"\"%s\" --game \"%s\" --pipe %S", arguments[1], test_root, token);
    ZeroMemory(&startup, sizeof(startup)); startup.cb = sizeof(startup);
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) { printf("FAIL cannot start the service\n"); return 1; }
    swprintf_s(ready, 160, L"Local\\LLL_Steam_Ready_%S", token);
    for (int wait = 0; wait < 300 && !event; ++wait) { event = OpenEventW(SYNCHRONIZE, FALSE, ready); if (!event) Sleep(50); }
    if (!event || WaitForSingleObject(event, 15000) != WAIT_OBJECT_0) { printf("FAIL service never became ready (hashes refused?)\n"); return 1; }
    swprintf_s(command, 70000, L"\\\\.\\pipe\\%S_request", token);
    service_request = CreateFileW(command, GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    swprintf_s(command, 70000, L"\\\\.\\pipe\\%S_response", token);
    for (int wait = 0; wait < 100 && service_response == INVALID_HANDLE_VALUE; ++wait) {
        service_response = CreateFileW(command, GENERIC_READ, 0, NULL, OPEN_EXISTING, 0, NULL);
        if (service_response == INVALID_HANDLE_VALUE) Sleep(20);
    }
    if (service_request == INVALID_HANDLE_VALUE || service_response == INVALID_HANDLE_VALUE) { printf("FAIL cannot open the service pipes\n"); return 1; }

    GetTempPathW(MAX_PATH, temp);
    swprintf_s(folder, MAX_PATH, L"%slll-inproc-%08lx", temp, (unsigned long)GetTickCount());
    WideCharToMultiByte(CP_UTF8, 0, folder, -1, base, sizeof(base), NULL, NULL);
    for (char *at = base; *at; ++at) if (*at == '\\') *at = '/';

    CHECK(both("handshake", 0, NULL, NULL, 0, 1) == 0, "handshake accepted (stock hashes)");
    CHECK(both("mkdir new", 3, base, NULL, 0, 1) == 0, "mkdir");
    CHECK(both("mkdir again", 3, base, NULL, 0, 1) == 0, "mkdir existing");
    sprintf_s(path, sizeof(path), "%s/a", base); both("mkdir a", 3, path, NULL, 0, 1);
    sprintf_s(path, sizeof(path), "%s/a/x.lua", base);
    CHECK(both("write x", 5, path, "return 1", 8, 1) == 0, "write");
    both("stat x", 2, path, NULL, 0, 1);
    sprintf_s(path, sizeof(path), "%s/a/missing.lua", base); both("stat missing", 2, path, NULL, 0, 1);
    sprintf_s(path, sizeof(path), "%s/a", base); both("list a", 1, path, NULL, 0, 1);
    both("list a with a body", 1, path, "x", 1, 1);
    sprintf_s(path, sizeof(path), "%s/none", base); both("list missing", 1, path, NULL, 0, 1);
    both("hash", 6, "hash", "core/wwise/lua/wwise_flow_callbacks", 35, 1);
    both("hash empty", 6, "hash", NULL, 0, 1);
    sprintf_s(path, sizeof(path), "%s/a", base);
    both("watch a", 4, path, NULL, 0, 1);
    both("watch a again", 4, path, NULL, 0, 1);
    both("poll", 8, "poll", NULL, 0, 1);
    sprintf_s(path, sizeof(path), "%s/a/y.lua", base);
    both("write y", 5, path, "return 2", 8, 1);
    Sleep(600);
    both("poll after change", 8, "poll", NULL, 0, 1);
    sprintf_s(path, sizeof(path), "%s/a", base);
    both("unwatch a", 7, path, NULL, 0, 1);
    both("poll after unwatch", 8, "poll", NULL, 0, 1);
    both("watch a after unwatch", 4, path, NULL, 0, 1);
    both("invalid path", 3, "", NULL, 0, 1);
    both("unknown operation", 19, "x", NULL, 0, 1);
    both("keyboard wrong path", 16, "keyboard", bytes, 40, 1);
    memset(bytes, 0, 40); bytes[0] = 1; bytes[4] = 1; memcpy(bytes + 8, mask, 32);
    both("keyboard acquire (not the game)", 16, "keyboard-v1", bytes, 40, 1);
    memset(bytes, 0, 12); bytes[0] = 1;
    both("keyboard snapshot unknown", 17, "keyboard-v1", bytes, 12, 1);
    both("keyboard release unknown", 18, "keyboard-v1", bytes, 8, 1);
    both("pointer snapshot", 10, "pointer", NULL, 0, 1);
    both("pointer extended", 12, "pointer-v1", NULL, 0, 1);
    both("pointer release", 11, "pointer", NULL, 0, 1);
    status = both("screenshot request", 13, "C:/users/x/Screenshots/a.png", NULL, 0, 0);
    CHECK(status == ERROR_NOT_SUPPORTED, "screenshot request refused with ERROR_NOT_SUPPORTED (got %u)", status);
    both("screenshot status bad id", 14, "xyz", NULL, 0, 1);
    both("screenshot status unknown", 14, "0123456789abcdef0123456789abcdef", NULL, 0, 1);
    both("screenshot cancel unknown", 15, "0123456789abcdef0123456789abcdef", NULL, 0, 1);
    both("close", 9, "close", NULL, 0, 1);
    both("poll after close", 8, "poll", NULL, 0, 1);
    CloseHandle(service_request); CloseHandle(service_response);
    WaitForSingleObject(process.hProcess, 5000);

    /* 3. Pointer readers. Nothing is registered yet: the helper's own sink. */
    CHECK(inproc(++nonce, 10, "pointer", NULL, 0, &reply) == 36, "own sink snapshot");
    CHECK(lll_pointer_state.thread && !lll_inproc_hook, "own sink selected without a registration");
    CHECK(inproc(++nonce, 11, "pointer", NULL, 0, &reply) == 8 && !lll_pointer_state.thread, "own sink released");
    game_ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    thread = CreateThread(NULL, 0, game_thread, NULL, 0, NULL);
    WaitForSingleObject(game_ready, 5000);
    CHECK(game_window != NULL, "fixture registered its mouse sink");
    CHECK(inproc(++nonce, 12, "pointer-v1", NULL, 0, &reply) == 44, "observer snapshot");
    CHECK(lll_inproc_hook && !lll_pointer_state.thread && lll_pointer_state.active, "observer hook selected with a registration");
    PostMessageW(game_window, WM_INPUT, RIM_INPUT, 0);
    Sleep(200);
    CHECK(game_messages >= 1, "fixture thread still receives its messages");
    CHECK(lll_pointer_registration(&registered) == 1 && registered.hwndTarget == game_window, "registration unchanged under the hook");
    CHECK(inproc(++nonce, 11, "pointer", NULL, 0, &reply) == 8 && !lll_inproc_hook && !lll_pointer_state.active, "observer released");
    CHECK(lll_pointer_registration(&registered) == 1 && registered.hwndTarget == game_window, "registration unchanged after release");
    PostThreadMessageW(GetThreadId(thread), WM_QUIT, 0, 0);
    WaitForSingleObject(thread, 5000);

    /* 4. A malformed request ends the service. */
    CHECK(inproc(5, 0, NULL, NULL, 0, &reply) == 0 && reply == NULL, "handshake with a nonce is fatal");
    CHECK(inproc(++nonce, 8, "poll", NULL, 0, &reply) == 0, "nothing answers after a fatal request");

    printf(failures ? "%d FAILED\n" : "all in-process contracts passed\n", failures);
    return failures ? 1 : 0;
}
