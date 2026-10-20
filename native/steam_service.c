/* External filesystem and leased pointer service. No DLL is loaded into Helldivers 2; no process
 * memory, hooks or changes to code-integrity policy. Local byte pipes only. */
#include "steam_files.c"
#include "steam_pointer.c"
#include "steam_screenshot_jobs.c"
#include <shellapi.h>
#include <share.h>

static HANDLE io_event;
static FILE *service_log;
static unsigned char *listing_bytes;
static uint32_t listing_capacity;
static void note(const char *message) {
    if (service_log) { fprintf(service_log, "%s\n", message); fflush(service_log); }
}
static int transfer(HANDLE pipe, void *bytes, DWORD size, int writing) {
    unsigned char *at = bytes;
    while (size) {
        OVERLAPPED pending = {0};
        DWORD count = 0, error;
        BOOL ok;
        pending.hEvent = io_event; ResetEvent(io_event);
        ok = writing ? WriteFile(pipe, at, size, &count, &pending) : ReadFile(pipe, at, size, &count, &pending);
        error = ok ? 0 : GetLastError();
        if (!ok && error == ERROR_IO_PENDING) {
            if (WaitForSingleObject(io_event, INFINITE) != WAIT_OBJECT_0) return 0;
            ok = GetOverlappedResult(pipe, &pending, &count, FALSE);
        }
        if (!ok || !count) return 0;
        at += count; size -= count;
    }
    return 1;
}
static int connect_pipe(HANDLE pipe) {
    OVERLAPPED pending = {0};
    DWORD error, count;
    pending.hEvent = io_event; ResetEvent(io_event);
    if (ConnectNamedPipe(pipe, &pending)) return 1;
    error = GetLastError();
    if (error == ERROR_PIPE_CONNECTED) return 1;
    if (error != ERROR_IO_PENDING) return 0;
    if (WaitForSingleObject(io_event, 30 * 60 * 1000) != WAIT_OBJECT_0) {
        CancelIoEx(pipe, &pending); GetOverlappedResult(pipe, &pending, &count, TRUE); return 0;
    }
    return GetOverlappedResult(pipe, &pending, &count, FALSE) != 0;
}
static int send_file(HANDLE pipe) {
    FILE *stream = NULL;
    unsigned char *bytes;
    long length;
    DWORD size;
    int ok;
    if (_wfopen_s(&stream, response_file, L"rb")) return 0;
    if (fseek(stream, 0, SEEK_END) || (length=ftell(stream))<8 || length>MAX_REQUEST || fseek(stream,0,SEEK_SET)) { fclose(stream);return 0; }
    size=(DWORD)length; bytes=malloc(size);
    if (!bytes) { fclose(stream);return 0; }
    ok=fread(bytes,1,size,stream)==size; fclose(stream);
    if (ok) ok=transfer(pipe,&size,4,1) && transfer(pipe,bytes,size,1);
    free(bytes);return ok;
}

/* Reuse one bounded buffer across explicit discovery requests. Enumeration
 * never creates transport files or wakes a watcher on the service directory. */
static DWORD listing_reserve(uint32_t needed) {
    uint32_t capacity;
    unsigned char *larger;
    if (needed > MAX_REQUEST) return ERROR_MORE_DATA;
    if (needed <= listing_capacity) return 0;
    capacity = listing_capacity ? listing_capacity : 4096;
    while (capacity < needed) capacity = capacity > MAX_REQUEST / 2 ? MAX_REQUEST : capacity * 2;
    larger = realloc(listing_bytes, capacity);
    if (!larger) return ERROR_NOT_ENOUGH_MEMORY;
    listing_bytes = larger;
    listing_capacity = capacity;
    return 0;
}

static int decode_path(const unsigned char *bytes, uint32_t size, uint32_t path_size, wchar_t path[32768]) {
    int count = 0;
    if (path_size && path_size <= 32760 && size == 12 + path_size && !memchr(bytes + 12, 0, path_size))
        count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)bytes + 12, (int)path_size, path, 32767);
    if (count <= 0) return 0;
    path[count] = 0;
    for (int index = 0; index < count; ++index) if (path[index] == L'/') path[index] = L'\\';
    return 1;
}

