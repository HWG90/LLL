// External, one-shot WGC worker. Adapted from David's existing
// DBF_PhotoMode/freecam/native/window_capture.cpp; no game-loaded component.
// Physical client pixels only. SDR BGRA8; fail closed on unknown/HDR output.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "steam_screenshot.h"
#include <dwmapi.h>
#include <d3d11.h>
#include <dxgi1_6.h>
#include <wincodec.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <algorithm>
#include <cstddef>
#include <cwchar>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace capture = winrt::Windows::Graphics::Capture;
namespace directx = winrt::Windows::Graphics::DirectX;
namespace d3d = winrt::Windows::Graphics::DirectX::Direct3D11;
namespace {
constexpr ULONGLONG kDeadlineMs = 5000;
constexpr uint64_t kMaxPixels = 64ull * 1024 * 1024;

void require(bool condition, DWORD error = ERROR_INVALID_DATA) {
    if (!condition) throw winrt::hresult_error(HRESULT_FROM_WIN32(error));
}
void last_error() {
    const DWORD error = GetLastError();
    throw winrt::hresult_error(HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE));
}
struct Operation {
    const LLLScreenshotRequest& request;
    const ULONGLONG begun = GetTickCount64();
    void check() const {
        const DWORD waited = WaitForSingleObject(request.cancel_event, 0);
        if (waited == WAIT_FAILED) last_error();
        require(waited == WAIT_TIMEOUT &&
                InterlockedCompareExchange(request.publication, LLL_SCREENSHOT_OPEN, LLL_SCREENSHOT_OPEN) == LLL_SCREENSHOT_OPEN,
                ERROR_CANCELLED);
        require(GetTickCount64() - begun < kDeadlineMs, ERROR_TIMEOUT);
    }
    DWORD remaining() const {
        check();
        const ULONGLONG elapsed = GetTickCount64() - begun;
        require(elapsed < kDeadlineMs, ERROR_TIMEOUT);
        return static_cast<DWORD>(kDeadlineMs - elapsed);
    }
};
struct Apartment {
    Apartment() { winrt::init_apartment(winrt::apartment_type::multi_threaded); }
    ~Apartment() { winrt::uninit_apartment(); }
};
struct ThreadDpiContext {
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    ThreadDpiContext() { if (!previous) last_error(); }
    ~ThreadDpiContext() { SetThreadDpiAwarenessContext(previous); }
};
int64_t width(const RECT& rect) { return static_cast<int64_t>(rect.right) - rect.left; }
int64_t height(const RECT& rect) { return static_cast<int64_t>(rect.bottom) - rect.top; }
struct Geometry {
    RECT window{}, client{}, dwm{};
    bool has_dwm = false;
    HMONITOR monitor = nullptr;
    UINT dpi = 0;
};
Geometry geometry(HWND window) {
    Geometry value;
    RECT client{};
    if (!GetWindowRect(window, &value.window) || !GetClientRect(window, &client)) last_error();
    POINT first{client.left, client.top}, last{client.right, client.bottom};
    if (!ClientToScreen(window, &first) || !ClientToScreen(window, &last)) last_error();
    value.client = {first.x, first.y, last.x, last.y};
    require(width(value.window) > 0 && height(value.window) > 0 && width(value.client) > 0 && height(value.client) > 0);
    value.has_dwm = SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &value.dwm, sizeof(value.dwm))) &&
                    width(value.dwm) > 0 && height(value.dwm) > 0;
    value.monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONULL);
    value.dpi = GetDpiForWindow(window);
    require(value.monitor && value.dpi);
    return value;
}
struct Crop { UINT left, top, width, height; };
Crop client_crop(const Geometry& value, int64_t frame_width, int64_t frame_height) {
    require(frame_width > 0 && frame_height > 0 && frame_width <= 16384 && frame_height <= 16384 &&
            static_cast<uint64_t>(frame_width) * frame_height <= kMaxPixels);
    const bool matches_window = width(value.window) == frame_width && height(value.window) == frame_height;
    const bool matches_dwm = value.has_dwm && width(value.dwm) == frame_width && height(value.dwm) == frame_height;
    require(matches_window || matches_dwm);
    require(!(matches_window && matches_dwm) || EqualRect(&value.window, &value.dwm));
    const RECT frame = matches_dwm ? value.dwm : value.window;
    require(width(value.client) > 0 && height(value.client) > 0 && value.client.left >= frame.left && value.client.top >= frame.top &&
            value.client.right <= frame.right && value.client.bottom <= frame.bottom);
    return {static_cast<UINT>(static_cast<int64_t>(value.client.left) - frame.left),
            static_cast<UINT>(static_cast<int64_t>(value.client.top) - frame.top),
            static_cast<UINT>(width(value.client)), static_cast<UINT>(height(value.client))};
}
struct WindowSearch { DWORD pid; HWND window = nullptr; unsigned count = 0; bool unreadable = false; };
BOOL CALLBACK eligible_window(HWND window, LPARAM parameter) {
    auto& search = *reinterpret_cast<WindowSearch*>(parameter);
    DWORD pid = 0; GetWindowThreadProcessId(window, &pid);
    if (pid != search.pid || !IsWindowVisible(window) || IsIconic(window)) return TRUE;
    DWORD cloaked = 0;
    if (FAILED(DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked)))) search.unreadable = true;
    else if (!cloaked) { search.window = window; ++search.count; }
    return TRUE;
}
HWND unique_window(DWORD pid) {
    WindowSearch search{pid};
    if (!EnumWindows(eligible_window, reinterpret_cast<LPARAM>(&search))) last_error();
    require(!search.unreadable && search.count == 1, ERROR_INVALID_WINDOW_HANDLE);
    return search.window;
}
void expected_executable(HANDLE process, const std::wstring& expected) {
    wchar_t image[32768]; DWORD length = static_cast<DWORD>(std::size(image));
    if (!QueryFullProcessImageNameW(process, 0, image, &length)) last_error();
    require(length && CompareStringOrdinal(image, static_cast<int>(length), expected.c_str(), -1, TRUE) == CSTR_EQUAL,
            ERROR_INVALID_EXE_SIGNATURE);
}
struct Identity {
    const LLLScreenshotRequest& request;
    const std::wstring executable;
    winrt::handle process;
    HWND window = nullptr;
    DWORD thread = 0;
    Geometry bounds;
    explicit Identity(const LLLScreenshotRequest& value) : request(value), executable(value.executable) {
        require(std::filesystem::path(executable).is_absolute() &&
                _wcsicmp(std::filesystem::path(executable).filename().c_str(), L"helldivers2.exe") == 0,
                ERROR_INVALID_EXE_SIGNATURE);
        process.attach(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, request.pid));
        if (!process) last_error();
        expected_executable(process.get(), executable);
        window = unique_window(request.pid);
        DWORD owner = 0; thread = GetWindowThreadProcessId(window, &owner);
        require(thread && owner == request.pid, ERROR_INVALID_WINDOW_HANDLE);
        bounds = geometry(window);
        validate();
    }
    void validate() const {
        require(WaitForSingleObject(process.get(), 0) == WAIT_TIMEOUT, ERROR_PROCESS_ABORTED);
        FILETIME created{}, exited{}, kernel{}, user{};
        if (!GetProcessTimes(process.get(), &created, &exited, &kernel, &user)) last_error();
        require(CompareFileTime(&created, &request.created) == 0, ERROR_INVALID_PARAMETER);
        expected_executable(process.get(), executable);
        DWORD owner = 0;
        require(IsWindow(window) && GetWindowThreadProcessId(window, &owner) == thread && owner == request.pid &&
                unique_window(request.pid) == window && GetAncestor(window, GA_ROOT) == window && GetForegroundWindow() == window,
                ERROR_INVALID_WINDOW_HANDLE);
        const auto current = geometry(window);
        require(EqualRect(&bounds.window, &current.window) && EqualRect(&bounds.client, &current.client) &&
                bounds.has_dwm == current.has_dwm && (!bounds.has_dwm || EqualRect(&bounds.dwm, &current.dwm)) &&
                bounds.monitor == current.monitor && bounds.dpi == current.dpi, ERROR_RETRY);
    }
};
void require_sdr(HMONITOR monitor, const Operation& operation) {
    winrt::com_ptr<IDXGIFactory1> factory;
    winrt::check_hresult(CreateDXGIFactory1(__uuidof(IDXGIFactory1), factory.put_void()));
    unsigned matched = 0;
    for (UINT adapter_index = 0; adapter_index < 64; ++adapter_index) {
        operation.check();
        winrt::com_ptr<IDXGIAdapter1> adapter;
        const HRESULT adapter_result = factory->EnumAdapters1(adapter_index, adapter.put());
        if (adapter_result == DXGI_ERROR_NOT_FOUND) { require(matched == 1 && factory->IsCurrent(), ERROR_NOT_SUPPORTED); return; }
        winrt::check_hresult(adapter_result);
        bool finished = false;
        for (UINT output_index = 0; output_index < 64; ++output_index) {
            winrt::com_ptr<IDXGIOutput> output;
            const HRESULT result = adapter->EnumOutputs(output_index, output.put());
            if (result == DXGI_ERROR_NOT_FOUND) { finished = true; break; }
            winrt::check_hresult(result);
            DXGI_OUTPUT_DESC basic{}; winrt::check_hresult(output->GetDesc(&basic));
            if (basic.Monitor != monitor) continue;
            ++matched;
            auto extended = output.as<IDXGIOutput6>();
            DXGI_OUTPUT_DESC1 desc{}; winrt::check_hresult(extended->GetDesc1(&desc));
            require(desc.Monitor == monitor && desc.AttachedToDesktop &&
                    desc.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709, ERROR_NOT_SUPPORTED);
        }
        require(finished, ERROR_NOT_SUPPORTED);
    }
    require(false, ERROR_NOT_SUPPORTED);
}
struct FrameState {
    std::mutex mutex;
    HANDLE ready = nullptr; // Borrowed; cleanup clears it under mutex before closing.
    bool closed = false;
};
struct CaptureLifetime {
    winrt::handle ready{CreateEventW(nullptr, FALSE, FALSE, nullptr)};
    std::shared_ptr<FrameState> state = std::make_shared<FrameState>();
    capture::GraphicsCaptureItem item{nullptr};
    capture::Direct3D11CaptureFramePool pool{nullptr};
    capture::GraphicsCaptureSession session{nullptr};
    capture::Direct3D11CaptureFramePool::FrameArrived_revoker arrived;
    capture::GraphicsCaptureItem::Closed_revoker closed;
    CaptureLifetime() { if (!ready) last_error(); state->ready = ready.get(); }
    void check() const { std::lock_guard<std::mutex> lock(state->mutex); require(!state->closed, ERROR_INVALID_WINDOW_HANDLE); }
    void close() noexcept {
        { std::lock_guard<std::mutex> lock(state->mutex); state->closed = true; state->ready = nullptr; }
        arrived.revoke(); closed.revoke();
        if (session) { try { session.Close(); } catch (...) {} session = nullptr; }
        if (pool) { try { pool.Close(); } catch (...) {} pool = nullptr; }
        item = nullptr;
        ready.close();
    }
    ~CaptureLifetime() { close(); }
};
struct FrameLifetime {
    capture::Direct3D11CaptureFrame value{nullptr};
    ~FrameLifetime() { if (value) { try { value.Close(); } catch (...) {} } }
};
struct MappedTexture {
    ID3D11DeviceContext* context;
    ID3D11Texture2D* texture;
    ~MappedTexture() { context->Unmap(texture, 0); }
};
winrt::com_ptr<IStream> encode_png(UINT width, UINT height, const D3D11_MAPPED_SUBRESOURCE& pixels) {
    require(pixels.RowPitch >= width * 4 && static_cast<uint64_t>(pixels.RowPitch) * height <= MAXDWORD);
    auto factory = winrt::create_instance<IWICImagingFactory>(CLSID_WICImagingFactory);
    winrt::com_ptr<IStream> stream;
    winrt::check_hresult(CreateStreamOnHGlobal(nullptr, TRUE, stream.put()));
    winrt::com_ptr<IWICBitmapEncoder> encoder;
    winrt::check_hresult(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, encoder.put()));
    winrt::check_hresult(encoder->Initialize(stream.get(), WICBitmapEncoderNoCache));
    winrt::com_ptr<IWICBitmapFrameEncode> image;
    winrt::check_hresult(encoder->CreateNewFrame(image.put(), nullptr));
    winrt::check_hresult(image->Initialize(nullptr));
    winrt::check_hresult(image->SetSize(width, height));
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    winrt::check_hresult(image->SetPixelFormat(&format));
    require(IsEqualGUID(format, GUID_WICPixelFormat32bppBGRA));
    winrt::check_hresult(image->WritePixels(height, pixels.RowPitch, pixels.RowPitch * height, static_cast<BYTE*>(pixels.pData)));
    winrt::check_hresult(image->Commit());
    winrt::check_hresult(encoder->Commit());
    return stream;
}
std::wstring output_path(const wchar_t* text) {
    const std::filesystem::path path(text);
    require(path.is_absolute() && _wcsicmp(path.extension().c_str(), L".png") == 0, ERROR_INVALID_NAME);
    const auto normalized = path.lexically_normal();
    const auto raw = normalized.native();
    const auto colon = raw.find(L':');
    require(colon == std::wstring::npos || (colon == 1 && raw.find(L':', 2) == std::wstring::npos), ERROR_INVALID_NAME);
    const DWORD attributes = GetFileAttributesW(normalized.parent_path().c_str());
    require(attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) &&
            !(attributes & FILE_ATTRIBUTE_REPARSE_POINT), ERROR_PATH_NOT_FOUND);
    return raw;
}
struct ExclusiveOutput {
    winrt::handle file;
    explicit ExclusiveOutput(const std::wstring& path) {
        GUID unique{}; winrt::check_hresult(CoCreateGuid(&unique));
        wchar_t name[40]; require(StringFromGUID2(unique, name, static_cast<int>(std::size(name))) != 0);
        const auto temporary = std::filesystem::path(path).parent_path() / (std::wstring(L".lll-steam-screenshot-") + name + L".tmp");
        HANDLE created = CreateFileW(temporary.c_str(), GENERIC_WRITE | DELETE, 0, nullptr, CREATE_NEW,
                                     FILE_ATTRIBUTE_NORMAL | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
        if (created == INVALID_HANDLE_VALUE) last_error();
        file.attach(created);
    }
    void publish(const std::wstring& path, const Operation& operation) {
        const size_t bytes = sizeof(FILE_RENAME_INFO) + path.size() * sizeof(wchar_t);
        require(bytes <= MAXDWORD, ERROR_FILENAME_EXCED_RANGE);
        std::vector<BYTE> storage(bytes, 0);
        auto* rename = reinterpret_cast<FILE_RENAME_INFO*>(storage.data());
        rename->ReplaceIfExists = FALSE;
        rename->FileNameLength = static_cast<DWORD>(path.size() * sizeof(wchar_t));
        std::copy(path.begin(), path.end(), rename->FileName);
        operation.check();
        require(InterlockedCompareExchange(operation.request.publication, LLL_SCREENSHOT_PUBLISHING, LLL_SCREENSHOT_OPEN) == LLL_SCREENSHOT_OPEN,
                ERROR_CANCELLED);
        if (!SetFileInformationByHandle(file.get(), FileRenameInfo, rename, static_cast<DWORD>(bytes))) last_error();
        FILE_DISPOSITION_INFO_EX keep{FILE_DISPOSITION_FLAG_ON_CLOSE};
        if (!SetFileInformationByHandle(file.get(), FileDispositionInfoEx, &keep, sizeof(keep))) last_error();
        file.close();
        InterlockedExchange(operation.request.publication, LLL_SCREENSHOT_PUBLISHED);
    }
};
void save_window(const LLLScreenshotRequest& request, LLLScreenshotResult& result, const Operation& operation) {
    operation.check();
    const std::wstring path = output_path(request.output_path);
    ThreadDpiContext dpi;
    Identity identity(request);
    require_sdr(identity.bounds.monitor, operation);
    require(capture::GraphicsCaptureSession::IsSupported(), ERROR_NOT_SUPPORTED);
    CaptureLifetime lifetime;
    auto interop = winrt::get_activation_factory<capture::GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
    winrt::check_hresult(interop->CreateForWindow(identity.window, winrt::guid_of<capture::GraphicsCaptureItem>(), winrt::put_abi(lifetime.item)));
    const auto size = lifetime.item.Size();
    const auto crop = client_crop(identity.bounds, size.Width, size.Height);
    operation.check();
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext> context;
    const D3D_FEATURE_LEVEL levels[]{D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    winrt::check_hresult(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        levels, static_cast<UINT>(std::size(levels)), D3D11_SDK_VERSION, device.put(), nullptr, context.put()));
    auto dxgi = device.as<IDXGIDevice>();
    winrt::com_ptr<IInspectable> inspectable;
    winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()));
    const auto projected = inspectable.as<d3d::IDirect3DDevice>();
    lifetime.pool = capture::Direct3D11CaptureFramePool::CreateFreeThreaded(projected,
        directx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
    lifetime.session = lifetime.pool.CreateCaptureSession(lifetime.item);
    lifetime.session.IsCursorCaptureEnabled(false);
    const std::weak_ptr<FrameState> weak = lifetime.state;
    lifetime.arrived = lifetime.pool.FrameArrived(winrt::auto_revoke, [weak](const auto&, const auto&) noexcept {
        if (const auto state = weak.lock()) {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (state->ready && !state->closed) SetEvent(state->ready);
        }
    });
    lifetime.closed = lifetime.item.Closed(winrt::auto_revoke, [weak](const auto&, const auto&) noexcept {
        if (const auto state = weak.lock()) {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->closed = true;
            if (state->ready) SetEvent(state->ready);
        }
    });
    LARGE_INTEGER ticks{}, frequency{};
    require(QueryPerformanceCounter(&ticks) && QueryPerformanceFrequency(&frequency));
    const int64_t fresh_after = static_cast<int64_t>(static_cast<long double>(ticks.QuadPart) * 10000000 / frequency.QuadPart);
    operation.check(); identity.validate();
    lifetime.session.StartCapture();
    FrameLifetime accepted;
    HANDLE waits[]{request.cancel_event, lifetime.ready.get(), identity.process.get()};
    while (!accepted.value) {
        const DWORD waited = WaitForMultipleObjects(static_cast<DWORD>(std::size(waits)), waits, FALSE, operation.remaining());
        if (waited == WAIT_FAILED) last_error();
        require(waited == WAIT_OBJECT_0 + 1, waited == WAIT_TIMEOUT ? ERROR_TIMEOUT : waited == WAIT_OBJECT_0 ? ERROR_CANCELLED : ERROR_PROCESS_ABORTED);
        operation.check(); lifetime.check();
        FrameLifetime pending;
        pending.value = lifetime.pool.TryGetNextFrame();
        if (!pending.value) continue; // Only retry after another FrameArrived notification.
        if (pending.value.SystemRelativeTime().count() < fresh_after) continue;
        const auto content = pending.value.ContentSize();
        require(content.Width == size.Width && content.Height == size.Height, ERROR_RETRY);
        accepted.value = pending.value; pending.value = nullptr;
    }
    identity.validate();
    auto access = accepted.value.Surface().as<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    winrt::com_ptr<ID3D11Texture2D> surface;
    winrt::check_hresult(access->GetInterface(__uuidof(ID3D11Texture2D), surface.put_void()));
    D3D11_TEXTURE2D_DESC desc{}; surface->GetDesc(&desc);
    require(desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM && desc.SampleDesc.Count == 1 &&
            desc.Width >= static_cast<UINT>(size.Width) && desc.Height >= static_cast<UINT>(size.Height), ERROR_NOT_SUPPORTED);
    desc.Width = crop.width; desc.Height = crop.height; desc.MipLevels = 1; desc.ArraySize = 1;
    desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ; desc.MiscFlags = 0;
    winrt::com_ptr<ID3D11Texture2D> staging;
    winrt::check_hresult(device->CreateTexture2D(&desc, nullptr, staging.put()));
    const D3D11_BOX content{crop.left, crop.top, 0, crop.left + crop.width, crop.top + crop.height, 1};
    context->CopySubresourceRegion(staging.get(), 0, 0, 0, 0, surface.get(), 0, &content);
    D3D11_MAPPED_SUBRESOURCE pixels{};
    winrt::check_hresult(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &pixels));
    MappedTexture mapped{context.get(), staging.get()};
    operation.check(); identity.validate(); lifetime.check();
    auto png = encode_png(crop.width, crop.height, pixels);
    operation.check(); identity.validate(); lifetime.check();
    require_sdr(identity.bounds.monitor, operation);
    accepted.value.Close(); accepted.value = nullptr;
    surface = nullptr; access = nullptr;
    lifetime.close();
    STATSTG status{}; winrt::check_hresult(png->Stat(&status, STATFLAG_NONAME));
    require(status.cbSize.QuadPart > 8 && status.cbSize.QuadPart <= 512ull * 1024 * 1024);
    LARGE_INTEGER beginning{}; winrt::check_hresult(png->Seek(beginning, STREAM_SEEK_SET, nullptr));
    ExclusiveOutput output(path);
    uint64_t remaining = status.cbSize.QuadPart;
    BYTE buffer[65536];
    while (remaining) {
        operation.check();
        const ULONG requested = static_cast<ULONG>(std::min<uint64_t>(sizeof(buffer), remaining));
        ULONG read = 0; winrt::check_hresult(png->Read(buffer, requested, &read));
        require(read == requested, ERROR_HANDLE_EOF);
        DWORD written = 0;
        if (!WriteFile(output.file.get(), buffer, read, &written, nullptr)) last_error();
        require(written == read, ERROR_WRITE_FAULT); remaining -= read;
    }
    if (!FlushFileBuffers(output.file.get())) last_error();
    operation.check(); identity.validate();
    require_sdr(identity.bounds.monitor, operation);
    output.publish(path, operation);
    result.width = crop.width; result.height = crop.height;
}
} // namespace

extern "C" DWORD lll_steam_screenshot_capture(const LLLScreenshotRequest* request, LLLScreenshotResult* result) {
    if (!result) return ERROR_INVALID_PARAMETER;
    *result = {};
    const ULONGLONG begun = GetTickCount64();
    try {
        require(request && request->pid && request->executable && *request->executable && request->output_path &&
                *request->output_path && request->cancel_event && request->publication, ERROR_INVALID_PARAMETER);
        const Operation operation{*request};
        operation.check();
        Apartment apartment;
        save_window(*request, *result, operation);
    } catch (const winrt::hresult_error& error) { result->error = static_cast<uint32_t>(error.code().value); }
      catch (const std::bad_alloc&) { result->error = static_cast<uint32_t>(E_OUTOFMEMORY); }
      catch (...) { result->error = static_cast<uint32_t>(E_FAIL); }
    result->elapsed_ms = static_cast<uint32_t>(std::min<ULONGLONG>(GetTickCount64() - begun, MAXDWORD));
    return result->error;
}
