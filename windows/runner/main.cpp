#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdlib>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Whether to use Impeller (off by default: we ship Skia).
//
// Impeller has no picture raster cache: every frame that has new content
// re-rasterizes the whole tree. The now-playing page is a full-screen flow
// background + lyrics + spectrum + big cover, so each frame of the route
// transition allocates a fresh batch of offscreen layers; they pile up to
// GBs before the OS reclaims them (RSS peaked at 4.9GB, also reproducible
// in debug builds). Skia caches those pictures, so the same transition is
// almost free.
//
// To compare the two renderers, set the environment variable before launch:
//   set LAMP_IMPELLER=1   -> Impeller
//   set LAMP_IMPELLER=0   -> Skia (default)
bool UseImpeller() {
  char* value = nullptr;
  size_t length = 0;
  if (_dupenv_s(&value, &length, "LAMP_IMPELLER") != 0 || value == nullptr) {
    return false;
  }
  const std::string text(value);
  free(value);
  return text == "1" || text == "true";
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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

  project.set_impeller_switch(UseImpeller() ? flutter::ImpellerSwitch::Enabled
                                            : flutter::ImpellerSwitch::Disabled);

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Lamp Player", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