static int send_listing(uint32_t nonce, const wchar_t *path, HANDLE outgoing) {
    uint32_t header[2] = {nonce, ERROR_INVALID_DATA}, length = 8, count = 0;
    WIN32_FIND_DATAW data;
    HANDLE handle = INVALID_HANDLE_VALUE;
    wchar_t pattern[32768];
    DWORD status;
    if (!path) goto header_only;
    status = listing_reserve(length);
    if (status) { header[1] = status; goto header_only; }
    swprintf_s(pattern, 32768, L"%s\\*", path);
    handle = FindFirstFileW(pattern, &data);
    if (handle == INVALID_HANDLE_VALUE) { header[1] = GetLastError(); goto header_only; }
    do {
        uint32_t fields[6], name_size;
        char name[4 * MAX_PATH];
        int encoded;
        if (!wcscmp(data.cFileName, L".") || !wcscmp(data.cFileName, L"..")) continue;
        if (++count > 100000) { status = ERROR_MORE_DATA; goto finished; }
        encoded = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, data.cFileName, -1,
                                      name, (int)sizeof(name), NULL, NULL);
        /* Match the legacy text serializer for an invalid UTF-16 name. */
        name_size = encoded > 0 ? (uint32_t)encoded - 1 : 0;
        status = listing_reserve(length + 24 + name_size);
        if (status) goto finished;
        fields[0] = data.dwFileAttributes;
        fields[1] = data.nFileSizeHigh;
        fields[2] = data.nFileSizeLow;
        fields[3] = data.ftLastWriteTime.dwHighDateTime;
        fields[4] = data.ftLastWriteTime.dwLowDateTime;
        fields[5] = name_size;
        memcpy(listing_bytes + length, fields, sizeof(fields)); length += 24;
        memcpy(listing_bytes + length, name, name_size); length += name_size;
    } while (FindNextFileW(handle, &data));
    status = GetLastError() == ERROR_NO_MORE_FILES ? 0 : ERROR_MORE_DATA;
finished:
    FindClose(handle);
    header[1] = status;
    memcpy(listing_bytes, header, sizeof(header));
    return transfer(outgoing, &length, 4, 1) && transfer(outgoing, listing_bytes, length, 1) ? 2 : 0;
header_only:
    return transfer(outgoing, &length, 4, 1) && transfer(outgoing, header, length, 1) ? 2 : 0;
}

static int send_screenshot(uint32_t nonce,uint32_t operation,const wchar_t *path,HANDLE outgoing) {
    LLLScreenshotJobStatus status;
    uint32_t fields[8]={nonce,ERROR_INVALID_DATA,0},length=8,path_size;
    int encoded;
    if (!path) goto header_only;
    if (operation==13) {
        /* Allocate and encode the exact immutable reply path BEFORE accepting
         * a worker: a rejected request must never leave an unacknowledged job. */
        encoded=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,NULL,0,NULL,NULL);
        if (encoded<=0) goto header_only;
        path_size=(uint32_t)encoded-1;length=68+path_size;
        fields[1]=listing_reserve(length+1);if (fields[1]) goto header_only;
        if (WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,(char*)listing_bytes+68,encoded,NULL,NULL)!=encoded) { fields[1]=ERROR_INVALID_DATA;goto header_only; }
        fields[1]=lll_screenshot_job_request(session_pid,executable,path,&status);
        if (fields[1]) goto header_only;
        if (strlen(status.id)!=32) return 0; /* Accepted: transport-uncertain, never a false rejection. */
    } else {
        fields[1]=operation==14?lll_screenshot_job_status(path,&status):lll_screenshot_job_cancel(path,&status);
        if (fields[1]) goto header_only;
        encoded=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,status.output_path,-1,NULL,0,NULL,NULL);
        if (encoded<=0||strlen(status.id)!=32) { fields[1]=ERROR_INVALID_DATA;goto header_only; }
        path_size=(uint32_t)encoded-1;length=68+path_size;
        fields[1]=listing_reserve(length+1);if (fields[1]) goto header_only;
        if (WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,status.output_path,-1,(char*)listing_bytes+68,encoded,NULL,NULL)!=encoded) { fields[1]=ERROR_INVALID_DATA;goto header_only; }
    }
    fields[2]=status.state;fields[3]=status.error;fields[4]=status.width;fields[5]=status.height;fields[6]=status.elapsed_ms;fields[7]=32;
    memcpy(listing_bytes,fields,sizeof(fields));memcpy(listing_bytes+32,status.id,32);memcpy(listing_bytes+64,&path_size,4);
    return transfer(outgoing,&length,4,1)&&transfer(outgoing,listing_bytes,length,1)?2:0;
header_only:
    length=8;
    return transfer(outgoing,&length,4,1)&&transfer(outgoing,fields,length,1)?2:0;
}

