#include "flutter_window.h"

#include "rgs_multi_view_host.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  auto& host = RgsMultiViewHost::Instance();
  if (!host.Initialize(project_, GetHandle(), frame.right - frame.left,
                       frame.bottom - frame.top)) {
    return false;
  }
  SetChildContent(host.MainFlutterWindow());

  // Visibility is applied through RgsMultiViewHost after Flutter's first
  // frame. In particular, --rgs-startup must remain hidden.

  return true;
}

void FlutterWindow::OnDestroy() {
  RgsMultiViewHost::Instance().Shutdown();
  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  auto& host = RgsMultiViewHost::Instance();
  LRESULT result = 0;
  if (host.HandleWindowMessage(hwnd, message, wparam, lparam, &result)) {
    return result;
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (host.engine() != nullptr) {
        FlutterDesktopEngineReloadSystemFonts(host.engine());
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
