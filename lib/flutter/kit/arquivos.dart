/// Seletores de arquivo do Windows ("Abrir" e "Salvar como"), com título, nome sugerido e
/// filtro de extensão. A janela do sistema roda fora da linha de execução da tela, que
/// continua desenhando enquanto ela está aberta.
library;

import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

final class _Ofn extends Struct {
  @Uint32()
  external int lStructSize;
  external Pointer<Void> hwndOwner;
  external Pointer<Void> hInstance;
  external Pointer<Utf16> lpstrFilter;
  external Pointer<Utf16> lpstrCustomFilter;
  @Uint32()
  external int nMaxCustFilter;
  @Uint32()
  external int nFilterIndex;
  external Pointer<Utf16> lpstrFile;
  @Uint32()
  external int nMaxFile;
  external Pointer<Utf16> lpstrFileTitle;
  @Uint32()
  external int nMaxFileTitle;
  external Pointer<Utf16> lpstrInitialDir;
  external Pointer<Utf16> lpstrTitle;
  @Uint32()
  external int flags;
  @Uint16()
  external int nFileOffset;
  @Uint16()
  external int nFileExtension;
  external Pointer<Utf16> lpstrDefExt;
  @IntPtr()
  external int lCustData;
  external Pointer<Void> lpfnHook;
  external Pointer<Utf16> lpTemplateName;
  external Pointer<Void> pvReserved;
  @Uint32()
  external int dwReserved;
  @Uint32()
  external int flagsEx;
}

typedef _DialogoC = Int32 Function(Pointer<_Ofn>);
typedef _DialogoD = int Function(Pointer<_Ofn>);
typedef _JanelaC = IntPtr Function();
typedef _JanelaD = int Function();

const _ofnOverwritePrompt = 0x00000002;
const _ofnHideReadOnly = 0x00000004;
const _ofnPathMustExist = 0x00000800;
const _ofnFileMustExist = 0x00001000;
const _ofnExplorer = 0x00080000;
const _maxCaminho = 4096;

int _janelaAtiva() {
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    return user32.lookupFunction<_JanelaC, _JanelaD>('GetForegroundWindow')();
  } catch (_) {
    return 0;
  }
}

/// "Files (*.a,*.b)\0*.a;*.b\0\0" em UTF-16.
Pointer<Utf16> _filtro(List<String> extensoes) {
  final nome = 'Files (${extensoes.map((e) => '*.$e').join(',')})';
  final padrao = extensoes.map((e) => '*.$e').join(';');
  final unidades = <int>[...nome.codeUnits, 0, ...padrao.codeUnits, 0, 0];
  final p = calloc<Uint16>(unidades.length);
  p.asTypedList(unidades.length).setAll(0, unidades);
  return p.cast<Utf16>();
}

String? _abrirDialogo(
  (bool salvar, String titulo, String nome, List<String> extensoes, int dono) a,
) {
  final (salvar, titulo, nome, extensoes, dono) = a;
  final comdlg = DynamicLibrary.open('comdlg32.dll');
  final funcao = comdlg.lookupFunction<_DialogoC, _DialogoD>(
    salvar ? 'GetSaveFileNameW' : 'GetOpenFileNameW',
  );
  final ofn = calloc<_Ofn>();
  final arquivo = calloc<Uint16>(_maxCaminho);
  final tituloP = titulo.toNativeUtf16();
  final filtroP = extensoes.isEmpty ? nullptr : _filtro(extensoes);
  try {
    if (nome.isNotEmpty) {
      final u = nome.codeUnits;
      final n = u.length < _maxCaminho - 1 ? u.length : _maxCaminho - 1;
      arquivo.asTypedList(_maxCaminho).setAll(0, u.take(n));
    }
    ofn.ref
      ..lStructSize = sizeOf<_Ofn>()
      ..hwndOwner = Pointer<Void>.fromAddress(dono)
      ..lpstrFilter = filtroP
      ..nFilterIndex = 1
      ..lpstrFile = arquivo.cast<Utf16>()
      ..nMaxFile = _maxCaminho
      ..lpstrTitle = tituloP
      ..flags = salvar
          ? (_ofnExplorer |
                _ofnPathMustExist |
                _ofnOverwritePrompt |
                _ofnHideReadOnly)
          : (_ofnExplorer | _ofnFileMustExist | _ofnHideReadOnly);
    if (funcao(ofn) == 0) return null;
    return arquivo.cast<Utf16>().toDartString();
  } finally {
    calloc.free(ofn);
    calloc.free(arquivo);
    calloc.free(tituloP);
    if (filtroP != nullptr) calloc.free(filtroP);
  }
}

Future<String?> _dialogo(
  bool salvar,
  String titulo,
  String nome,
  List<String> extensoes,
) async {
  final dono = _janelaAtiva();
  return Isolate.run(
    () => _abrirDialogo((salvar, titulo, nome, extensoes, dono)),
  );
}

/// "Abrir": o caminho escolhido, ou nulo se o usuário desistiu.
Future<String?> escolherArquivo({
  required String titulo,
  List<String> extensoes = const [],
}) => _dialogo(false, titulo, '', extensoes);

/// "Salvar como": o caminho de destino, ou nulo se o usuário desistiu.
Future<String?> salvarArquivo({
  required String titulo,
  String nome = '',
  List<String> extensoes = const [],
}) => _dialogo(true, titulo, nome, extensoes);
