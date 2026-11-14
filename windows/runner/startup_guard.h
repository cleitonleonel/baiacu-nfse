#ifndef RUNNER_STARTUP_GUARD_H_
#define RUNNER_STARTUP_GUARD_H_

#include <windows.h>
#include <cwctype>
#include <string>

// Evita abrir outra instancia do mesmo executavel enquanto o Flutter prepara o acesso.
class StartupGuard {
 public:
  StartupGuard() {
    wchar_t path[32768] = {};
    GetModuleFileNameW(nullptr, path, 32768);
    unsigned long long hash = 14695981039346656037ull;
    for (const wchar_t* c = path; *c; ++c) {
      hash ^= static_cast<unsigned long long>(towlower(*c));
      hash *= 1099511628211ull;
    }
    const auto name = L"Local\\BaiacuNFSe.Startup." + std::to_wstring(hash);
    mutex_ = CreateMutexW(nullptr, TRUE, name.c_str());
    duplicate_ = mutex_ && GetLastError() == ERROR_ALREADY_EXISTS;
    if (duplicate_) {
      if (HWND previous = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Baiacu NFS-e")) {
        SetForegroundWindow(previous);
      }
    }
  }
  ~StartupGuard() { Finish(); }
  StartupGuard(const StartupGuard&) = delete;
  StartupGuard& operator=(const StartupGuard&) = delete;
  bool duplicate() const { return duplicate_; }
  void Finish() {
    if (!mutex_) return;
    if (!duplicate_) ReleaseMutex(mutex_);
    CloseHandle(mutex_);
    mutex_ = nullptr;
  }

 private:
  HANDLE mutex_ = nullptr;
  bool duplicate_ = false;
};

// Um programa aberto por COMPUTADOR (todas as sessoes do Windows): instalado para todos os
// usuarios, o banco e um so, e duas copias abertas ao mesmo tempo (troca rapida de usuario,
// area de trabalho remota) disputariam a numeracao e as chaves. A trava vale enquanto o
// processo vive; o Windows a solta sozinho quando ele fecha (ate num travamento).
class MachineGuard {
 public:
  // [espera_ms]: quanto esperar a outra copia fechar (a reabertura depois de restaurar um backup
  // ou de uma atualizacao comeca antes de a copia antiga terminar de sair).
  explicit MachineGuard(DWORD espera_ms = 0) {
    const ULONGLONG limite = GetTickCount64() + espera_ms;
    for (;;) {
      Tentar();
      if (!busy_ || GetTickCount64() >= limite) return;
      Sleep(250);
    }
  }

 private:
  void Tentar() {
    busy_ = false;
    wchar_t path[32768] = {};
    GetModuleFileNameW(nullptr, path, 32768);
    unsigned long long hash = 14695981039346656037ull;
    for (const wchar_t* c = path; *c; ++c) {
      hash ^= static_cast<unsigned long long>(towlower(*c));
      hash *= 1099511628211ull;
    }
    const auto name = L"Global\\BaiacuNFSe.Aberto." + std::to_wstring(hash);
    // Sem DACL: qualquer usuario do computador enxerga a trava de outro.
    SECURITY_DESCRIPTOR sd;
    InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION);
    SetSecurityDescriptorDacl(&sd, TRUE, nullptr, FALSE);
    SECURITY_ATTRIBUTES sa{sizeof(sa), &sd, FALSE};
    mutex_ = CreateMutexW(&sa, FALSE, name.c_str());
    const DWORD erro = GetLastError();
    if (!mutex_) {
      // Criada por outro usuario sem acesso para este: ja esta aberta.
      busy_ = erro == ERROR_ACCESS_DENIED;
      return;
    }
    if (erro == ERROR_ALREADY_EXISTS) {
      busy_ = true;
      CloseHandle(mutex_);
      mutex_ = nullptr;
    }
  }

 public:
  ~MachineGuard() {
    if (mutex_) CloseHandle(mutex_);
  }
  MachineGuard(const MachineGuard&) = delete;
  MachineGuard& operator=(const MachineGuard&) = delete;
  bool busy() const { return busy_; }

  // Ja aberto: na mesma sessao, traz a janela para a frente; em outra sessao (outro usuario do
  // Windows), avisa.
  static void Warn() {
    if (HWND previous = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Baiacu NFS-e")) {
      ShowWindow(previous, SW_RESTORE);
      SetForegroundWindow(previous);
      return;
    }
    MessageBoxW(nullptr,
                L"O Baiacu NFS-e já está aberto neste computador, por outro usuário do Windows.\n\n"
                L"Para proteger os dados, ele só pode ficar aberto uma vez por computador. "
                L"Peça para essa pessoa fechar o programa (ou sair da conta dela) e tente de novo.",
                L"Baiacu NFS-e", MB_OK | MB_ICONINFORMATION);
  }

 private:
  HANDLE mutex_ = nullptr;
  bool busy_ = false;
};
#endif
