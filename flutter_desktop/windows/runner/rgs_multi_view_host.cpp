#include "rgs_multi_view_host.h"

#include <dwmapi.h>
#include <windowsx.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include <tray_manager/tray_manager_plugin.h>
#include "rgs_media_controller.h"

namespace {

constexpr char kChannelName[] =
    "studio.rahngaming.rgs_sensor_panel/multi_view";
constexpr wchar_t kWindowClassName[] = L"RGS_SENSOR_WIDGET_VIEW";
constexpr DWORD kDwmWindowCornerPreference = 33;
constexpr int kDwmCornerRound = 2;

// Flutter 3.44 exports this engine API but does not publish it in
// flutter_windows.h yet. Keep the declaration isolated here so an SDK upgrade
// fails at link time instead of silently falling back to multiple engines.
struct FlutterDesktopViewControllerProperties {
  int width;
  int height;
};

extern "C" FlutterDesktopViewControllerRef
FlutterDesktopEngineCreateViewController(
    FlutterDesktopEngineRef engine,
    const FlutterDesktopViewControllerProperties* properties);

const flutter::EncodableValue* Value(const flutter::EncodableMap& map,
                                     const char* key) {
  const auto iterator = map.find(flutter::EncodableValue(key));
  return iterator == map.end() ? nullptr : &iterator->second;
}

double Number(const flutter::EncodableMap& map, const char* key,
              double fallback = 0) {
  const auto* value = Value(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* number = std::get_if<double>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    return static_cast<double>(*number);
  }
  return fallback;
}

int64_t Integer(const flutter::EncodableMap& map, const char* key,
                int64_t fallback = -1) {
  const auto* value = Value(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return *number;
  }
  return fallback;
}

bool Boolean(const flutter::EncodableMap& map, const char* key,
             bool fallback = false) {
  const auto* value = Value(map, key);
  const auto* boolean = value == nullptr ? nullptr : std::get_if<bool>(value);
  return boolean == nullptr ? fallback : *boolean;
}

std::string String(const flutter::EncodableMap& map, const char* key) {
  const auto* value = Value(map, key);
  const auto* text = value == nullptr ? nullptr : std::get_if<std::string>(value);
  return text == nullptr ? "" : *text;
}

std::wstring WideString(const flutter::EncodableMap& map, const char* key) {
  const auto* value = Value(map, key);
  const auto* text = value == nullptr ? nullptr : std::get_if<std::string>(value);
  if (text == nullptr || text->empty()) {
    return L"";
  }
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         text->data(),
                                         static_cast<int>(text->size()),
                                         nullptr, 0);
  if (length <= 0) {
    return L"";
  }
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->data(),
                      static_cast<int>(text->size()), result.data(), length);
  return result;
}

double ScaleForWindow(HWND hwnd) {
  const UINT dpi = GetDpiForWindow(hwnd);
  return dpi > 0 ? static_cast<double>(dpi) / USER_DEFAULT_SCREEN_DPI : 1.0;
}

double ScaleForPoint(double physical_left, double physical_top,
                     bool has_position) {
  const POINT point = has_position
                          ? POINT{static_cast<LONG>(physical_left),
                                  static_cast<LONG>(physical_top)}
                          : POINT{0, 0};
  const HMONITOR monitor =
      MonitorFromPoint(point, MONITOR_DEFAULTTOPRIMARY);
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  return dpi > 0 ? static_cast<double>(dpi) / USER_DEFAULT_SCREEN_DPI : 1.0;
}

flutter::EncodableMap BoundsMap(HWND hwnd) {
  RECT rect{};
  GetWindowRect(hwnd, &rect);
  const double scale = ScaleForWindow(hwnd);
  return {
      {flutter::EncodableValue("left"),
       flutter::EncodableValue(rect.left / scale)},
      {flutter::EncodableValue("top"),
       flutter::EncodableValue(rect.top / scale)},
      {flutter::EncodableValue("width"),
       flutter::EncodableValue((rect.right - rect.left) / scale)},
      {flutter::EncodableValue("height"),
       flutter::EncodableValue((rect.bottom - rect.top) / scale)},
      {flutter::EncodableValue("physicalLeft"),
       flutter::EncodableValue(static_cast<double>(rect.left))},
      {flutter::EncodableValue("physicalTop"),
       flutter::EncodableValue(static_cast<double>(rect.top))},
      {flutter::EncodableValue("scaleFactor"),
       flutter::EncodableValue(scale)},
  };
}

