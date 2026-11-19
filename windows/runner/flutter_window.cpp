#include "flutter_window.h"

#include <optional>

namespace {

// Do not synchronously call Flutter's top-level handler while Windows is
// moving, resizing, activating, or changing DPI for this fixed-size window.
bool IsWindowManagerMessage(UINT message) {
  switch (message) {
    case WM_SIZE:
    case WM_ACTIVATE:
    case WM_DPICHANGED:
    case WM_WINDOWPOSCHANGING:
    case WM_WINDOWPOSCHANGED:
    case WM_MOVING:
    case WM_SIZING:
    case WM_ENTERSIZEMOVE:
    case WM_EXITSIZEMOVE:
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONUP:
    case WM_NCCALCSIZE:
    case WM_NCPAINT:
    case WM_NCACTIVATE:
    case WM_ERASEBKGND:
    case WM_STYLECHANGED:
    case kRefreshPopupFrameMessage:
      return true;
    default:
      return false;
  }
}

}  // namespace

#include "flutter/generated_plugin_registrant.h"

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
  if (message == WM_SIZE && wparam != SIZE_MINIMIZED &&
      !resize_message_pending_) {
    resize_message_pending_ = true;
    if (!PostMessage(hwnd, kResizeChildMessage, 0, 0)) {
      resize_message_pending_ = false;
    }
  } else if (message == kResizeChildMessage) {
    resize_message_pending_ = false;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  // The deferred resize is handled by Win32Window after this dispatch.
  if (flutter_controller_ && message != kResizeChildMessage &&
      message != kApplyDpiRectMessage && message != kFocusChildMessage &&
      message != kRestoreWindowMessage &&
      !IsWindowManagerMessage(message)) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
