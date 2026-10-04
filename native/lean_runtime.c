#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <stdint.h>
#include <intrin.h>
uintptr_t __security_cookie=0x2b992ddfa232ULL;
__declspec(safebuffers) void __cdecl __security_check_cookie(uintptr_t cookie) {
 if(cookie!=__security_cookie)__fastfail(2);
}
__declspec(safebuffers) BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID reserved) {
 (void)instance;(void)reserved;
 if(reason==DLL_PROCESS_ATTACH) {
  uintptr_t cookie=0;
  if(BCryptGenRandom(NULL,(PUCHAR)&cookie,sizeof(cookie),BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0)return FALSE;
  cookie&=0x0000ffffffffffffULL;
  if(!cookie || cookie==__security_cookie)return FALSE;
  __security_cookie=cookie;
 }
 return TRUE;
}
