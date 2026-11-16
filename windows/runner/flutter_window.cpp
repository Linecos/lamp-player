#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Serving an accessibility (UIA) object lets external clients (IME TSF hooks,
// screenshot tools) call into our UI thread synchronously; observed to deadlock
// with Baidu IME and freeze the window. Only opt in with LAMP_A11Y=1.
bool A11yEnabled() {
  static const bool enabled = [] {
    wchar_t buf[8] = {};
    return GetEnvironmentVariableW(L"LAMP_A11Y", buf, 8) > 0;
  }();
  return enabled;
}

WNDPROC g_view_proc = nullptr;

LRESULT CALLBACK ViewProc(HWND hwnd, UINT message, WPARAM wparam,
                          LPARAM lparam) {
  if (message == WM_GETOBJECT && !A11yEnabled()) {
    return 0;
  }
  return CallWindowProc(g_view_proc, hwnd, message, wparam, lparam);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  g_view_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      flutter_controller_->view()->GetNativeWindow(), GWLP_WNDPROC,
      reinterpret_cast<LONG_PTR>(ViewProc)));
  if (g_view_proc == nullptr) {
    // Subclassing failed: a11y blocking is off and the window falls back to the
    // old "UIA client can stall the UI thread" behaviour. Leave a trace so the
    // next freeze report is not another guessing game.
    OutputDebugStringW(
        L"lamp_player: failed to subclass flutter view; "
        L"WM_GETOBJECT blocking is disabled\n");
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (message == WM_GETOBJECT && !A11yEnabled()) {
    return 0;
  }
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