static int dispatch(const unsigned char *bytes, uint32_t size, HANDLE outgoing) {
    uint32_t nonce, operation, path_size;
    FILE *stream = NULL;
    if (size<12) return 0;
    memcpy(&nonce,bytes,4);memcpy(&operation,bytes+4,4);memcpy(&path_size,bytes+8,4);
    if (operation==0) {
        if (size!=12 || nonce!=0 || path_size!=0) return 0;
        lll_steam_boot(NULL);return 1;
    }
    if (operation==10 || operation==11 || operation==12) {
        uint32_t reply[11]={0},length=8;
        reply[0]=nonce;
        if (operation==11) {
            if (!lll_pointer_release()) reply[1]=ERROR_BUSY;
        } else if (operation==10) {
            LLLSteamPointerSnapshot snapshot;
            if (!lll_pointer_start(session_pid) || !lll_pointer_snapshot(&snapshot)) reply[1]=ERROR_NOT_READY;
            else { memcpy(reply+2,&snapshot,sizeof(snapshot));length=8+(uint32_t)sizeof(snapshot); }
        } else {
            LLLSteamPointerSample snapshot;
            if (!lll_pointer_start(session_pid) || !lll_pointer_snapshot_extended(&snapshot)) reply[1]=ERROR_NOT_READY;
            else { memcpy(reply+2,&snapshot,sizeof(snapshot));length=8+(uint32_t)sizeof(snapshot); }
        }
        return transfer(outgoing,&length,4,1)&&transfer(outgoing,reply,length,1) ? 2 : 0;
    }
    if (operation==8 || operation==9) {
        uint32_t reply[MAX_WATCHES+4],length;
        if (operation==8) lll_steam_poll(NULL);
        else { lll_screenshot_jobs_cancel_all();lll_pointer_release();lll_steam_close(NULL); }
        reply[0]=nonce;reply[1]=0;length=8;
        if (operation==8) {
            reply[2]=session_pid;reply[3]=watch_count;length=16+watch_count*4;
            for (uint32_t index=0;index<watch_count;++index) reply[index+4]=watches[index].generation;
        }
        /* Idle notifications never touch disk or invalidate a watched root. */
        return transfer(outgoing,&length,4,1)&&transfer(outgoing,reply,length,1) ? 2 : 0;
    }
    if (!nonce || path_size>size-12) return 0;
    if (operation==13||operation==14||operation==15) {
        wchar_t path[32768];
        return send_screenshot(nonce,operation,decode_path(bytes,size,path_size,path)?path:NULL,outgoing);
    }
    if (operation==1) {
        wchar_t path[32768];
        return send_listing(nonce,decode_path(bytes,size,path_size,path)?path:NULL,outgoing);
    }
    if (operation==2) {
        uint32_t reply[7]={0},length=8;
        wchar_t path[32768];
        WIN32_FILE_ATTRIBUTE_DATA data;
        reply[0]=nonce;reply[1]=ERROR_INVALID_DATA;
        if (decode_path(bytes,size,path_size,path)) {
            if (GetFileAttributesExW(path,GetFileExInfoStandard,&data)) {
                reply[1]=0;reply[2]=data.dwFileAttributes;
                reply[3]=data.nFileSizeHigh;reply[4]=data.nFileSizeLow;
                reply[5]=data.ftLastWriteTime.dwHighDateTime;reply[6]=data.ftLastWriteTime.dwLowDateTime;length=28;
            } else reply[1]=GetLastError();
        }
        return transfer(outgoing,&length,4,1)&&transfer(outgoing,reply,length,1) ? 2 : 0;
    }
    if (_wfopen_s(&stream,request_file,L"wb")) return 0;
    if (fwrite(bytes,1,size,stream)!=size) { fclose(stream);return 0; }
    fclose(stream);lll_steam_request(NULL);return 1;
}

