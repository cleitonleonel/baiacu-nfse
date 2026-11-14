/// Pontes com o Windows: abrir um arquivo/endereço no programa padrão, abrir um PDF no leitor
/// que vem com o programa, copiar para a área de transferência.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'app.dart';

typedef _ShellC =
    IntPtr Function(
      IntPtr hwnd,
      Pointer<Utf16> operacao,
      Pointer<Utf16> arquivo,
      Pointer<Utf16> parametros,
      Pointer<Utf16> pasta,
      Int32 mostrar,
    );
typedef _ShellD =
    int Function(
      int hwnd,
      Pointer<Utf16> operacao,
      Pointer<Utf16> arquivo,
      Pointer<Utf16> parametros,
      Pointer<Utf16> pasta,
      int mostrar,
    );

void _shellAbrir(String alvo) {
  final shell = DynamicLibrary.open('shell32.dll');
  final executar = shell.lookupFunction<_ShellC, _ShellD>('ShellExecuteW');
  final operacao = 'open'.toNativeUtf16();
  final arquivo = alvo.toNativeUtf16();
  try {
    final r = executar(0, operacao, arquivo, nullptr, nullptr, 1);
    if (r <= 32) throw OSError('Não foi possível abrir: $alvo', r);
  } finally {
    calloc.free(operacao);
    calloc.free(arquivo);
  }
}

/// Abre o arquivo no aplicativo padrão do sistema (associação de extensão).
void abrirNoSistema(String caminho) {
  if (!File(caminho).existsSync() && !Directory(caminho).existsSync()) {
    throw FileSystemException('Arquivo não encontrado', caminho);
  }
  _shellAbrir(caminho);
}

/// Abre um endereço https no navegador padrão (só https: nada de arquivo ou outro esquema).
void abrirEndereco(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.scheme != 'https' || u.host.isEmpty) {
    throw ArgumentError('Endereço inválido: $url');
  }
  _shellAbrir(u.toString());
}

// ---- leitor de PDF que vem com o programa -------------------------------------- //
typedef _EnumC = Int32 Function(IntPtr hwnd, IntPtr param);
typedef _EnumWindowsC = Int32 Function(Pointer<NativeFunction<_EnumC>>, IntPtr);
typedef _EnumWindowsD = int Function(Pointer<NativeFunction<_EnumC>>, int);
typedef _PidC = Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _PidD = int Function(int, Pointer<Uint32>);
typedef _BoolC = Int32 Function(IntPtr);
typedef _BoolD = int Function(int);
typedef _MostrarC = Int32 Function(IntPtr, Int32);
typedef _MostrarD = int Function(int, int);
typedef _PosC =
    Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32);
typedef _PosD = int Function(int, int, int, int, int, int, int);
typedef _PermitirC = Int32 Function(Uint32);
typedef _PermitirD = int Function(int);

int _pidProcurado = 0;
int _pidAlternativo = 0;
int _pidEncontrado = 0;
int _leitorPid = 0;
String _arquivoEsperado = '';
int _janelaAchada = 0;
typedef _TituloC = Int32 Function(IntPtr, Pointer<Utf16>, Int32);
typedef _TituloD = int Function(int, Pointer<Utf16>, int);
final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final _pidDaJanela = _user32.lookupFunction<_PidC, _PidD>(
  'GetWindowThreadProcessId',
);
final _visivel = _user32.lookupFunction<_BoolC, _BoolD>('IsWindowVisible');

int _aoEnumerar(int hwnd, int _) {
  final pid = calloc<Uint32>();
  try {
    _pidDaJanela(hwnd, pid);
    if ((pid.value == _pidProcurado || pid.value == _pidAlternativo) &&
        _visivel(hwnd) != 0) {
      final titulo = calloc<Uint16>(1024).cast<Utf16>();
      try {
        _user32.lookupFunction<_TituloC, _TituloD>('GetWindowTextW')(
          hwnd,
          titulo,
          1024,
        );
        if (!titulo.toDartString().toLowerCase().contains(_arquivoEsperado))
          return 1;
      } finally {
        calloc.free(titulo);
      }
      _pidEncontrado = pid.value;
      _janelaAchada = hwnd;
      return 0;
    }
  } finally {
    calloc.free(pid);
  }
  return 1;
}

