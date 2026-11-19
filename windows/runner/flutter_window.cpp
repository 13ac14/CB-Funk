#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Falls Dart vor dem ersten Bild haengt oder abstuerzt, das Fenster trotzdem
// zeigen, damit nicht ein unsichtbarer Prozess im Hintergrund weiterlaeuft.
constexpr UINT_PTR kShowFallbackTimer = 1;
constexpr UINT kShowFallbackMs = 5000;

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
  RegisterWindowChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Fenster erst zeigen, wenn Flutter das erste Bild fertig hat (Vorlage).
  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    KillTimer(GetHandle(), kShowFallbackTimer);
    this->Show();
  });
  SetTimer(GetHandle(), kShowFallbackTimer, kShowFallbackMs, nullptr);

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::RegisterWindowChannel() {
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "de.cbfunk/window",
          &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND hwnd = GetHandle();
        if (hwnd == nullptr) {
          result->Error("no_window", "Fenster existiert nicht mehr");
          return;
        }
        const std::string& method = call.method_name();
        if (method == "startDrag") {
          // Windows-eigenes Verschieben (wie beim Ziehen an der Titelleiste).
          // Per PostMessage, damit die Verschiebe-Schleife nicht innerhalb
          // dieses Aufrufs laeuft.
          ReleaseCapture();
          PostMessage(hwnd, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
          result->Success();
        } else if (method == "minimize") {
          ShowWindow(hwnd, SW_MINIMIZE);
          result->Success();
        } else if (method == "close") {
          PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_TIMER && wparam == kShowFallbackTimer) {
    KillTimer(hwnd, kShowFallbackTimer);
    if (!IsWindowVisible(hwnd)) {
      Show();
    }
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
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
