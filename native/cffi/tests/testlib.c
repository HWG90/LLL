#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif
EXPORT int ffi_test_add(int a, int b) { return a+b; }
EXPORT int ffi_test_callback(int (*callback)(int), int value) { return callback(value)+1; }
