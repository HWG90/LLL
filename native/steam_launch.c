/* One-shot helper launcher for Wine/Proton and Windows. No PowerShell dependency. */
#define WIN32_LEAN_AND_MEAN
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shellapi.h>
#include <bcrypt.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#ifndef LLL_HELPER_NAME
#error Define content-addressed helper name and SHA256 at build time
#endif
static int hash_matches(const wchar_t *path) {
    HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,0,NULL);
    BCRYPT_ALG_HANDLE algorithm=NULL;BCRYPT_HASH_HANDLE hash=NULL;
    unsigned char buffer[65536],digest[32];char hex[65];DWORD count;int ok=0;
    if (file==INVALID_HANDLE_VALUE) return 0;
    if (BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,NULL,0)<0 || BCryptCreateHash(algorithm,&hash,NULL,0,NULL,0,0)<0)goto done;
    for (;;) {if (!ReadFile(file,buffer,sizeof(buffer),&count,NULL))goto done;if (!count)break;if (BCryptHashData(hash,buffer,count,0)<0)goto done;}
    if (BCryptFinishHash(hash,digest,32,0)<0)goto done;
    for (count=0;count<32;count++)sprintf(hex+count*2,"%02x",digest[count]);
    ok=!strcmp(hex,LLL_HELPER_SHA256);
done:
    if(hash)BCryptDestroyHash(hash);if(algorithm)BCryptCloseAlgorithmProvider(algorithm,0);CloseHandle(file);return ok;
}
int wmain(int argc,wchar_t **argv) {
    wchar_t directory[32768],helper[32768],binding[32768],game[32768],command[65536],event_name[160];
    char utf8[65536];DWORD length,count;HANDLE file=INVALID_HANDLE_VALUE,ready=NULL;
    STARTUPINFOW startup={0};PROCESS_INFORMATION child={0};int result=1,created=0;
    if(argc!=3 || wcscmp(argv[1],L"--pipe"))goto done;
    length=(DWORD)wcslen(argv[2]);if(length<16 || length>96)goto done;
    for(DWORD i=0;i<length;i++)if(!((argv[2][i]>=L'a'&&argv[2][i]<=L'z')||(argv[2][i]>=L'0'&&argv[2][i]<=L'9')||argv[2][i]==L'_'))goto done;
    length=GetModuleFileNameW(NULL,directory,32768);if(!length || length>=32768)goto done;
    wchar_t *last=wcsrchr(directory,L'\\');if(!last)goto done;*last=0;
    if(swprintf(helper,32768,L"%ls\\%ls",directory,LLL_HELPER_NAME)<0 || swprintf(binding,32768,L"%ls\\game-root.txt",directory)<0)goto done;
    if(!hash_matches(helper))goto done;
    file=CreateFileW(binding,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,0,NULL);
    if(file==INVALID_HANDLE_VALUE)goto done;
    if(GetFileSize(file,NULL)>=sizeof(utf8) || !ReadFile(file,utf8,sizeof(utf8),&count,NULL))goto done;
    CloseHandle(file);file=INVALID_HANDLE_VALUE;
    while(count && (utf8[count-1]=='\r'||utf8[count-1]=='\n'))count--;
    length=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,utf8,count,game,32767);if(!length)goto done;game[length]=0;
    if(!((length>3 && game[1]==L':' && (game[2]==L'\\'||game[2]==L'/')) || (length>2 && game[0]==L'\\'&&game[1]==L'\\')))goto done;
    for(DWORD i=0;i<length;i++)if(game[i]<32 || game[i]==L'"')goto done;
    while(length>3 && (game[length-1]==L'\\'||game[length-1]==L'/'))game[--length]=0;
    if(game[length-1]==L'\\')goto done;
    if(swprintf(event_name,160,L"Local\\LLL_Steam_Ready_%ls",argv[2])<0)goto done;
    ready=CreateEventW(NULL,TRUE,FALSE,event_name);if(!ready)goto done;
    created=GetLastError()!=ERROR_ALREADY_EXISTS;
    if(WaitForSingleObject(ready,0)==WAIT_OBJECT_0){result=0;goto done;}
    if(created) {
        if(swprintf(command,65536,L"\"%ls\" --game \"%ls\" --pipe %ls",helper,game,argv[2])<0)goto done;
        startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESHOWWINDOW;startup.wShowWindow=SW_HIDE;
        if(!CreateProcessW(helper,command,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,directory,&startup,&child))goto done;
        HANDLE handles[2]={ready,child.hProcess};
        if(WaitForMultipleObjects(2,handles,FALSE,8000)==WAIT_OBJECT_0)result=0;
    } else if(WaitForSingleObject(ready,8000)==WAIT_OBJECT_0)result=0;
done:
    if(result && child.hProcess && WaitForSingleObject(child.hProcess,0)==WAIT_TIMEOUT){TerminateProcess(child.hProcess,1);WaitForSingleObject(child.hProcess,2000);}
    if(file!=INVALID_HANDLE_VALUE)CloseHandle(file);if(ready)CloseHandle(ready);
    if(child.hThread)CloseHandle(child.hThread);if(child.hProcess)CloseHandle(child.hProcess);
    puts(result?"LLL_ERROR: helper launch, fingerprint or readiness failed":"LLL_READY");
    return result;
}
