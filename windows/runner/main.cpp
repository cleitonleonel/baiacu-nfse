#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"
#include "startup_guard.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  wchar_t oculta_env[8] = {};
  const bool oculta = GetEnvironmentVariableW(L"NFSE_OCULTA", oculta_env, 8) > 0 && oculta_env[0] == L'1';
  StartupGuard starting;
  if (starting.duplicate()) return EXIT_SUCCESS;
  wchar_t reabrir_env[8] = {};
  const bool reabrir = GetEnvironmentVariableW(L"NFSE_REABRIR", reabrir_env, 8) > 0 && reabrir_env[0] == L'1';
  SetEnvironmentVariableW(L"NFSE_REABRIR", nullptr);
  MachineGuard machine(reabrir ? 20000 : 0);
  if (machine.busy()) {
    if (!oculta) MachineGuard::Warn();
    return EXIT_SUCCESS;
  }
  // As DLLs do programa (Flutter, plugins, nucleo e Visual C++) moram em data\dll, nao ao lado do
  // executavel. O Windows tem de saber disso antes de a primeira delas ser pedida.
  {
    std::wstring pasta(32768, L'\0');
    pasta.resize(::GetModuleFileNameW(nullptr, pasta.data(),
                                      static_cast<DWORD>(pasta.size())));
    pasta.resize(pasta.find_last_of(L'\\'));
    ::SetDllDirectoryW((pasta + L"\\data\\dll").c_str());
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Os arquivos de execucao do Flutter ficam em "data" (app.so, icudtl.dat, flutter_assets).
  // Os bancos do usuario ficam em "database" (dados.db, dados.key, notas.db).
  flutter::DartProject project(L"data");
  // Skia evita a inicializacao lenta do Impeller neste aplicativo Windows.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // NFSE_OCULTA=1 (conferencia de partida do compilar_exe.py): a janela nasce fora da tela e nunca e mostrada.
  FlutterWindow window(project, oculta, &starting);
  Win32Window::Point origin(oculta ? -8000 : 10, oculta ? 40 : 10);
  Win32Window::Size size(oculta ? 1536 : 1280, oculta ? 830 : 720);
  if (!window.Create(L"Baiacu NFS-e", origin, size)) {
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
