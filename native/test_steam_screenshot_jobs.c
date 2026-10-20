/* Offline owned-job fixtures. Fake worker only: no WGC or game interaction. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <winioctl.h>
#include <stdio.h>
#pragma comment(lib,"advapi32.lib")
#include "steam_screenshot_jobs.c"

enum { FAKE_OPEN,FAKE_PUBLISHING,FAKE_PUBLISHED,FAKE_FAIL };
static HANDLE fake_entered,fake_finish;
static volatile LONG fake_mode,fake_errors;
static wchar_t original_appdata[32768],isolated[32768],screenshots[32768],own_exe[32768],expected_output[32768];
static unsigned checks;
static ULONGLONG max_request_ms,max_status_ms,max_cancel_ms;

#define CHECK(value) do { ++checks;if (!(value)) { fprintf(stderr,"FAIL line %d: %s (error %lu)\n",__LINE__,#value,(unsigned long)GetLastError());exit(1); } } while (0)
static void timely(ULONGLONG begun,ULONGLONG *maximum) {
    ULONGLONG elapsed=GetTickCount64()-begun;if (elapsed>*maximum) *maximum=elapsed;CHECK(elapsed<250);
}
static void wide_id(const char id[33],wchar_t output[33]) {
    for (unsigned index=0;index<33;++index) output[index]=(wchar_t)(unsigned char)id[index];
}
static void make_path(const wchar_t *name,wchar_t output[32768]) {
    CHECK(swprintf_s(output,32768,L"%s\\%s",screenshots,name)>0);
}
DWORD lll_steam_screenshot_capture(const LLLScreenshotRequest *request,LLLScreenshotResult *result) {
    FILETIME created,exited,kernel,user;DWORD mode=(DWORD)InterlockedCompareExchange(&fake_mode,0,0);
    if (!request||request->pid!=GetCurrentProcessId()||!GetProcessTimes(GetCurrentProcess(),&created,&exited,&kernel,&user)||
        CompareFileTime(&request->created,&created)||wcscmp(request->executable,own_exe)||wcscmp(request->output_path,expected_output))
        InterlockedIncrement(&fake_errors);
    if (mode==FAKE_PUBLISHING||mode==FAKE_PUBLISHED) {
        if (InterlockedCompareExchange(request->publication,LLL_SCREENSHOT_PUBLISHING,LLL_SCREENSHOT_OPEN)!=LLL_SCREENSHOT_OPEN)
            InterlockedIncrement(&fake_errors);
    }
    if (mode==FAKE_PUBLISHED) {
        result->width=1920;result->height=1080;result->elapsed_ms=7;
        InterlockedExchange(request->publication,LLL_SCREENSHOT_PUBLISHED);
    }
    SetEvent(fake_entered);
    if (WaitForSingleObject(fake_finish,10000)!=WAIT_OBJECT_0) { result->error=ERROR_TIMEOUT;return result->error; }
    if (mode==FAKE_FAIL) { result->error=ERROR_NOT_SUPPORTED;return result->error; }
    if (mode==FAKE_OPEN&&InterlockedCompareExchange(request->publication,LLL_SCREENSHOT_PUBLISHING,LLL_SCREENSHOT_OPEN)!=LLL_SCREENSHOT_OPEN) {
        result->error=ERROR_CANCELLED;return result->error;
    }
    result->width=1920;result->height=1080;result->elapsed_ms=7;
    InterlockedExchange(request->publication,LLL_SCREENSHOT_PUBLISHED);return 0;
}
static void start_job(const wchar_t *name,LONG mode,LLLScreenshotJobStatus *status,wchar_t id[33]) {
    ULONGLONG begun;
    CHECK(!shot_active);CHECK(ResetEvent(fake_entered));CHECK(ResetEvent(fake_finish));
    InterlockedExchange(&fake_mode,mode);make_path(name,expected_output);
    begun=GetTickCount64();CHECK(!lll_screenshot_job_request(GetCurrentProcessId(),own_exe,expected_output,status));timely(begun,&max_request_ms);
    CHECK(status->state==LLL_SCREENSHOT_PENDING&&strlen(status->id)==32&&!status->error&&!status->width&&!status->height);
    wide_id(status->id,id);CHECK(WaitForSingleObject(fake_entered,3000)==WAIT_OBJECT_0);CHECK(!fake_errors);
}
static void pending_status(const wchar_t id[33],LLLScreenshotJobStatus *status) {
    ULONGLONG begun=GetTickCount64();CHECK(!lll_screenshot_job_status(id,status));timely(begun,&max_status_ms);
    CHECK(status->state==LLL_SCREENSHOT_PENDING&&!status->width&&!status->height&&!status->elapsed_ms);
}
static void finish_job(const wchar_t id[33],DWORD state,LLLScreenshotJobStatus *status) {
    HANDLE retired[35];DWORD info;unsigned count=0;
    CHECK(shot_active!=NULL);retired[count++]=shot_active->thread;retired[count++]=shot_active->cancel;
    retired[count++]=shot_active->guard;
    for (unsigned index=0;index<shot_active->parent_count;++index) retired[count++]=shot_active->parents[index];
    CHECK(SetEvent(fake_finish));CHECK(WaitForSingleObject(shot_active->thread,3000)==WAIT_OBJECT_0);
    CHECK(!lll_screenshot_job_status(id,status));CHECK(status->state==state&&!shot_active);
    for (unsigned index=0;index<count;++index) { SetLastError(0);CHECK(!GetHandleInformation(retired[index],&info)&&GetLastError()==ERROR_INVALID_HANDLE); }
}
static void invalid_name(const wchar_t *name) {
    wchar_t path[32768];LLLScreenshotJobStatus status;
    make_path(name,path);CHECK(lll_screenshot_job_request(GetCurrentProcessId(),own_exe,path,&status)==ERROR_INVALID_NAME);CHECK(!shot_active);
}
static DWORD set_junction(const wchar_t *path,const wchar_t *target) {
    struct Junction { DWORD tag;WORD length,reserved,sub_offset,sub_length,print_offset,print_length;wchar_t names[32768]; } *buffer;
    wchar_t substitute[32768];HANDLE handle;DWORD returned,bytes,error;size_t sub_length,print_length;BOOL changed;
    CHECK(swprintf_s(substitute,32768,L"\\??\\%s",target)>0);
    sub_length=wcslen(substitute)*sizeof(wchar_t);print_length=wcslen(target)*sizeof(wchar_t);
    CHECK(sub_length+print_length+2*sizeof(wchar_t)<32768*sizeof(wchar_t));
    buffer=(struct Junction*)calloc(1,sizeof(*buffer));CHECK(buffer!=NULL);buffer->tag=IO_REPARSE_TAG_MOUNT_POINT;
    buffer->sub_length=(WORD)sub_length;buffer->print_offset=(WORD)(sub_length+sizeof(wchar_t));buffer->print_length=(WORD)print_length;
    memcpy(buffer->names,substitute,sub_length);memcpy((BYTE*)buffer->names+buffer->print_offset,target,print_length);
    buffer->length=(WORD)(8+sub_length+print_length+2*sizeof(wchar_t));bytes=8+buffer->length;
    handle=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS,NULL);
    if (handle==INVALID_HANDLE_VALUE) { error=GetLastError();free(buffer);return error; }
    changed=DeviceIoControl(handle,FSCTL_SET_REPARSE_POINT,buffer,bytes,NULL,0,&returned,NULL);error=changed?0:GetLastError();
    CHECK(CloseHandle(handle));free(buffer);return error;
}
static void junction(const wchar_t *path,const wchar_t *target) {
    CHECK(CreateDirectoryW(path,NULL));CHECK(!set_junction(path,target));CHECK(GetFileAttributesW(path)&FILE_ATTRIBUTE_REPARSE_POINT);
}
static DWORD set_symlink(const wchar_t *path,const wchar_t *target) {
    struct Symlink { DWORD tag;WORD length,reserved,sub_offset,sub_length,print_offset,print_length;DWORD flags;wchar_t names[32768]; } *buffer;
    wchar_t substitute[32768];HANDLE handle;DWORD returned,bytes,error;size_t sub_length,print_length;BOOL changed;
    if (swprintf_s(substitute,32768,L"\\??\\%s",target)<=0) return ERROR_INVALID_NAME;
    sub_length=wcslen(substitute)*sizeof(wchar_t);print_length=wcslen(target)*sizeof(wchar_t);
    if (sub_length+print_length+2*sizeof(wchar_t)>=32768*sizeof(wchar_t)) return ERROR_BUFFER_OVERFLOW;
    buffer=(struct Symlink*)calloc(1,sizeof(*buffer));if (!buffer) return ERROR_NOT_ENOUGH_MEMORY;
    buffer->tag=IO_REPARSE_TAG_SYMLINK;
    buffer->sub_length=(WORD)sub_length;buffer->print_offset=(WORD)(sub_length+sizeof(wchar_t));buffer->print_length=(WORD)print_length;
    memcpy(buffer->names,substitute,sub_length);memcpy((BYTE*)buffer->names+buffer->print_offset,target,print_length);
    buffer->length=(WORD)(12+sub_length+print_length+2*sizeof(wchar_t));bytes=8+buffer->length;
    handle=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS,NULL);
    if (handle==INVALID_HANDLE_VALUE) { error=GetLastError();free(buffer);return error; }
    changed=DeviceIoControl(handle,FSCTL_SET_REPARSE_POINT,buffer,bytes,NULL,0,&returned,NULL);error=changed?0:GetLastError();
    if (!CloseHandle(handle)&&!error) error=GetLastError();free(buffer);return error;
}
static DWORD own_privileged_symlink(const wchar_t *path,const wchar_t *target) {
    HANDLE token;TOKEN_PRIVILEGES enabled={0},previous={0};DWORD previous_size=sizeof(previous),error,result,restored_error;BOOL restored,closed;
    /* Fixture process only: never the external service or game token. Restore
     * the exact previous state before any result assertion can exit the test. */
    if (!OpenProcessToken(GetCurrentProcess(),TOKEN_ADJUST_PRIVILEGES|TOKEN_QUERY,&token)) {
        error=GetLastError();printf("symlink privilege unavailable: OpenProcessToken error=%lu\n",(unsigned long)error);return ERROR_PRIVILEGE_NOT_HELD;
    }
    if (!LookupPrivilegeValueW(NULL,L"SeCreateSymbolicLinkPrivilege",&enabled.Privileges[0].Luid)) {
        error=GetLastError();CHECK(CloseHandle(token));printf("symlink privilege unavailable: lookup error=%lu\n",(unsigned long)error);return ERROR_PRIVILEGE_NOT_HELD;
    }
    enabled.PrivilegeCount=1;enabled.Privileges[0].Attributes=SE_PRIVILEGE_ENABLED;SetLastError(ERROR_SUCCESS);
    if (!AdjustTokenPrivileges(token,FALSE,&enabled,sizeof(previous),&previous,&previous_size)) {
        error=GetLastError();CHECK(CloseHandle(token));printf("symlink privilege unavailable: enable error=%lu\n",(unsigned long)error);return ERROR_PRIVILEGE_NOT_HELD;
    }
    error=GetLastError();
    if (error==ERROR_NOT_ALL_ASSIGNED) {
        CHECK(CloseHandle(token));printf("symlink privilege absent: ERROR_NOT_ALL_ASSIGNED; raw mutation remains unqualified\n");return ERROR_PRIVILEGE_NOT_HELD;
    }
    result=error==ERROR_SUCCESS?set_symlink(path,target):error;
    SetLastError(ERROR_SUCCESS);restored=AdjustTokenPrivileges(token,FALSE,&previous,0,NULL,NULL);restored_error=GetLastError();closed=CloseHandle(token);
    CHECK(error==ERROR_SUCCESS&&restored&&restored_error==ERROR_SUCCESS&&closed);
    printf("symlink privilege enabled for own-temp attempt; exact prior token state restored\n");return result;
}
static void nonempty_reparse(void) {
    wchar_t directory[32768],target[32768],guard_path[32768];HANDLE guard;DWORD error,before_privilege,after_privilege;
    CHECK(swprintf_s(directory,32768,L"%s\\guarded",isolated)>0);CHECK(CreateDirectoryW(directory,NULL));
    CHECK(swprintf_s(target,32768,L"%s\\guard-target",isolated)>0);CHECK(CreateDirectoryW(target,NULL));
    CHECK(swprintf_s(guard_path,32768,L"%s\\.fixture-guard",directory)>0);
    guard=CreateFileW(guard_path,GENERIC_WRITE|DELETE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_DELETE_ON_CLOSE,NULL);CHECK(guard!=INVALID_HANDLE_VALUE);
    error=set_junction(directory,target);printf("nonempty reparse mountpoint error=%lu\n",(unsigned long)error);CHECK(error==ERROR_DIR_NOT_EMPTY);
    /* LookupPrivilegeValue may initialize process-owned LSA/RPC infrastructure.
     * Warm this exact new fixture path before measuring job-owned handles. */
    CHECK(GetProcessHandleCount(GetCurrentProcess(),&before_privilege));
    error=own_privileged_symlink(directory,target);CHECK(error==ERROR_DIR_NOT_EMPTY||error==ERROR_PRIVILEGE_NOT_HELD||error==ERROR_NOT_SUPPORTED);
    CHECK(GetProcessHandleCount(GetCurrentProcess(),&after_privilege));
    printf("first privilege-path handle count before=%lu after=%lu\n",(unsigned long)before_privilege,(unsigned long)after_privilege);
    for (unsigned index=0;index<8;++index) {
        DWORD repeated;error=own_privileged_symlink(directory,target);CHECK(error==ERROR_DIR_NOT_EMPTY||error==ERROR_PRIVILEGE_NOT_HELD||error==ERROR_NOT_SUPPORTED);
        CHECK(GetProcessHandleCount(GetCurrentProcess(),&repeated));
        printf("privilege repeat %u handle count=%lu\n",index+1,(unsigned long)repeated);CHECK(repeated==after_privilege);
    }
    CHECK(!(GetFileAttributesW(directory)&FILE_ATTRIBUTE_REPARSE_POINT));
    CHECK(CloseHandle(guard));CHECK(GetFileAttributesW(guard_path)==INVALID_FILE_ATTRIBUTES);CHECK(RemoveDirectoryW(directory));CHECK(RemoveDirectoryW(target));
}
static DWORD WINAPI shutdown_thread(void *unused) { (void)unused;lll_screenshot_jobs_shutdown();return 0; }
static void full_publication(void) {
    wchar_t stage[32768],published[32768],basename[128],cwd_path[32768];HANDLE file;DWORD bytes;FILE_RENAME_INFO *rename;size_t length;
    CHECK(swprintf_s(basename,128,L"fixture-published-%lu.png",(unsigned long)GetCurrentProcessId())>0);
    make_path(L"fixture-stage.tmp",stage);make_path(basename,published);
    CHECK(GetFullPathNameW(basename,32768,cwd_path,NULL)>0);CHECK(GetFileAttributesW(cwd_path)==INVALID_FILE_ATTRIBUTES);
    file=CreateFileW(stage,GENERIC_READ|GENERIC_WRITE|DELETE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);CHECK(file!=INVALID_HANDLE_VALUE);
    CHECK(WriteFile(file,"fixture",7,&bytes,NULL)&&bytes==7);
    length=sizeof(FILE_RENAME_INFO)+wcslen(published)*sizeof(wchar_t);rename=(FILE_RENAME_INFO*)calloc(1,length);CHECK(rename!=NULL);
    rename->FileNameLength=(DWORD)(wcslen(published)*sizeof(wchar_t));memcpy(rename->FileName,published,rename->FileNameLength);
    CHECK(SetFileInformationByHandle(file,FileRenameInfo,rename,(DWORD)length));free(rename);CHECK(CloseHandle(file));
    CHECK(GetFileAttributesW(published)!=INVALID_FILE_ATTRIBUTES);CHECK(GetFileAttributesW(cwd_path)==INVALID_FILE_ATTRIBUTES);
    {
        char content[8]={0};file=CreateFileW(published,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);CHECK(file!=INVALID_HANDLE_VALUE);
        CHECK(ReadFile(file,content,sizeof(content),&bytes,NULL)&&bytes==7&&!memcmp(content,"fixture",7));CHECK(CloseHandle(file));CHECK(DeleteFileW(published));
    }
    CHECK(GetFileAttributesW(stage)==INVALID_FILE_ATTRIBUTES);
}
static void pinned_parent(void) {
    HANDLE directory;wchar_t guard_path[32768],moved[32768],target[32768];DWORD error,length;
    directory=CreateFileW(screenshots,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
    CHECK(directory!=INVALID_HANDLE_VALUE);CHECK(CloseHandle(directory));
    CHECK(shot_active->guard!=NULL);length=GetFinalPathNameByHandleW(shot_active->guard,guard_path,32768,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);CHECK(length&&length<32768);
    CHECK(swprintf_s(moved,32768,L"%s-moved",guard_path)>0);
    CHECK(!DeleteFileW(guard_path));CHECK(GetLastError()==ERROR_SHARING_VIOLATION||GetLastError()==ERROR_ACCESS_DENIED);
    CHECK(!MoveFileExW(guard_path,moved,0));CHECK(GetLastError()==ERROR_SHARING_VIOLATION||GetLastError()==ERROR_ACCESS_DENIED);
    CHECK(swprintf_s(target,32768,L"%s\\guard-target-active",isolated)>0);CHECK(CreateDirectoryW(target,NULL));
    error=set_junction(screenshots,target);CHECK(error==ERROR_DIR_NOT_EMPTY);
    error=own_privileged_symlink(screenshots,target);printf("guarded reparse errors: mountpoint=145 symlink=%lu\n",(unsigned long)error);
    CHECK(error==ERROR_DIR_NOT_EMPTY||error==ERROR_PRIVILEGE_NOT_HELD||error==ERROR_NOT_SUPPORTED);
    CHECK(!(GetFileAttributesW(screenshots)&FILE_ATTRIBUTE_REPARSE_POINT));CHECK(RemoveDirectoryW(target));
    full_publication();
}
int wmain(void) {
    LLLScreenshotJobStatus status,last_status;wchar_t id_a[33],id_b[33],unknown[33],path[32768],moved[32768],target[32768];
    DWORD length=32768,baseline,handles;FILETIME created,exited,kernel,user;HANDLE file,joining;ULONGLONG begun;
    CHECK(GetEnvironmentVariableW(L"LOCALAPPDATA",original_appdata,32768)>3);
    CHECK(swprintf_s(isolated,32768,L"%s\\Temp\\lll-screenshot-jobs-%lu-%llu",original_appdata,(unsigned long)GetCurrentProcessId(),GetTickCount64())>0);
    CHECK(CreateDirectoryW(isolated,NULL));CHECK(swprintf_s(path,32768,L"%s\\LLL",isolated)>0);CHECK(CreateDirectoryW(path,NULL));
    CHECK(wcscat_s(path,32768,L"\\Helldivers2")==0);CHECK(CreateDirectoryW(path,NULL));
    CHECK(swprintf_s(screenshots,32768,L"%s\\Screenshots",path)>0);CHECK(SetEnvironmentVariableW(L"LOCALAPPDATA",isolated));
    CHECK(QueryFullProcessImageNameW(GetCurrentProcess(),0,own_exe,&length));CHECK(!shot_canonical(own_exe,own_exe));
    fake_entered=CreateEventW(NULL,TRUE,FALSE,NULL);fake_finish=CreateEventW(NULL,TRUE,FALSE,NULL);CHECK(fake_entered&&fake_finish);
    CHECK(GetProcessTimes(GetCurrentProcess(),&created,&exited,&kernel,&user));
    CHECK(!shot_identity(GetCurrentProcessId(),own_exe,target,&exited));CHECK(!CompareFileTime(&created,&exited)&&!wcscmp(target,own_exe));
    printf("Running offline fake-worker fixtures\n");fflush(stdout);
    nonempty_reparse();
    /* Privilege/LSA path above and CRT/CNG paths here are warmed before exact owned-handle accounting. */
    start_job(L"warmup.png",FAKE_OPEN,&status,id_a);finish_job(id_a,LLL_SCREENSHOT_SUCCEEDED,&status);
    start_job(L"warmup-second.png",FAKE_OPEN,&status,id_a);finish_job(id_a,LLL_SCREENSHOT_SUCCEEDED,&status);
    CHECK(GetProcessHandleCount(GetCurrentProcess(),&baseline));
    start_job(L"open.png",FAKE_OPEN,&status,id_a);pending_status(id_a,&status);
    CHECK(shot_active->parent_count>3);CHECK(lll_screenshot_job_request(GetCurrentProcessId(),own_exe,expected_output,&last_status)==ERROR_BUSY);
    CHECK(!strcmp(status.id,shot_active->id));
    wcscpy_s(unknown,33,id_a);unknown[0]=unknown[0]==L'0'?L'1':L'0';
    CHECK(lll_screenshot_job_status(unknown,&last_status)==ERROR_NOT_FOUND);
    CHECK(lll_screenshot_job_cancel(unknown,&last_status)==ERROR_NOT_FOUND);
    CHECK(lll_screenshot_job_cancel(L"BAD",&last_status)==ERROR_INVALID_PARAMETER);
    CHECK(lll_screenshot_job_status(L"0123456789ABCDEF0123456789ABCDEF",&last_status)==ERROR_INVALID_PARAMETER);
    CHECK(lll_screenshot_job_status(NULL,&last_status)==ERROR_INVALID_PARAMETER);
    CHECK(WaitForSingleObject(shot_active->cancel,0)==WAIT_TIMEOUT&&shot_active->publication==LLL_SCREENSHOT_OPEN);
    pinned_parent();
    /* All ancestor names remain bound until retirement, even after cancel. */
    CHECK(swprintf_s(path,32768,L"%s\\LLL",isolated)>0);CHECK(swprintf_s(moved,32768,L"%s\\LLL-renamed",isolated)>0);
    CHECK(!MoveFileExW(path,moved,0));CHECK(GetLastError()==ERROR_SHARING_VIOLATION||GetLastError()==ERROR_ACCESS_DENIED);
    begun=GetTickCount64();CHECK(!lll_screenshot_job_cancel(id_a,&status));timely(begun,&max_cancel_ms);
    CHECK(status.state==LLL_SCREENSHOT_PENDING&&shot_active->publication==LLL_SCREENSHOT_CANCELLED&&WaitForSingleObject(shot_active->cancel,0)==WAIT_OBJECT_0);
    CHECK(WaitForSingleObject(shot_active->thread,0)==WAIT_TIMEOUT);finish_job(id_a,LLL_SCREENSHOT_JOB_CANCELLED,&status);
    CHECK(status.error==ERROR_CANCELLED);CHECK(MoveFileExW(path,moved,0));CHECK(MoveFileExW(moved,path,0));
    start_job(L"publishing.png",FAKE_PUBLISHING,&status,id_b);
    CHECK(!lll_screenshot_job_status(id_a,&last_status)&&last_status.state==LLL_SCREENSHOT_JOB_CANCELLED);
    CHECK(!lll_screenshot_job_cancel(id_a,&last_status));CHECK(WaitForSingleObject(shot_active->cancel,0)==WAIT_TIMEOUT);
    begun=GetTickCount64();CHECK(!lll_screenshot_job_cancel(id_b,&status));timely(begun,&max_cancel_ms);
    CHECK(status.state==LLL_SCREENSHOT_PENDING&&shot_active->publication==LLL_SCREENSHOT_PUBLISHING);pending_status(id_b,&status);
    finish_job(id_b,LLL_SCREENSHOT_SUCCEEDED,&status);CHECK(status.width==1920&&status.height==1080&&status.elapsed_ms==7&&!status.error);
    CHECK(lll_screenshot_job_status(id_a,&last_status)==ERROR_NOT_FOUND);
    start_job(L"published-not-retired.png",FAKE_PUBLISHED,&status,id_a);CHECK(shot_active->publication==LLL_SCREENSHOT_PUBLISHED);
    pending_status(id_a,&status);CHECK(!lll_screenshot_job_cancel(id_a,&status)&&status.state==LLL_SCREENSHOT_PENDING);
    finish_job(id_a,LLL_SCREENSHOT_SUCCEEDED,&status);
    start_job(L"failure.png",FAKE_FAIL,&status,id_a);finish_job(id_a,LLL_SCREENSHOT_FAILED,&status);CHECK(status.error==ERROR_NOT_SUPPORTED);
    invalid_name(L"CON.png");invalid_name(L"NUL .png");invalid_name(L"PRN.png");invalid_name(L"AUX.png");invalid_name(L"COM1.png");invalid_name(L"LPT9.png");
    invalid_name(L".hidden.png");invalid_name(L" leading.png");invalid_name(L"x..png");invalid_name(L"..\\outside.png");invalid_name(L"sub\\image.png");
    invalid_name(L"image.png:stream");invalid_name(L"image.jpg");invalid_name(L".png");invalid_name(L"image.png ");invalid_name(L"snowman-\x2603.png");
    make_path(L"existing.png",target);file=CreateFileW(target,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);CHECK(file!=INVALID_HANDLE_VALUE);CHECK(CloseHandle(file));
    CHECK(lll_screenshot_job_request(GetCurrentProcessId(),own_exe,target,&status)==ERROR_FILE_EXISTS);CHECK(!shot_active);CHECK(DeleteFileW(target));
    CHECK(GetSystemDirectoryW(target,32768)>0);CHECK(wcscat_s(target,32768,L"\\kernel32.dll")==0);make_path(L"identity.png",expected_output);
    CHECK(lll_screenshot_job_request(GetCurrentProcessId(),target,expected_output,&status)==ERROR_ACCESS_DENIED);CHECK(!shot_active);
    CHECK(lll_screenshot_job_request(0,own_exe,expected_output,&status)==ERROR_ACCESS_DENIED);CHECK(!shot_active);
    CHECK(RemoveDirectoryW(screenshots));CHECK(swprintf_s(target,32768,L"%s\\redirected",isolated)>0);CHECK(CreateDirectoryW(target,NULL));junction(screenshots,target);
    CHECK(lll_screenshot_job_request(GetCurrentProcessId(),own_exe,expected_output,&status)==ERROR_ACCESS_DENIED);CHECK(!shot_active);
    CHECK(RemoveDirectoryW(screenshots));CHECK(CreateDirectoryW(screenshots,NULL));
    file=CreateFileW(screenshots,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
    CHECK(file!=INVALID_HANDLE_VALUE);
    CHECK(lll_screenshot_job_request(GetCurrentProcessId(),own_exe,expected_output,&status)==ERROR_SHARING_VIOLATION);CHECK(!shot_active);CHECK(CloseHandle(file));
    for (unsigned index=0;index<8;++index) {
        start_job(L"handle-cycle.png",FAKE_OPEN,&status,id_a);pinned_parent();finish_job(id_a,LLL_SCREENSHOT_SUCCEEDED,&status);
        CHECK(GetProcessHandleCount(GetCurrentProcess(),&handles));
        printf("privilege/job repeat %u handle count=%lu\n",index+1,(unsigned long)handles);CHECK(handles==baseline);
    }
    CHECK(GetProcessHandleCount(GetCurrentProcess(),&handles));printf("handle baseline=%lu after=%lu\n",(unsigned long)baseline,(unsigned long)handles);CHECK(handles==baseline);CHECK(!shot_active);
    start_job(L"shutdown.png",FAKE_OPEN,&status,id_a);
    joining=CreateThread(NULL,0,shutdown_thread,NULL,0,NULL);CHECK(joining!=NULL);
    CHECK(WaitForSingleObject(shot_active->cancel,3000)==WAIT_OBJECT_0);CHECK(WaitForSingleObject(joining,0)==WAIT_TIMEOUT);
    CHECK(shot_active&&shot_active->publication==LLL_SCREENSHOT_CANCELLED);CHECK(SetEvent(fake_finish));
    CHECK(WaitForSingleObject(joining,3000)==WAIT_OBJECT_0);CHECK(CloseHandle(joining));CHECK(!shot_active);
    CHECK(!lll_screenshot_job_status(id_a,&status)&&status.state==LLL_SCREENSHOT_JOB_CANCELLED);
    lll_screenshot_jobs_cancel_all();lll_screenshot_jobs_shutdown();CHECK(GetProcessHandleCount(GetCurrentProcess(),&handles));CHECK(handles==baseline);
    CHECK(CloseHandle(fake_entered));CHECK(CloseHandle(fake_finish));CHECK(SetEnvironmentVariableW(L"LOCALAPPDATA",original_appdata));CHECK(!fake_errors);
    printf("PASS: %u fake-worker checks; request/status/cancel max %llu/%llu/%llu ms; no worker/ancestor handle leaks; no WGC\n",checks,max_request_ms,max_status_ms,max_cancel_ms);
    return 0;
}
