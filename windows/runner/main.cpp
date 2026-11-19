#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include <string>
#include <optional>

#include "flutter_window.h"
#include "utils.h"
#include "startup_guard.h"

namespace {
// O serviço coordena as operações no banco e dá uma sessão própria a cada cliente.
bool UsaServicoDeDados(const std::wstring& pasta) {
  if (GetFileAttributesW((pasta + L"\\installed.marker").c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!scm) return false;
  SC_HANDLE dados = OpenServiceW(scm, L"BaiacuNFSeDados", SERVICE_QUERY_STATUS);
  if (dados) CloseServiceHandle(dados);
  CloseServiceHandle(scm);
  return dados != nullptr;
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  auto arguments = GetCommandLineArguments();
  const bool probe = arguments.size() == 1 &&
                     arguments.front() == "--baiacu-validar-inicializacao";
  if (probe) {
    // Evita diálogos do Windows se uma DLL da versão candidata não carregar.
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
  }
  wchar_t oculta_env[8] = {};
  const bool oculta = probe ||
      (GetEnvironmentVariableW(L"NFSE_OCULTA", oculta_env, 8) > 0 && oculta_env[0] == L'1');
  // Não abre uma segunda sessão enquanto o serviço substitui os binários.
  wchar_t exe_path[32768] = {};
  GetModuleFileNameW(nullptr, exe_path, 32768);
  std::wstring directory(exe_path);
  directory.resize(directory.find_last_of(L'\\'));
  unsigned long long update_hash = 14695981039346656037ull;
  for (const wchar_t* c = exe_path; *c; ++c) {
    update_hash ^= static_cast<unsigned long long>((*c >= L'A' && *c <= L'Z') ? *c + 32 : *c);
    update_hash *= 1099511628211ull;
  }
  const std::wstring update_mutex = L"Global\\BaiacuNFSe.Update." + std::to_wstring(update_hash);
  HANDLE updating = OpenMutexW(SYNCHRONIZE, FALSE, update_mutex.c_str());
  const bool update_active = updating || GetLastError() == ERROR_ACCESS_DENIED;
  if (updating) CloseHandle(updating);
  const bool pending = GetFileAttributesW((directory + L"\\update.pending").c_str()) != INVALID_FILE_ATTRIBUTES;
  if (probe && (!update_active || !pending)) return EXIT_FAILURE;
  if (update_active && !probe) {
    if (!oculta) MessageBoxW(nullptr, L"Aguarde a atualização ou recuperação do Baiacu terminar.", L"Baiacu NFS-e", MB_OK | MB_ICONINFORMATION);
    return EXIT_SUCCESS;
  }
  if (!probe && GetFileAttributesW((directory + L"\\installed.marker").c_str()) != INVALID_FILE_ATTRIBUTES) {
    SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (scm) {
      SC_HANDLE service = OpenServiceW(scm, L"BaiacuNFSeUpdate", SERVICE_QUERY_STATUS);
      if (service) {
        SERVICE_STATUS status{};
        if (QueryServiceStatus(service, &status) && status.dwCurrentState != SERVICE_STOPPED) {
          CloseServiceHandle(service);
          CloseServiceHandle(scm);
          if (!oculta) MessageBoxW(nullptr, L"O Baiacu está sendo atualizado. Aguarde a conclusão; ele abrirá novamente.", L"Baiacu NFS-e", MB_OK | MB_ICONINFORMATION);
          return EXIT_SUCCESS;
        }
        CloseServiceHandle(service);
      }
      CloseServiceHandle(scm);
    }
  }
  wchar_t program_files[32768] = {};
  GetEnvironmentVariableW(L"ProgramW6432", program_files, 32768);
  if (program_files[0] == 0) GetEnvironmentVariableW(L"ProgramFiles", program_files, 32768);
  if (_wcsicmp(directory.c_str(), (std::wstring(program_files) + L"\\Baiacu NFS-e").c_str()) == 0 &&
      GetFileAttributesW((directory + L"\\installed.marker").c_str()) == INVALID_FILE_ATTRIBUTES) {
    MessageBoxW(nullptr, L"Esta instalação precisa ser migrada para o novo modelo de segurança.\n\nExecute o instalador atualizado (setup.exe). Ele preservará e migrará seus bancos para ProgramData.", L"Baiacu NFS-e", MB_OK | MB_ICONINFORMATION);
    return EXIT_SUCCESS;
  }
  if (pending && !probe) {
    const bool installed = GetFileAttributesW((directory + L"\\installed.marker").c_str()) != INVALID_FILE_ATTRIBUTES;
    if (MessageBoxW(nullptr, L"Uma atualização foi interrompida. O Baiacu precisa restaurar a versão anterior antes de abrir.\n\nDeseja recuperar agora?", L"Baiacu NFS-e", MB_OKCANCEL | MB_ICONINFORMATION) != IDOK) return EXIT_SUCCESS;
    const std::wstring helper = directory + L"\\service\\baiacu-atualizador.exe";
    SHELLEXECUTEINFOW info{};
    info.cbSize = sizeof(info);
    info.fMask = SEE_MASK_NOCLOSEPROCESS;
    info.lpVerb = installed ? L"runas" : L"open";
    info.lpFile = helper.c_str();
    info.lpParameters = L"--recover";
    info.nShow = SW_HIDE;
    // O recuperador precisa SUBSTITUIR este executável: esperar por ele aqui manteria o .exe em
    // uso e a recuperação falharia com "Acesso negado" (os error 5). Este processo sai já.
    info.fMask = 0;
    // Nem uma mensagem aqui: ela seguraria o processo. O recuperador avisa quando terminar.
    ShellExecuteExW(&info);
    return EXIT_SUCCESS;
  }
  // Sem o serviço Baiacu NFSe - Dados (instalação 1.0.0.2 atualizada pelo atualizador automático,
  // que não registra serviços), o programa abre no modelo anterior: os bancos de ProgramData são
  // abertos no próprio processo. O núcleo decide isso sozinho (dados_windows::servico_registrado).
  // Bloquear aqui fazia a conferência de partida do atualizador falhar e a atualização ser desfeita.
  const bool banco_local = !probe && !UsaServicoDeDados(directory);
  StartupGuard starting(banco_local);
  if (starting.duplicate()) return EXIT_SUCCESS;
  wchar_t reabrir_env[8] = {};
  const bool reabrir = GetEnvironmentVariableW(L"NFSE_REABRIR", reabrir_env, 8) > 0 && reabrir_env[0] == L'1';
  SetEnvironmentVariableW(L"NFSE_REABRIR", nullptr);
  std::optional<MachineGuard> machine;
  if (banco_local) {
    machine.emplace(reabrir ? 20000 : 0);
    if (machine->busy()) {
      if (!oculta) MachineGuard::Warn();
      return EXIT_SUCCESS;
    }
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
  flutter::DartProject project(directory + L"\\data");
  // Skia evita a inicializacao lenta do Impeller neste aplicativo Windows.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  project.set_dart_entrypoint_arguments(std::move(arguments));

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

  // Desmonta o motor do Flutter aqui, fora de qualquer callback de janela, e só depois o COM.
  window.Destroy();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
