#include "flutter_window.h"

#include <shellapi.h>

#include <cwchar>
#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kEventoBandeja = WM_APP + 1;
constexpr UINT kIdIcone = 1;
constexpr int kSair = 1;

NOTIFYICONDATAW DadosDoIcone(HWND janela) {
  NOTIFYICONDATAW dados{};
  dados.cbSize = sizeof(dados);
  dados.hWnd = janela;
  dados.uID = kIdIcone;
  return dados;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool oculta, StartupGuard* starting)
    : project_(project), oculta_(oculta), starting_(starting) {}

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

  mensagem_fechar_instalador_ = ::RegisterWindowMessageW(L"BaiacuNFSe.FecharParaInstalar.v1");
  mensagem_taskbar_criada_ = ::RegisterWindowMessageW(L"TaskbarCreated");
  janela_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "baiacu/janela",
      &flutter::StandardMethodCodec::GetInstance());
  janela_->SetMethodCallHandler([this](const auto& chamada, auto resposta) {
    if (chamada.method_name() != "ocultarNaBandeja") {
      resposta->NotImplemented();
      return;
    }
    const HWND janela = GetHandle();
    if (janela == nullptr || oculta_) {
      resposta->Success(flutter::EncodableValue(false));
      return;
    }
    if (!na_bandeja_ && AdicionarIcone(janela)) {
      na_bandeja_ = true;
      ::ShowWindow(janela, SW_HIDE);
    }
    resposta->Success(flutter::EncodableValue(na_bandeja_));
  });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (starting_) starting_->Finish();
    if (oculta_) {
      return;
    }
    ::ShowWindow(GetHandle(), SW_SHOWMAXIMIZED);
    ::UpdateWindow(GetHandle());
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (na_bandeja_ && GetHandle() != nullptr) {
    RemoverIcone(GetHandle());
  }
  janela_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::AdicionarIcone(HWND window) {
  auto dados = DadosDoIcone(window);
  dados.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  dados.uCallbackMessage = kEventoBandeja;
  dados.hIcon = ::LoadIconW(::GetModuleHandleW(nullptr),
                            MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(dados.szTip, L"Baiacu NFS-e");
  if (dados.hIcon == nullptr || !::Shell_NotifyIconW(NIM_ADD, &dados)) {
    return false;
  }
  dados.uVersion = NOTIFYICON_VERSION_4;
  if (::Shell_NotifyIconW(NIM_SETVERSION, &dados)) {
    return true;
  }
  ::Shell_NotifyIconW(NIM_DELETE, &dados);
  return false;
}

void FlutterWindow::RemoverIcone(HWND window) {
  if (!na_bandeja_) return;
  na_bandeja_ = false;
  auto dados = DadosDoIcone(window);
  ::Shell_NotifyIconW(NIM_DELETE, &dados);
}

void FlutterWindow::RestaurarDaBandeja(HWND window) {
  RemoverIcone(window);
  ::ShowWindow(window, ::IsIconic(window) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(window);
}

void FlutterWindow::MostrarMenuDaBandeja(HWND window) {
  const HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) return;
  if (!::AppendMenuW(menu, MF_STRING, kSair, L"Sair")) {
    ::DestroyMenu(menu);
    return;
  }
  POINT posicao{};
  ::GetCursorPos(&posicao);
  ::SetForegroundWindow(window);
  // Encosta a borda inferior do menu no cursor: abre acima do clique.
  // WORKAREA mantém o menu na área útil do monitor, fora da barra de tarefas.
  const UINT acao = ::TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON |
                TPM_RIGHTALIGN | TPM_BOTTOMALIGN | TPM_WORKAREA,
      posicao.x, posicao.y, window, nullptr);
  ::DestroyMenu(menu);
  ::PostMessageW(window, WM_NULL, 0, 0);
  if (!na_bandeja_) return;
  if (acao == kSair && janela_) {
    RestaurarDaBandeja(window);
    janela_->InvokeMethod("sairDaBandeja", nullptr);
  } else {
    auto dados = DadosDoIcone(window);
    ::Shell_NotifyIconW(NIM_SETFOCUS, &dados);
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (mensagem_fechar_instalador_ != 0 && message == mensagem_fechar_instalador_) {
    if (janela_) janela_->InvokeMethod("fecharParaInstalar", nullptr);
    return 0;
  }
  if (mensagem_taskbar_criada_ != 0 && message == mensagem_taskbar_criada_) {
    if (na_bandeja_ && !AdicionarIcone(hwnd)) RestaurarDaBandeja(hwnd);
    return 0;
  }
  if (message == kEventoBandeja && HIWORD(lparam) == kIdIcone) {
    if (na_bandeja_) {
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
        case NIN_SELECT:
        case NIN_KEYSELECT:
          RestaurarDaBandeja(hwnd);
          break;
        case WM_CONTEXTMENU:
          MostrarMenuDaBandeja(hwnd);
          break;
      }
    }
    return 0;
  }
  if (message == WM_DESTROY) RemoverIcone(hwnd);
  if (na_bandeja_ && message == WM_WINDOWPOSCHANGED &&
      (reinterpret_cast<const WINDOWPOS*>(lparam)->flags & SWP_SHOWWINDOW)) {
    RemoverIcone(hwnd);
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
    case WM_GETMINMAXINFO: {
      // Tamanho minimo da janela: 900 x 640 (pontos logicos).
      const double escala = ::GetDpiForWindow(hwnd) / 96.0;
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = static_cast<LONG>(900 * escala);
      info->ptMinTrackSize.y = static_cast<LONG>(640 * escala);
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