/// Abre o PDF no leitor portátil que acompanha o programa (tela cheia, página inteira).
Future<void> abrirPdfNativo(String caminho) async {
  final pdf = File(caminho).absolute;
  if (!pdf.existsSync()) {
    throw FileSystemException('PDF nao encontrado', pdf.path);
  }
  final raiz = ja<String>('nucleo.raiz');
  final exe = File('$raiz\\bin\\sumatrapdf\\SumatraPDF.exe').absolute;
  if (!exe.existsSync()) {
    throw FileSystemException('SumatraPDF nao encontrado', exe.path);
  }
  if (_leitorPid != 0) {
    try {
      if (await chamar<bool>('pdf.abrir_no_leitor', {
        'arquivo': pdf.path,
        'pid': _leitorPid,
      })) {
        unawaited(
          _primeiroPlanoPorPid(
            _leitorPid,
            pdf.uri.pathSegments.last.toLowerCase(),
          ),
        );
        return;
      }
    } catch (_) {
      /* O leitor pode ter sido fechado: a abertura normal segue abaixo. */
    }
  }
  final processo = await Process.start(
    exe.path,
    [
      '-appdata',
      exe.parent.path,
      '-reuse-instance',
      '-new-window',
      '-fullscreen',
      '-zoom',
      'fit page',
      pdf.path,
    ],
    workingDirectory: exe.parent.path,
    mode: ProcessStartMode.detached,
  );
  try {
    _user32.lookupFunction<_PermitirC, _PermitirD>('AllowSetForegroundWindow')(
      processo.pid,
    );
  } catch (_) {}
  unawaited(
    _primeiroPlanoPorPid(processo.pid, pdf.uri.pathSegments.last.toLowerCase()),
  );
}

/// Espera a primeira janela do leitor aparecer e a traz para a frente.
Future<void> _primeiroPlanoPorPid(int pid, String arquivo) async {
  final enumerar = _user32.lookupFunction<_EnumWindowsC, _EnumWindowsD>(
    'EnumWindows',
  );
  final minimizada = _user32.lookupFunction<_BoolC, _BoolD>('IsIconic');
  final mostrar = _user32.lookupFunction<_MostrarC, _MostrarD>('ShowWindow');
  final topo = _user32.lookupFunction<_BoolC, _BoolD>('BringWindowToTop');
  final frente = _user32.lookupFunction<_BoolC, _BoolD>('SetForegroundWindow');
  final posicionar = _user32.lookupFunction<_PosC, _PosD>('SetWindowPos');
  final retorno = Pointer.fromFunction<_EnumC>(_aoEnumerar, 1);
  const restaurar = 9;
  const flags = 0x0002 | 0x0001 | 0x0040;
  for (var i = 0; i < 250; i++) {
    _pidProcurado = pid;
    _pidAlternativo = _leitorPid;
    _arquivoEsperado = arquivo;
    _janelaAchada = 0;
    enumerar(retorno, 0);
    final janela = _janelaAchada;
    if (janela != 0) {
      _leitorPid = _pidEncontrado;
      if (minimizada(janela) != 0) mostrar(janela, restaurar);
      posicionar(janela, -1, 0, 0, 0, 0, flags);
      topo(janela);
      frente(janela);
      posicionar(janela, -2, 0, 0, 0, 0, flags);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

// ---- o que as telas chamam ------------------------------------------------------- //
/// PDF: o leitor que vem com o programa, ou o padrão do Windows se o usuário desmarcou
/// "Usar leitor PDF nativo" (Configurações > Outros). O resto vai para o programa padrão.
void abrirCaminho(App app, String caminho) {
  try {
    if (caminho.toLowerCase().endsWith('.pdf') && app.pdfNativo) {
      abrirPdfNativo(caminho).catchError((Object e) {
        app.toast('$e', erro: true);
      });
    } else {
      abrirNoSistema(caminho);
    }
  } catch (e) {
    app.toast('$e', erro: true);
  }
}

/// Abre um endereço no navegador padrão do sistema.
void abrirUrl(App app, String url) {
  if (url.isEmpty) return;
  try {
    _shellAbrir(url);
  } catch (e) {
    registrar('Falha ao abrir a URL $url: $e', nivel: 'error');
    app.toast('Não consegui abrir o navegador: $e', erro: true);
  }
}

/// Copia para a área de transferência.
void copiar(
  App app,
  String texto, {
  String aviso = 'Copiado para a área de transferência.',
}) {
  if (texto.isEmpty) return;
  Clipboard.setData(ClipboardData(text: texto)).then(
    (_) => app.toast(aviso),
    onError: (Object e) {
      registrar(
        'Falha ao copiar para a área de transferência: $e',
        nivel: 'error',
      );
      app.toast(
        'Não consegui copiar — selecione o texto e use Ctrl+C.',
        erro: true,
      );
    },
  );
}
