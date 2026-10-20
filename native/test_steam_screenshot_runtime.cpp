// Runtime-only regression for the production Apartment boundary. This fixture
// never calls the screenshot entry, opens a process/window, creates a graphics
// device/capture session, or starts capture. It queries activation factories only.
#include "steam_screenshot.cpp"
#include <cstdio>

namespace {
struct ExpectedUnwind {};
struct RuntimeCase {
    unsigned index;
    bool unwind;
    bool supported = false;
    DWORD error = 0;
    const char* phase = "initial cache check";
};

template<class Class, class Interface> bool cached() noexcept {
    return winrt::impl::factory_cache_entry_v<Class, Interface>.m_value.object != nullptr;
}
bool all_cached() noexcept {
    return cached<capture::GraphicsCaptureSession, capture::IGraphicsCaptureSessionStatics>() &&
           cached<capture::GraphicsCaptureItem, IGraphicsCaptureItemInterop>() &&
           cached<capture::Direct3D11CaptureFramePool, capture::IDirect3D11CaptureFramePoolStatics2>();
}
bool all_clear() noexcept {
    return !cached<capture::GraphicsCaptureSession, capture::IGraphicsCaptureSessionStatics>() &&
           !cached<capture::GraphicsCaptureItem, IGraphicsCaptureItemInterop>() &&
           !cached<capture::Direct3D11CaptureFramePool, capture::IDirect3D11CaptureFramePoolStatics2>();
}
void check_case(bool condition, RuntimeCase& test, const char* phase) {
    test.phase = phase;
    if (!condition) throw winrt::hresult_error(E_UNEXPECTED);
}
DWORD WINAPI runtime_case(void* parameter) noexcept {
    auto& test = *static_cast<RuntimeCase*>(parameter);
    try {
        check_case(all_clear(), test, "cache nonnull before new worker apartment");
        bool unwound = false;
        try {
            // Use the exact production RAII implementation. All factory locals
            // below are destroyed before Apartment on normal and exception exit.
            Apartment apartment;
            test.phase = "GraphicsCaptureSession::IsSupported";
            test.supported = capture::GraphicsCaptureSession::IsSupported();
            test.phase = "GraphicsCaptureItem interop factory";
            auto item = winrt::get_activation_factory<capture::GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
            test.phase = "Direct3D11CaptureFramePool statics2 factory";
            auto pool = winrt::get_activation_factory<capture::Direct3D11CaptureFramePool, capture::IDirect3D11CaptureFramePoolStatics2>();
            check_case(item && pool, test, "typed factory references missing");
            check_case(all_cached(), test, "expected agile factory cache entries missing while active");
            if (test.unwind) throw ExpectedUnwind{};
        } catch (const ExpectedUnwind&) {
            // This handler is outside Apartment: its destructor must already
            // have cleared the cache and then uninitialized the worker apartment.
            unwound = true;
        }
        check_case(unwound == test.unwind, test, "unexpected exception-unwind path");
        check_case(all_clear(), test, "factory cache survived production Apartment destruction");
        test.phase = "complete";
    } catch (const winrt::hresult_error& error) {
        test.error = static_cast<DWORD>(error.code().value);
    } catch (const std::bad_alloc&) {
        test.error = static_cast<DWORD>(E_OUTOFMEMORY);
    } catch (...) {
        test.error = static_cast<DWORD>(E_FAIL);
    }
    return test.error;
}
} // namespace

int main() {
    unsigned normal = 0, unwind = 0, supported = 0;
    for (unsigned index = 0; index < 32; ++index) {
        RuntimeCase test{index, (index & 1u) != 0};
        HANDLE thread = CreateThread(nullptr, 0, runtime_case, &test, 0, nullptr);
        if (!thread) { std::fprintf(stderr, "FAIL: CreateThread error=%lu\n", static_cast<unsigned long>(GetLastError())); return 1; }
        // No next worker exists until the preceding worker has fully exited.
        const DWORD waited = WaitForSingleObject(thread, INFINITE);
        DWORD returned = ERROR_GEN_FAILURE;
        const BOOL exited = waited == WAIT_OBJECT_0 && GetExitCodeThread(thread, &returned);
        const BOOL closed = CloseHandle(thread);
        if (!exited || !closed || returned || test.error) {
            std::fprintf(stderr, "FAIL: worker=%u unwind=%u phase=%s error=0x%08lx exit=0x%08lx\n",
                         test.index, test.unwind ? 1u : 0u, test.phase,
                         static_cast<unsigned long>(test.error), static_cast<unsigned long>(returned));
            return 1;
        }
        if (test.unwind) ++unwind; else ++normal;
        if (test.supported) ++supported;
    }
    std::printf("PASS: %u normal + %u exception-unwind fresh worker apartments; three factory caches active then cleared each time; IsSupported true %u/32; no capture, device/session/window creation, or process access\n",
                normal, unwind, supported);
    return 0;
}
