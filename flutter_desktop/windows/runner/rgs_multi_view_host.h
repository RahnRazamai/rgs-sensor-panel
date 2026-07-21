#ifndef RUNNER_RGS_MULTI_VIEW_HOST_H_
#define RUNNER_RGS_MULTI_VIEW_HOST_H_

#include <flutter/dart_project.h>
#include <flutter_windows.h>
#include <windows.h>

#include <cstdint>
#include <map>
#include <memory>
#include <optional>

// Project-owned, Windows-only bridge for Flutter's experimental multi-view
// embedder API. All widget windows share the primary Flutter engine.
class RgsMultiViewHost {
 public:
  static RgsMultiViewHost& Instance();

  bool Initialize(const flutter::DartProject& project, HWND main_window,
                  int width, int height);
  FlutterDesktopEngineRef engine() const { return engine_; }
  HWND MainFlutterWindow() const;
  int64_t main_view_id() const { return main_view_id_; }

  bool HandleWindowMessage(HWND hwnd, UINT message, WPARAM wparam,
                           LPARAM lparam, LRESULT* result);
  void Shutdown();

  RgsMultiViewHost(const RgsMultiViewHost&) = delete;
  RgsMultiViewHost& operator=(const RgsMultiViewHost&) = delete;

 private:
  RgsMultiViewHost();
  ~RgsMultiViewHost();

  struct WindowEntry;
  class Plugin;
  friend class Plugin;

  static LRESULT CALLBACK SecondaryWindowProc(HWND hwnd, UINT message,
                                               WPARAM wparam, LPARAM lparam);
  static ATOM RegisterWindowClass();

  WindowEntry* Find(int64_t view_id);
  WindowEntry* Find(HWND hwnd);
  int64_t CreateWidgetWindow(double width, double height,
                             const std::wstring& title,
                             double physical_left, double physical_top,
                             bool has_position);
  void DestroyWindow(int64_t view_id);
  void ResizeFlutterChild(WindowEntry* entry);
  void EmitEvent(const char* name, WindowEntry* entry);

  FlutterDesktopEngineRef engine_ = nullptr;
  HWND main_window_ = nullptr;
  int64_t main_view_id_ = -1;
  std::unique_ptr<Plugin> plugin_;
  std::map<int64_t, std::unique_ptr<WindowEntry>> windows_;
};

#endif  // RUNNER_RGS_MULTI_VIEW_HOST_H_