FlutterDesktopEngineProperties BuildEngineProperties(
    const flutter::DartProject& project) {
  static std::wstring assets_path = L"data\\flutter_assets";
  static std::wstring icu_path = L"data\\icudtl.dat";
  static std::wstring aot_path = L"data\\app.so";
  static std::vector<std::string> argument_storage;
  static std::vector<const char*> arguments;

  argument_storage = project.dart_entrypoint_arguments();
  arguments.clear();
  for (const auto& argument : argument_storage) {
    arguments.push_back(argument.c_str());
  }

  FlutterDesktopEngineProperties properties{};
  properties.assets_path = assets_path.c_str();
  properties.icu_data_path = icu_path.c_str();
  properties.aot_library_path = aot_path.c_str();
  properties.dart_entrypoint = project.dart_entrypoint().empty()
                                   ? nullptr
                                   : project.dart_entrypoint().c_str();
  properties.dart_entrypoint_argc = static_cast<int>(arguments.size());
  properties.dart_entrypoint_argv = arguments.empty() ? nullptr : arguments.data();
  properties.gpu_preference = static_cast<FlutterDesktopGpuPreference>(
      project.gpu_preference());
  properties.ui_thread_policy = static_cast<FlutterDesktopUIThreadPolicy>(
      project.ui_thread_policy());
  properties.accessibility_mode =
      static_cast<FlutterDesktopAccessibilityMode>(project.accessibility_mode());
  return properties;
}

void RegisterEnginePlugins(FlutterDesktopEngineRef engine) {
  TrayManagerPluginRegisterWithRegistrar(
      FlutterDesktopEngineGetPluginRegistrar(engine, "TrayManagerPlugin"));
}

}  // namespace

struct RgsMultiViewHost::WindowEntry {
  int64_t view_id = -1;
  HWND host = nullptr;
  FlutterDesktopViewControllerRef controller = nullptr;
  bool primary = false;
  bool moving = false;
  bool resizing = false;
  bool native_corner_rounding = false;
};

