#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Nur eine Instanz: Ein zweiter Start (z. B. Doppelklick, weil der erste Start
// etwas dauert) holt das vorhandene Fenster nach vorn, statt Mikrofon,
// Lautsprecher und Server-Verbindung doppelt zu belegen.
bool ActivateRunningInstance(HANDLE* mutex_out) {
  HANDLE mutex = CreateMutexW(nullptr, TRUE, L"Local\\CBFunk_SingleInstance");
  if (mutex != nullptr && GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = FindWindowW(L"CBFUNK_RUNNER_WIN32_WINDOW", nullptr);
    if (existing != nullptr) {
      if (IsIconic(existing)) {
        ShowWindow(existing, SW_RESTORE);
      }
      SetForegroundWindow(existing);
    }
    CloseHandle(mutex);
    return true;
  }
  *mutex_out = mutex;
  return false;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE instance_mutex = nullptr;
  if (ActivateRunningInstance(&instance_mutex)) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // 16:9-Fenster, hoechstens 1280x720 (logisch). Auf kleinen Bildschirmen
  // wird es passend verkleinert; die Oberflaeche skaliert mit.
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"CB-Funk", size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
