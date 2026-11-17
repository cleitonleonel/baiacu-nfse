#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"
#include "startup_guard.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool oculta = false, StartupGuard* starting = nullptr);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  bool AdicionarIcone(HWND window);
  void RemoverIcone(HWND window);
  void RestaurarDaBandeja(HWND window);
  void MostrarMenuDaBandeja(HWND window);

  // The project to run.
  flutter::DartProject project_;

  // Conferencia de partida (NFSE_OCULTA): a janela nunca e mostrada.
  bool oculta_ = false;
  StartupGuard* starting_ = nullptr;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> janela_;
  UINT mensagem_taskbar_criada_ = 0;
  UINT mensagem_fechar_instalador_ = 0;
  bool na_bandeja_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
