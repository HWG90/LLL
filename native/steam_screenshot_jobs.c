#include "steam_screenshot_jobs.h"
#include <bcrypt.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef struct LLLScreenshotOwnedJob {
    HANDLE thread,cancel,guard,parents[32];
    unsigned parent_count;
    volatile LONG publication;
    LLLScreenshotRequest request;
    LLLScreenshotResult result;
    DWORD returned;
    char id[33];
    wchar_t executable[32768],output[32768];
} LLLScreenshotOwnedJob;
static LLLScreenshotOwnedJob *shot_active;
static LLLScreenshotJobStatus shot_terminal;

static void shot_copy_status(LLLScreenshotJobStatus *to,const LLLScreenshotJobStatus *from) {
    to->state=from->state;to->error=from->error;to->width=from->width;
    to->height=from->height;to->elapsed_ms=from->elapsed_ms;
    strcpy_s(to->id,33,from->id);wcscpy_s(to->output_path,32768,from->output_path);
}
static void shot_pending(LLLScreenshotJobStatus *status,const LLLScreenshotOwnedJob *job) {
    status->state=LLL_SCREENSHOT_PENDING;status->error=0;status->width=0;status->height=0;status->elapsed_ms=0;
    strcpy_s(status->id,33,job->id);wcscpy_s(status->output_path,32768,job->output);
}
static DWORD shot_retire(void) {
    LLLScreenshotOwnedJob *job=shot_active;DWORD waited;
    if (!job) return 0;
    waited=WaitForSingleObject(job->thread,0);
    if (waited==WAIT_TIMEOUT) return 0;
    if (waited!=WAIT_OBJECT_0) return GetLastError()?GetLastError():ERROR_INVALID_HANDLE;
    /* Thread signal fences all WGC/COM cleanup and result writes. No result is
     * read or exposed until the worker has exited and both handles retire. */
    CloseHandle(job->thread);CloseHandle(job->cancel);
    CloseHandle(job->guard);
    for (unsigned index=0;index<job->parent_count;++index) CloseHandle(job->parents[index]);
    shot_terminal.error=job->result.error?job->result.error:job->returned;
    if (job->publication==LLL_SCREENSHOT_PUBLISHED&&!shot_terminal.error) shot_terminal.state=LLL_SCREENSHOT_SUCCEEDED;
    else if (job->publication==LLL_SCREENSHOT_CANCELLED) {
        shot_terminal.state=LLL_SCREENSHOT_JOB_CANCELLED;shot_terminal.error=ERROR_CANCELLED;
    } else {
        shot_terminal.state=LLL_SCREENSHOT_FAILED;
        if (!shot_terminal.error) shot_terminal.error=ERROR_INVALID_DATA;
    }
    shot_terminal.width=job->result.width;shot_terminal.height=job->result.height;shot_terminal.elapsed_ms=job->result.elapsed_ms;
    strcpy_s(shot_terminal.id,33,job->id);wcscpy_s(shot_terminal.output_path,32768,job->output);
    shot_active=NULL;free(job);return 0;
}
static DWORD shot_canonical(const wchar_t *path,wchar_t output[32768]) {
    HANDLE file;DWORD count,error=0;wchar_t *resolved;
    file=CreateFileW(path,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
    if (file==INVALID_HANDLE_VALUE) return GetLastError();
    count=GetFinalPathNameByHandleW(file,output,32768,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
    if (!count||count>=32768) error=GetLastError()?GetLastError():ERROR_BUFFER_OVERFLOW;
    CloseHandle(file);
    if (error) return error;
    resolved=!wcsncmp(output,L"\\\\?\\",4)?output+4:output;
    if (resolved!=output) memmove(output,resolved,(wcslen(resolved)+1)*sizeof(wchar_t));
    return 0;
}
static DWORD shot_identity(DWORD pid,const wchar_t *expected,wchar_t executable_out[32768],FILETIME *created) {
    HANDLE process;FILETIME exited,kernel,user;DWORD count=32768,error=0;
    wchar_t *actual=NULL,*canonical_expected=NULL;
    if (!pid||!expected||!*expected) return ERROR_ACCESS_DENIED;
    process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
    if (!process) return GetLastError();
    actual=(wchar_t*)malloc(32768*sizeof(wchar_t));canonical_expected=(wchar_t*)malloc(32768*sizeof(wchar_t));
    if (!actual||!canonical_expected) { error=ERROR_NOT_ENOUGH_MEMORY;goto done; }
    if (!GetProcessTimes(process,created,&exited,&kernel,&user)||!QueryFullProcessImageNameW(process,0,actual,&count)) { error=GetLastError();goto done; }
    if (exited.dwLowDateTime||exited.dwHighDateTime) { error=ERROR_PROCESS_ABORTED;goto done; }
    error=shot_canonical(expected,canonical_expected);if (error) goto done;
    error=shot_canonical(actual,executable_out);if (error) goto done;
    if (CompareStringOrdinal(executable_out,-1,canonical_expected,-1,TRUE)!=CSTR_EQUAL) error=ERROR_ACCESS_DENIED;
done:
    if (actual) free(actual);if (canonical_expected) free(canonical_expected);CloseHandle(process);return error;
}
static int shot_reserved(const wchar_t *name) {
    wchar_t stem[129];size_t length=0;
    while (name[length]&&name[length]!=L'.'&&length<128) { stem[length]=name[length];++length; }
    while (length&&(stem[length-1]==L' '||stem[length-1]==L'.')) --length;
    stem[length]=0;
    if (!_wcsicmp(stem,L"CON")||!_wcsicmp(stem,L"PRN")||!_wcsicmp(stem,L"AUX")||!_wcsicmp(stem,L"NUL")) return 1;
    return length==4&&(!_wcsnicmp(stem,L"COM",3)||!_wcsnicmp(stem,L"LPT",3))&&stem[3]>=L'0'&&stem[3]<=L'9';
}
static DWORD shot_directory(const wchar_t *path,HANDLE parents[32],unsigned *parent_count) {
    wchar_t *root;DWORD count,attributes,error=0;size_t prefix,length;const wchar_t *name;
    root=(wchar_t*)malloc(32768*sizeof(wchar_t));if (!root) return ERROR_NOT_ENOUGH_MEMORY;
    count=GetEnvironmentVariableW(L"LOCALAPPDATA",root,32768);
    if (!count||count>=32768||count<3||root[1]!=L':'||root[2]!=L'\\') { error=ERROR_INVALID_NAME;goto done; }
    while (count>3&&root[count-1]==L'\\') root[--count]=0;
    if (wcscat_s(root,32768,L"\\LLL\\Helldivers2\\Screenshots")) { error=ERROR_BUFFER_OVERFLOW;goto done; }
    prefix=wcslen(root);length=wcsnlen_s(path,32768);
    if (length>=32768||length<=prefix+1||CompareStringOrdinal(path,(int)prefix,root,(int)prefix,TRUE)!=CSTR_EQUAL||path[prefix]!=L'\\') { error=ERROR_INVALID_NAME;goto done; }
    name=path+prefix+1;length=wcslen(name);
    if (length<5||length>128||name[0]==L'.'||name[0]==L' '||_wcsicmp(name+length-4,L".png")||wcsstr(name,L"..")||shot_reserved(name)) { error=ERROR_INVALID_NAME;goto done; }
    for (size_t index=0;index<length;++index) {
        wchar_t value=name[index];
        if (!((value>=L'a'&&value<=L'z')||(value>=L'A'&&value<=L'Z')||(value>=L'0'&&value<=L'9')||value==L'_'||value==L'-'||value==L'.'||value==L' ')) { error=ERROR_INVALID_NAME;goto done; }
    }
    /* Pin every existing directory name from drive root to the output parent.
     * No delete sharing: an active job fences ancestor renames/rebinding too. */
    for (size_t end=3;;) {
        wchar_t saved=root[end];HANDLE handle;BY_HANDLE_FILE_INFORMATION info;
        if (*parent_count>=32) { error=ERROR_TOO_MANY_OPEN_FILES;goto done; }
        root[end]=0;
        handle=CreateFileW(root,FILE_READ_ATTRIBUTES|FILE_LIST_DIRECTORY,end==prefix?FILE_SHARE_READ:FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,NULL);
        if (handle==INVALID_HANDLE_VALUE&&end==prefix&&GetLastError()==ERROR_FILE_NOT_FOUND) {
            if (!CreateDirectoryW(root,NULL)&&GetLastError()!=ERROR_ALREADY_EXISTS) { error=GetLastError();root[end]=saved;goto done; }
            handle=CreateFileW(root,FILE_READ_ATTRIBUTES|FILE_LIST_DIRECTORY,end==prefix?FILE_SHARE_READ:FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,NULL);
        }
        root[end]=saved;
        if (handle==INVALID_HANDLE_VALUE) { error=GetLastError();goto done; }
        if (!GetFileInformationByHandle(handle,&info)||(info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)||!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)) {
            CloseHandle(handle);error=ERROR_ACCESS_DENIED;goto done;
        }
        parents[(*parent_count)++]=handle;
        if (end==prefix) break;
        while (end<prefix&&root[end]==L'\\') ++end;
        while (end<prefix&&root[end]!=L'\\') ++end;
    }
    attributes=GetFileAttributesW(path);
    if (attributes!=INVALID_FILE_ATTRIBUTES) { error=ERROR_FILE_EXISTS;goto done; }
    if (GetLastError()!=ERROR_FILE_NOT_FOUND) error=GetLastError();
done:
    free(root);return error;
}
static DWORD shot_guard_directory(LLLScreenshotOwnedJob *job) {
    wchar_t *path;const wchar_t *separator=wcsrchr(job->output,L'\\');
    HANDLE replacement=INVALID_HANDLE_VALUE;BY_HANDLE_FILE_INFORMATION before,after;DWORD error=0;
    unsigned last;
    if (!separator||!job->parent_count) return ERROR_INVALID_NAME;
    last=job->parent_count-1;
    path=(wchar_t*)malloc(32768*sizeof(wchar_t));if (!path) return ERROR_NOT_ENOUGH_MEMORY;
    if (swprintf_s(path,32768,L"%.*s\\.lll-screenshot-job-%hs.guard",(int)(separator-job->output),job->output,job->id)<0) { error=ERROR_FILENAME_EXCED_RANGE;goto done; }
    /* Start with the parent's restrictive write-sharing fence. Create a real,
     * non-deletable guard before relaxing sharing for the child handle rename.
     * A guarded nonempty directory cannot become a junction/symlink target. */
    job->guard=CreateFileW(path,GENERIC_READ|DELETE,0,NULL,CREATE_NEW,
        FILE_ATTRIBUTE_HIDDEN|FILE_ATTRIBUTE_TEMPORARY|FILE_FLAG_DELETE_ON_CLOSE,NULL);
    if (job->guard==INVALID_HANDLE_VALUE) { error=GetLastError();job->guard=NULL;goto done; }
    path[separator-job->output]=0;
    replacement=CreateFileW(path,FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,NULL);
    if (replacement==INVALID_HANDLE_VALUE) { error=GetLastError();goto done; }
    if (!GetFileInformationByHandle(job->parents[last],&before)||!GetFileInformationByHandle(replacement,&after)) { error=GetLastError();goto done; }
    if ((after.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)||before.dwVolumeSerialNumber!=after.dwVolumeSerialNumber
        ||before.nFileIndexHigh!=after.nFileIndexHigh||before.nFileIndexLow!=after.nFileIndexLow) { error=ERROR_ACCESS_DENIED;goto done; }
    CloseHandle(job->parents[last]);job->parents[last]=replacement;replacement=INVALID_HANDLE_VALUE;
done:
    if (replacement!=INVALID_HANDLE_VALUE) CloseHandle(replacement);free(path);return error;
}
static DWORD WINAPI shot_worker(void *context) {
    LLLScreenshotOwnedJob *job=(LLLScreenshotOwnedJob*)context;
    job->returned=lll_steam_screenshot_capture(&job->request,&job->result);return job->returned;
}
static DWORD shot_id(const wchar_t *input,char id[33]) {
    if (!input||wcsnlen_s(input,33)!=32) return ERROR_INVALID_PARAMETER;
    for (unsigned index=0;index<32;++index) {
        wchar_t value=input[index];if (!((value>=L'0'&&value<=L'9')||(value>=L'a'&&value<=L'f'))) return ERROR_INVALID_PARAMETER;
        id[index]=(char)value;
    }
    id[32]=0;return 0;
}
DWORD lll_screenshot_job_request(DWORD client_pid,const wchar_t *expected_executable,const wchar_t *output_path,LLLScreenshotJobStatus *status) {
    LLLScreenshotOwnedJob *job;BYTE random[16];DWORD error;
    static const char hex[]="0123456789abcdef";
    if (!status||!output_path) return ERROR_INVALID_PARAMETER;
    error=shot_retire();if (error) return error;if (shot_active) return ERROR_BUSY;
    job=(LLLScreenshotOwnedJob*)calloc(1,sizeof(*job));if (!job) return ERROR_NOT_ENOUGH_MEMORY;
    error=shot_identity(client_pid,expected_executable,job->executable,&job->request.created);if (error) goto failed;
    error=shot_directory(output_path,job->parents,&job->parent_count);if (error) goto failed;
    if (BCryptGenRandom(NULL,random,sizeof(random),BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0) { error=ERROR_GEN_FAILURE;goto failed; }
    for (unsigned index=0;index<16;++index) { job->id[index*2]=hex[random[index]>>4];job->id[index*2+1]=hex[random[index]&15]; }
    if (shot_terminal.id[0]&&!strcmp(job->id,shot_terminal.id)) { error=ERROR_RETRY;goto failed; }
    wcscpy_s(job->output,32768,output_path);
    error=shot_guard_directory(job);if (error) goto failed;
    job->request.pid=client_pid;job->request.executable=job->executable;job->request.output_path=job->output;
    job->cancel=CreateEventW(NULL,TRUE,FALSE,NULL);if (!job->cancel) { error=GetLastError();goto failed; }
    job->request.cancel_event=job->cancel;job->request.publication=&job->publication;
    job->thread=CreateThread(NULL,0,shot_worker,job,0,NULL);if (!job->thread) { error=GetLastError();goto failed; }
    shot_active=job;shot_pending(status,job);return 0;
failed:
    if (job->cancel) CloseHandle(job->cancel);if (job->guard) CloseHandle(job->guard);
    for (unsigned index=0;index<job->parent_count;++index) CloseHandle(job->parents[index]);free(job);return error;
}
DWORD lll_screenshot_job_status(const wchar_t *input,LLLScreenshotJobStatus *status) {
    char id[33];DWORD error;if (!status) return ERROR_INVALID_PARAMETER;
    error=shot_id(input,id);if (error) return error;error=shot_retire();if (error) return error;
    if (shot_active&&!strcmp(id,shot_active->id)) { shot_pending(status,shot_active);return 0; }
    if (shot_terminal.id[0]&&!strcmp(id,shot_terminal.id)) { shot_copy_status(status,&shot_terminal);return 0; }
    return ERROR_NOT_FOUND;
}
DWORD lll_screenshot_job_cancel(const wchar_t *input,LLLScreenshotJobStatus *status) {
    char id[33];DWORD error;if (!status) return ERROR_INVALID_PARAMETER;
    error=shot_id(input,id);if (error) return error;error=shot_retire();if (error) return error;
    if (shot_active&&!strcmp(id,shot_active->id)) {
        SetEvent(shot_active->cancel);InterlockedCompareExchange(&shot_active->publication,LLL_SCREENSHOT_CANCELLED,LLL_SCREENSHOT_OPEN);
        error=shot_retire();if (error) return error;
    }
    return lll_screenshot_job_status(input,status);
}
void lll_screenshot_jobs_cancel_all(void) {
    if (shot_retire()||!shot_active) return;
    SetEvent(shot_active->cancel);InterlockedCompareExchange(&shot_active->publication,LLL_SCREENSHOT_CANCELLED,LLL_SCREENSHOT_OPEN);
}
void lll_screenshot_jobs_shutdown(void) {
    lll_screenshot_jobs_cancel_all();
    if (shot_active&&WaitForSingleObject(shot_active->thread,INFINITE)==WAIT_OBJECT_0) shot_retire();
}