int WINAPI wWinMain(HINSTANCE instance,HINSTANCE previous,PWSTR command,int show) {
    int count, result=1;
    LPWSTR *arguments=CommandLineToArgvW(GetCommandLineW(),&count);
    const wchar_t *root=NULL,*token=NULL;
    wchar_t incoming_name[256],outgoing_name[256],log_path[MAX_PATH],dll[32768];
    char hash[65];
    HANDLE incoming=INVALID_HANDLE_VALUE,outgoing=INVALID_HANDLE_VALUE;
    HANDLE single_instance=NULL;
    HANDLE ready_event=NULL;
    wchar_t ready_name[160];
    wchar_t mutex_name[96];
    DWORD peer=0;
    (void)instance;(void)previous;(void)command;(void)show;
    if (!arguments) return 1;
    for (int index=1;index+1<count;index+=2) {
        if (!wcscmp(arguments[index],L"--game")) root=arguments[index+1];
        else if (!wcscmp(arguments[index],L"--pipe")) token=arguments[index+1];
        else goto done;
    }
    if (!root || !token || wcslen(root)>32000 || wcslen(token)>96 || wcslen(token)<16) goto done;
    for (size_t index=0;index<wcslen(token);++index) if (!((token[index]>=L'a'&&token[index]<=L'z')||(token[index]>=L'0'&&token[index]<=L'9')||token[index]==L'_')) goto done;
    initialize();  /* Establish only the transport's ordinary output paths. */
    inline_events=1;
    if (!home[0] || !response_file[0]) goto done;
    swprintf_s(mutex_name,96,L"Local\\LLL_Steam_FS_%016llx",
        (unsigned long long)resource_hash((const unsigned char *)home,wcslen(home)*sizeof(wchar_t)));
    single_instance=CreateMutexW(NULL,FALSE,mutex_name);
    if (!single_instance || GetLastError()==ERROR_ALREADY_EXISTS) goto done;
    swprintf_s(log_path,MAX_PATH,L"%s\\service.log",home);
    service_log=_wfsopen(log_path,L"wb",_SH_DENYNO);
    wcscpy_s(game_root,32768,root);
    swprintf_s(executable,32768,L"%s\\bin\\helldivers2.exe",root);
    swprintf_s(dll,32768,L"%s\\data\\game\\game.dll",root);
    supported=hash_file(executable,hash)&&!strcmp(hash,EXE_SHA)&&hash_file(dll,hash)&&!strcmp(hash,GAME_SHA);
    if (!supported) { note("Refused: installed game hashes do not match this service build");goto done; }
    note("Stock game hashes verified; awaiting local Lua filesystem client");
    swprintf_s(incoming_name,256,L"\\\\.\\pipe\\%s_request",token);
    swprintf_s(outgoing_name,256,L"\\\\.\\pipe\\%s_response",token);
    io_event=CreateEventW(NULL,TRUE,FALSE,NULL);if (!io_event) goto done;
    incoming=CreateNamedPipeW(incoming_name,PIPE_ACCESS_INBOUND|FILE_FLAG_FIRST_PIPE_INSTANCE|FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE|PIPE_READMODE_BYTE|PIPE_WAIT|PIPE_REJECT_REMOTE_CLIENTS,1,65536,65536,0,NULL);
    outgoing=CreateNamedPipeW(outgoing_name,PIPE_ACCESS_OUTBOUND|FILE_FLAG_FIRST_PIPE_INSTANCE|FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE|PIPE_READMODE_BYTE|PIPE_WAIT|PIPE_REJECT_REMOTE_CLIENTS,1,65536,65536,0,NULL);
    if (incoming==INVALID_HANDLE_VALUE || outgoing==INVALID_HANDLE_VALUE) { note("Cannot create exclusive local pipes");goto done; }
    swprintf_s(ready_name,160,L"Local\\LLL_Steam_Ready_%s",token);
    ready_event=CreateEventW(NULL,TRUE,FALSE,ready_name);
    if (!ready_event || !SetEvent(ready_event)) { note("Cannot signal filesystem service readiness");goto done; }
    if (!connect_pipe(incoming)||!connect_pipe(outgoing)) { note("No complete client connection within startup timeout");goto done; }
    if (!GetNamedPipeClientProcessId(incoming,&session_pid)||!GetNamedPipeClientProcessId(outgoing,&peer)||peer!=session_pid) {
        note("Refused: request and response clients differ");goto done;
    }
    note("Local Lua client connected; filesystem and visible-menu pointer service ready");
    for (;;) {
        uint32_t size;
        unsigned char *bytes;
        int ok;
        if (!transfer(incoming,&size,4,0)) break;
        if (size<12||size>MAX_REQUEST) { note("Refused oversized or truncated request");break; }
        bytes=malloc(size);if (!bytes) break;
        ok=transfer(incoming,bytes,size,0) ? dispatch(bytes,size,outgoing) : 0;free(bytes);
        if (!ok||(ok==1&&!send_file(outgoing))) break;
    }
    note("Client disconnected; service stopped");result=0;
done:
    if (ready_event) ResetEvent(ready_event);
    if (incoming!=INVALID_HANDLE_VALUE) { CloseHandle(incoming);incoming=INVALID_HANDLE_VALUE; }
    if (outgoing!=INVALID_HANDLE_VALUE) { CloseHandle(outgoing);outgoing=INVALID_HANDLE_VALUE; }
    lll_screenshot_jobs_shutdown();
    lll_pointer_release();
    free(listing_bytes);
    if (ready_event) { ResetEvent(ready_event);CloseHandle(ready_event); }
    lll_steam_close(NULL);
    if (incoming!=INVALID_HANDLE_VALUE) CloseHandle(incoming);
    if (outgoing!=INVALID_HANDLE_VALUE) CloseHandle(outgoing);
    if (io_event) CloseHandle(io_event);
    if (single_instance) CloseHandle(single_instance);
    if (service_log) fclose(service_log);
    LocalFree(arguments);return result;
}
