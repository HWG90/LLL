/* External WGC screenshot worker. No code is loaded into the game. */
#ifndef LLL_STEAM_SCREENSHOT_H
#define LLL_STEAM_SCREENSHOT_H
#include <windows.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Publication is linearized before the atomic, non-replacing handle rename.
 * Cancel may CAS OPEN -> CANCELLED without blocking the request thread.
 * Once PUBLISHING wins, a cancellation waits for worker retirement and may
 * observe success. No terminal reply is valid before the worker has exited. */
#define LLL_SCREENSHOT_OPEN 0
#define LLL_SCREENSHOT_CANCELLED 1
#define LLL_SCREENSHOT_PUBLISHING 2
#define LLL_SCREENSHOT_PUBLISHED 3

typedef struct LLLScreenshotRequest {
    DWORD pid;
    FILETIME created;
    const wchar_t *executable;
    const wchar_t *output_path;
    HANDLE cancel_event;
    volatile LONG *publication;
} LLLScreenshotRequest;

typedef struct LLLScreenshotResult {
    uint32_t error;
    uint32_t width;
    uint32_t height;
    uint32_t elapsed_ms;
} LLLScreenshotResult;

/* Called only on one owned job thread; releases WGC/WIC/COM resources before
 * returning. Returns a Windows error/HRESULT (zero on published success). */
DWORD lll_steam_screenshot_capture(const LLLScreenshotRequest *request,
                                 LLLScreenshotResult *result);

#ifdef __cplusplus
}
#endif
#endif
