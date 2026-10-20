#ifndef LLL_STEAM_SCREENSHOT_JOBS_H
#define LLL_STEAM_SCREENSHOT_JOBS_H
#include "steam_screenshot.h"
#define LLL_SCREENSHOT_PENDING 1u
#define LLL_SCREENSHOT_SUCCEEDED 2u
#define LLL_SCREENSHOT_FAILED 3u
#define LLL_SCREENSHOT_JOB_CANCELLED 4u
typedef struct LLLScreenshotJobStatus {
    uint32_t state,error,width,height,elapsed_ms;
    char id[33];
    wchar_t output_path[32768];
} LLLScreenshotJobStatus;
/* Serialized by the service exchange thread. No function waits for a worker,
 * except shutdown, called only after both client pipes have been closed. */
DWORD lll_screenshot_job_request(DWORD client_pid,const wchar_t *expected_executable,
                                 const wchar_t *output_path,LLLScreenshotJobStatus *status);
DWORD lll_screenshot_job_status(const wchar_t *id,LLLScreenshotJobStatus *status);
DWORD lll_screenshot_job_cancel(const wchar_t *id,LLLScreenshotJobStatus *status);
void lll_screenshot_jobs_cancel_all(void);
void lll_screenshot_jobs_shutdown(void);
#endif