class RgsMultiViewHost::Plugin : public flutter::Plugin {
 public:
  Plugin(flutter::PluginRegistrarWindows* registrar, RgsMultiViewHost* host)
      : host_(host),
        channel_(std::make_unique<
                 flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), kChannelName,
            &flutter::StandardMethodCodec::GetInstance())) {
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) {
          const auto* args = std::get_if<flutter::EncodableMap>(
              call.arguments());
          const flutter::EncodableMap empty;
          const auto& values = args == nullptr ? empty : *args;
          const std::string& method = call.method_name();

          if (method == "mainViewId") {
            result->Success(flutter::EncodableValue(host_->main_view_id()));
            return;
          }
          if (method == "configureMain") {
            HWND window = host_->main_window_;
            const bool start_hidden = Boolean(values, "startHidden");
            SetWindowText(window, L"RGS Sensor Control");
            const double scale = ScaleForWindow(window);
            const int width = static_cast<int>(std::round(420 * scale));
            const int height = static_cast<int>(std::round(640 * scale));
            RECT work{};
            MONITORINFO monitor_info{};
            monitor_info.cbSize = sizeof(monitor_info);
            GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTOPRIMARY),
                           &monitor_info);
            work = monitor_info.rcWork;
            SetWindowPos(window, nullptr,
                         work.left + (work.right - work.left - width) / 2,
                         work.top + (work.bottom - work.top - height) / 2,
                         width, height, SWP_NOZORDER | SWP_NOACTIVATE);
            LONG_PTR style = GetWindowLongPtr(window, GWL_EXSTYLE);
            if (start_hidden) {
              SetWindowLongPtr(window, GWL_EXSTYLE,
                               (style | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
              ShowWindow(window, SW_HIDE);
            } else {
              SetWindowLongPtr(window, GWL_EXSTYLE,
                               (style | WS_EX_APPWINDOW) & ~WS_EX_TOOLWINDOW);
              ShowWindow(window, SW_SHOW);
              SetForegroundWindow(window);
            }
            result->Success();
            return;
          }
          if (method == "quit") {
            PostQuitMessage(0);
            result->Success();
            return;
          }

          if (method == "create") {
            const double left = Number(values, "physicalLeft");
            const double top = Number(values, "physicalTop");
            const int64_t id = host_->CreateWidgetWindow(
                Number(values, "width", 320), Number(values, "height", 210),
                WideString(values, "title"), left, top,
                Boolean(values, "hasPosition"));
            if (id < 0) {
              result->Error("CREATE_FAILED", "Could not create Flutter view");
            } else {
              result->Success(flutter::EncodableValue(id));
            }
            return;
          }

          const int64_t id = Integer(values, "viewId");
          WindowEntry* entry = host_->Find(id);
          if (entry == nullptr) {
            result->Error("UNKNOWN_VIEW", "The Flutter view no longer exists");
            return;
          }

          if (method == "destroy") {
            host_->DestroyWindow(id);
          } else if (method == "show") {
            ShowWindow(entry->host, SW_SHOWNOACTIVATE);
          } else if (method == "hide") {
            ShowWindow(entry->host, SW_HIDE);
          } else if (method == "focus") {
            ShowWindow(entry->host, SW_SHOW);
            SetForegroundWindow(entry->host);
          } else if (method == "startDragging") {
            entry->moving = true;
            ReleaseCapture();
            SendMessage(entry->host, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
          } else if (method == "startResizing") {
            const std::string edge = String(values, "edge");
            const int hit_test = edge == "topLeft"       ? HTTOPLEFT
                                 : edge == "top"          ? HTTOP
                                 : edge == "topRight"     ? HTTOPRIGHT
                                 : edge == "right"        ? HTRIGHT
                                 : edge == "bottomRight"  ? HTBOTTOMRIGHT
                                 : edge == "bottom"       ? HTBOTTOM
                                 : edge == "bottomLeft"   ? HTBOTTOMLEFT
                                 : edge == "left"         ? HTLEFT
                                                          : 0;
            if (hit_test != 0) {
              entry->resizing = true;
              ReleaseCapture();
              POINT cursor{};
              GetCursorPos(&cursor);
              PostMessage(entry->host, WM_NCLBUTTONDOWN, hit_test,
                          MAKELPARAM(cursor.x, cursor.y));
            }
          } else if (method == "setAlwaysOnTop") {
            SetWindowPos(entry->host,
                         Boolean(values, "value") ? HWND_TOPMOST : HWND_NOTOPMOST,
                         0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
          } else if (method == "setOpacity") {
            const double opacity =
                std::clamp(Number(values, "value", 1), 0.1, 1.0);
            LONG_PTR style = GetWindowLongPtr(entry->host, GWL_EXSTYLE);
            SetWindowLongPtr(entry->host, GWL_EXSTYLE, style | WS_EX_LAYERED);
            SetLayeredWindowAttributes(
                entry->host, 0,
                static_cast<BYTE>(std::round(opacity * 255)), LWA_ALPHA);
          } else if (method == "setSkipTaskbar") {
            LONG_PTR style = GetWindowLongPtr(entry->host, GWL_EXSTYLE);
            if (Boolean(values, "value")) {
              style = (style | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW;
            } else {
              style = (style | WS_EX_APPWINDOW) & ~WS_EX_TOOLWINDOW;
            }
            SetWindowLongPtr(entry->host, GWL_EXSTYLE, style);
          } else if (method == "setSize") {
            const double scale = ScaleForWindow(entry->host);
            SetWindowPos(entry->host, nullptr, 0, 0,
                         static_cast<int>(Number(values, "width") * scale),
                         static_cast<int>(Number(values, "height") * scale),
                         SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
          } else if (method == "setPosition") {
            SetWindowPos(entry->host, nullptr,
                         static_cast<int>(Number(values, "physicalLeft")),
                         static_cast<int>(Number(values, "physicalTop")),
                         0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
          } else if (method == "getBounds") {
            result->Success(flutter::EncodableValue(BoundsMap(entry->host)));
            return;
          } else {
            result->NotImplemented();
            return;
          }
          result->Success();
        });
  }

  ~Plugin() override { channel_->SetMethodCallHandler(nullptr); }

  void Emit(const char* name, WindowEntry* entry) {
    flutter::EncodableMap event = BoundsMap(entry->host);
    event[flutter::EncodableValue("name")] = flutter::EncodableValue(name);
    event[flutter::EncodableValue("viewId")] =
        flutter::EncodableValue(entry->view_id);
    channel_->InvokeMethod(
        "event", std::make_unique<flutter::EncodableValue>(event));
  }

 private:
  RgsMultiViewHost* host_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

RgsMultiViewHost& RgsMultiViewHost::Instance() {
  static RgsMultiViewHost instance;
  return instance;
}

RgsMultiViewHost::RgsMultiViewHost() = default;
RgsMultiViewHost::~RgsMultiViewHost() = default;

bool RgsMultiViewHost::Initialize(const flutter::DartProject& project,
                                  HWND main_window, int width, int height) {
  const FlutterDesktopEngineProperties engine_properties =
      BuildEngineProperties(project);
  engine_ = FlutterDesktopEngineCreate(&engine_properties);
  if (engine_ == nullptr || !FlutterDesktopEngineRun(engine_, nullptr)) {
    return false;
  }

  FlutterDesktopViewControllerProperties view_properties{width, height};
  FlutterDesktopViewControllerRef controller =
      FlutterDesktopEngineCreateViewController(engine_, &view_properties);
  if (controller == nullptr) {
    return false;
  }

  auto entry = std::make_unique<WindowEntry>();
  entry->view_id = FlutterDesktopViewControllerGetViewId(controller);
  entry->host = main_window;
  entry->controller = controller;
  entry->primary = true;
  main_window_ = main_window;
  main_view_id_ = entry->view_id;
  windows_[entry->view_id] = std::move(entry);

  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            FlutterDesktopEngineGetPluginRegistrar(
                                engine_, "RgsMultiViewHost"));
  plugin_ = std::make_unique<Plugin>(registrar, this);
  RegisterEnginePlugins(engine_);
  RgsMediaControllerRegisterWithRegistrar(
      FlutterDesktopEngineGetPluginRegistrar(engine_, "RgsMediaController"),
      main_window_);
  return true;
}

HWND RgsMultiViewHost::MainFlutterWindow() const {
  const auto iterator = windows_.find(main_view_id_);
  if (iterator == windows_.end()) {
    return nullptr;
  }
  FlutterDesktopViewRef view =
      FlutterDesktopViewControllerGetView(iterator->second->controller);
  return view == nullptr ? nullptr : FlutterDesktopViewGetHWND(view);
}

ATOM RgsMultiViewHost::RegisterWindowClass() {
  static ATOM atom = 0;
  if (atom != 0) {
    return atom;
  }
  WNDCLASSEX window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.lpfnWndProc = SecondaryWindowProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.hbrBackground =
      reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  window_class.lpszClassName = kWindowClassName;
  atom = RegisterClassEx(&window_class);
  return atom;
}

int64_t RgsMultiViewHost::CreateWidgetWindow(double width, double height,
                                             const std::wstring& title,
                                             double physical_left,
                                             double physical_top,
                                             bool has_position) {
  if (engine_ == nullptr || RegisterWindowClass() == 0) {
    return -1;
  }
  const double initial_scale =
      ScaleForPoint(physical_left, physical_top, has_position);
  const int physical_width = static_cast<int>(std::round(width * initial_scale));
  const int physical_height = static_cast<int>(std::round(height * initial_scale));
  auto entry = std::make_unique<WindowEntry>();
  HWND host = CreateWindowEx(
      WS_EX_TOOLWINDOW, kWindowClassName, title.c_str(),
      WS_POPUP,
      has_position ? static_cast<int>(physical_left) : CW_USEDEFAULT,
      has_position ? static_cast<int>(physical_top) : CW_USEDEFAULT,
      physical_width, physical_height, nullptr, nullptr, GetModuleHandle(nullptr),
      entry.get());
  if (host == nullptr) {
    return -1;
  }

  FlutterDesktopViewControllerProperties properties{physical_width,
                                                     physical_height};
  FlutterDesktopViewControllerRef controller =
      FlutterDesktopEngineCreateViewController(engine_, &properties);
  if (controller == nullptr) {
    ::DestroyWindow(host);
    return -1;
  }

  entry->view_id = FlutterDesktopViewControllerGetViewId(controller);
  entry->host = host;
  entry->controller = controller;
  const int corner_preference = kDwmCornerRound;
  entry->native_corner_rounding = SUCCEEDED(DwmSetWindowAttribute(
      host, kDwmWindowCornerPreference, &corner_preference,
      sizeof(corner_preference)));
  SetWindowLongPtr(host, GWLP_USERDATA,
                   reinterpret_cast<LONG_PTR>(entry.get()));

  FlutterDesktopViewRef view = FlutterDesktopViewControllerGetView(controller);
  HWND flutter_window = FlutterDesktopViewGetHWND(view);
  SetParent(flutter_window, host);
  windows_[entry->view_id] = std::move(entry);
  auto* registered_entry =
      windows_[FlutterDesktopViewControllerGetViewId(controller)].get();
  ResizeFlutterChild(registered_entry);
  ShowWindow(flutter_window, SW_SHOW);
  return FlutterDesktopViewControllerGetViewId(controller);
}

void RgsMultiViewHost::DestroyWindow(int64_t view_id) {
  const auto iterator = windows_.find(view_id);
  if (iterator == windows_.end() || iterator->second->primary) {
    return;
  }
  WindowEntry* entry = iterator->second.get();
  HWND host = entry->host;

  // DestroyWindow dispatches messages synchronously. Stop the window proc from
  // following GWLP_USERDATA after the owning WindowEntry has been released.
  SetWindowLongPtr(host, GWLP_USERDATA, 0);
  FlutterDesktopViewControllerDestroy(entry->controller);
  entry->controller = nullptr;
  if (IsWindow(host)) {
    ::DestroyWindow(host);
  }
  windows_.erase(iterator);
}

RgsMultiViewHost::WindowEntry* RgsMultiViewHost::Find(int64_t view_id) {
  const auto iterator = windows_.find(view_id);
  return iterator == windows_.end() ? nullptr : iterator->second.get();
}

RgsMultiViewHost::WindowEntry* RgsMultiViewHost::Find(HWND hwnd) {
  for (auto& pair : windows_) {
    if (pair.second->host == hwnd) {
      return pair.second.get();
    }
  }
  return nullptr;
}

void RgsMultiViewHost::ResizeFlutterChild(WindowEntry* entry) {
  if (entry == nullptr || entry->controller == nullptr) {
    return;
  }
  FlutterDesktopViewRef view =
      FlutterDesktopViewControllerGetView(entry->controller);
  HWND child = FlutterDesktopViewGetHWND(view);
  RECT rect{};
  GetClientRect(entry->host, &rect);
  if (!entry->primary && !entry->native_corner_rounding) {
    const int diameter =
        std::max(12, static_cast<int>(std::round(16 * ScaleForWindow(
                                                   entry->host))));
    HRGN region = CreateRoundRectRgn(0, 0, rect.right + 1, rect.bottom + 1,
                                     diameter, diameter);
    if (region != nullptr && !SetWindowRgn(entry->host, region, TRUE)) {
      DeleteObject(region);
    }
  }
  MoveWindow(child, 0, 0, rect.right, rect.bottom, TRUE);
  FlutterDesktopViewControllerForceRedraw(entry->controller);
}

void RgsMultiViewHost::EmitEvent(const char* name, WindowEntry* entry) {
  if (plugin_ != nullptr) {
    plugin_->Emit(name, entry);
  }
}

LRESULT CALLBACK RgsMultiViewHost::SecondaryWindowProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  auto& host = Instance();
  WindowEntry* entry = reinterpret_cast<WindowEntry*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    entry = static_cast<WindowEntry*>(create->lpCreateParams);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(entry));
  }

  if (message == WM_NCHITTEST) {
    RECT rect{};
    GetWindowRect(hwnd, &rect);
    const int border =
        std::max(5, static_cast<int>(std::round(6 * ScaleForWindow(hwnd))));
    const int x = GET_X_LPARAM(lparam);
    const int y = GET_Y_LPARAM(lparam);
    const bool left = x < rect.left + border;
    const bool right = x >= rect.right - border;
    const bool top = y < rect.top + border;
    const bool bottom = y >= rect.bottom - border;
    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
    return HTCLIENT;
  }

  LRESULT result = 0;
  if (entry != nullptr && entry->controller != nullptr &&
      FlutterDesktopViewControllerHandleTopLevelWindowProc(
          entry->controller, hwnd, message, wparam, lparam, &result)) {
    return result;
  }

  switch (message) {
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const double scale = ScaleForWindow(hwnd);
      info->ptMinTrackSize.x = static_cast<LONG>(220 * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(140 * scale);
      return 0;
    }
    case WM_SIZE:
      host.ResizeFlutterChild(entry);
      return 0;
    case WM_EXITSIZEMOVE:
      if (entry != nullptr) {
        if (entry->moving) host.EmitEvent("moved", entry);
        if (entry->resizing) host.EmitEvent("resized", entry);
        entry->moving = false;
        entry->resizing = false;
      }
      return 0;
    case WM_CLOSE:
      if (entry != nullptr) host.EmitEvent("close", entry);
      return 0;
    case WM_DPICHANGED: {
      const auto* suggested = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(hwnd, nullptr, suggested->left, suggested->top,
                   suggested->right - suggested->left,
                   suggested->bottom - suggested->top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      if (entry != nullptr) host.EmitEvent("dpiChanged", entry);
      return 0;
    }
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

bool RgsMultiViewHost::HandleWindowMessage(HWND hwnd, UINT message,
                                           WPARAM wparam, LPARAM lparam,
                                           LRESULT* result) {
  WindowEntry* entry = Find(hwnd);
  if (entry == nullptr || entry->controller == nullptr) {
    return false;
  }
  if (entry->primary && message == WM_CLOSE) {
    EmitEvent("close", entry);
    *result = 0;
    return true;
  }
  if (entry->primary && message == WM_SIZE && wparam == SIZE_MINIMIZED) {
    EmitEvent("minimize", entry);
  }
  return FlutterDesktopViewControllerHandleTopLevelWindowProc(
      entry->controller, hwnd, message, wparam, lparam, result);
}

void RgsMultiViewHost::Shutdown() {
  std::vector<int64_t> secondary;
  for (const auto& pair : windows_) {
    if (!pair.second->primary) secondary.push_back(pair.first);
  }
  for (const int64_t id : secondary) DestroyWindow(id);
  plugin_.reset();
  if (main_view_id_ >= 0) {
    auto iterator = windows_.find(main_view_id_);
    if (iterator != windows_.end() && iterator->second->controller != nullptr) {
      FlutterDesktopViewControllerDestroy(iterator->second->controller);
    }
    windows_.erase(main_view_id_);
  }
  engine_ = nullptr;
  main_view_id_ = -1;
  main_window_ = nullptr;
}
