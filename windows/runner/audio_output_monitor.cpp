#include "audio_output_monitor.h"
#include <initguid.h>
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>
#include <propvarutil.h>
#include <wrl/client.h>
#include <cstdio>
#include <utility>

namespace {
using Microsoft::WRL::ComPtr;

std::string Utf8(const wchar_t* text) {
  if (!text || !*text) return {};
  const int length = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (length <= 1) return {};
  std::string value(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, value.data(), length, nullptr, nullptr);
  value.pop_back();
  return value;
}
std::string ErrorCode(HRESULT result) {
  char value[16]{};
  std::snprintf(value, sizeof(value), "0x%08lX", static_cast<unsigned long>(result));
  return value;
}

class Notifications final : public IMMNotificationClient {
 public:
  explicit Notifications(HANDLE wake) : wake_(wake) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** value) override {
    if (!value) return E_POINTER;
    *value = nullptr;
    if (iid != __uuidof(IUnknown) && iid != __uuidof(IMMNotificationClient)) return E_NOINTERFACE;
    *value = static_cast<IMMNotificationClient*>(this);
    AddRef(); return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const auto references = --references_;
    if (!references) delete this;
    return references;
  }
  // COM callbacks only signal the worker; they never query devices, wait, or
  // invoke Flutter. The auto-reset event coalesces bursts of notifications.
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
    if (flow == eRender && role == eConsole) SetEvent(wake_);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return Wake(); }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { return Wake(); }
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { return Wake(); }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return Wake(); }
 private:
  HRESULT Wake() { SetEvent(wake_); return S_OK; }
  std::atomic<ULONG> references_{1};
  HANDLE wake_;
};

AudioOutputMonitor::State ReadDefault(IMMDeviceEnumerator* enumerator) {
  AudioOutputMonitor::State state;
  ComPtr<IMMDevice> device;
  // Match the system default playback endpoint, not the communications role or
  // an individual application's per-app audio routing override.
  const HRESULT result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (result == HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) {
    state.status = "none";
    return state;
  }
  if (FAILED(result)) {
    state.status = "error"; state.error = ErrorCode(result);
    return state;
  }
  LPWSTR id = nullptr;
  const auto identified = device->GetId(&id);
  if (SUCCEEDED(identified)) state.id = Utf8(id);
  CoTaskMemFree(id);
  ComPtr<IPropertyStore> properties;
  if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &properties))) {
    PROPVARIANT name;
    PropVariantInit(&name);
    if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &name)) && name.vt == VT_LPWSTR) {
      state.name = Utf8(name.pwszVal);
    }
    PropVariantClear(&name);
    PROPVARIANT form;
    PropVariantInit(&form);
    if (SUCCEEDED(properties->GetValue(PKEY_AudioEndpoint_FormFactor, &form)) && form.vt == VT_UI4) {
      switch (form.uintVal) {
        case Headphones: state.kind = "headphones"; state.headphones = true; break;
        case Headset: state.kind = "headset"; state.headphones = true; break;
        case Speakers: state.kind = "speakers"; break;
        case DigitalAudioDisplayDevice: state.kind = "display"; break;
        case LineLevel: state.kind = "line"; break;
        case SPDIF: state.kind = "digital"; break;
        default: break;
      }
    }
    PropVariantClear(&form);
  }
  if (state.name.empty()) state.name = "音频输出设备（名称不可用）";
  state.status = "ready";
  return state;
}
}  // namespace

AudioOutputMonitor::AudioOutputMonitor(HWND owner) : owner_(owner) {
  wake_ = CreateEventW(nullptr, FALSE, TRUE, nullptr);
  if (!wake_) {
    state_.status = "error";
    state_.error = ErrorCode(HRESULT_FROM_WIN32(GetLastError()));
    return;
  }
  worker_ = std::thread([this] { Run(); });
}
AudioOutputMonitor::~AudioOutputMonitor() {
  closing_ = true;
  if (wake_) SetEvent(wake_);
  if (worker_.joinable()) worker_.join();
  if (wake_) CloseHandle(wake_);
}
void AudioOutputMonitor::Refresh() { if (wake_) SetEvent(wake_); }
AudioOutputMonitor::State AudioOutputMonitor::Snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return state_;
}
void AudioOutputMonitor::Publish(State state) {
  bool changed = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    changed = state.status != state_.status || state.id != state_.id ||
        state.name != state_.name || state.error != state_.error || state.automatic != state_.automatic ||
        state.kind != state_.kind || state.headphones != state_.headphones;
    if (changed) {
      state.revision = state_.revision + 1;
      state_ = std::move(state);
    }
  }
  if (changed && !closing_) PostMessageW(owner_, kChangedMessage, 0, 0);
}
void AudioOutputMonitor::Run() {
  const auto initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) {
    State state; state.status = "error"; state.error = ErrorCode(initialized);
    Publish(std::move(state)); return;
  }
  {
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<Notifications> notifications;
    notifications.Attach(new Notifications(wake_));
    bool registered = false;
    while (WaitForSingleObject(wake_, INFINITE) == WAIT_OBJECT_0 && !closing_) {
      HRESULT result = S_OK;
      if (!enumerator) {
        result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER,
            IID_PPV_ARGS(&enumerator));
      }
      State state;
      if (FAILED(result)) {
        state.status = "error"; state.error = ErrorCode(result);
      } else {
        if (!registered) {
          registered = SUCCEEDED(enumerator->RegisterEndpointNotificationCallback(notifications.Get()));
        }
        state = ReadDefault(enumerator.Get());
        state.automatic = registered;
      }
      Publish(std::move(state));
    }
    if (registered) enumerator->UnregisterEndpointNotificationCallback(notifications.Get());
  }
  CoUninitialize();
}
