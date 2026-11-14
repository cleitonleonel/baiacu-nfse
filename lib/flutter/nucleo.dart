/// Ponte com o núcleo em Rust (nucleo.dll): as regras do programa moram lá.
///
/// `Nucleo.chamar("modulo.funcao", {...})` devolve um Future — o trabalho roda numa thread do
/// núcleo e a tela continua desenhando. `Nucleo.ja(...)` responde na hora e serve só para o
/// que não espera disco nem rede.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'canal_nucleo.dart';
export 'canal_nucleo.dart' show ErroNucleo;

/// Erro vindo do núcleo. [tipo] diz o que a tela faz com ele: "ValueError" é mensagem para o
/// usuário; "BancoTrancado" volta para a tela de acesso.
typedef _RetornoC = Void Function(Int64 id, Pointer<Utf8> json);
typedef _IniciarC =
    Void Function(
      Pointer<Utf8> raiz,
      Pointer<NativeFunction<_RetornoC>> retorno,
    );
typedef _IniciarD =
    void Function(
      Pointer<Utf8> raiz,
      Pointer<NativeFunction<_RetornoC>> retorno,
    );
typedef _ChamarC =
    Void Function(Int64 id, Pointer<Utf8> metodo, Pointer<Utf8> args);
typedef _ChamarD =
    void Function(int id, Pointer<Utf8> metodo, Pointer<Utf8> args);
typedef _ChamarJaC =
    Pointer<Utf8> Function(Pointer<Utf8> metodo, Pointer<Utf8> args);
typedef _LiberarC = Void Function(Pointer<Utf8> p);
typedef _LiberarD = void Function(Pointer<Utf8> p);

class Nucleo {
  Nucleo._();

  static late final DynamicLibrary _lib;
  static late final _ChamarD _chamar;
  static late final _ChamarJaC _chamarJa;
  static late final _LiberarD _liberar;
  static late final NativeCallable<_RetornoC> _retorno;
  static final CanalNucleo _canal = CanalNucleo();
  static int _proximo = 1;

  /// Carrega a biblioteca e diz ao núcleo onde ficam database/, logs/ e configs/.
  static void iniciar(String raiz) {
    // As DLLs do programa moram em data/dll, não ao lado do executável.
    final s = Platform.pathSeparator;
    final pasta = File(Platform.resolvedExecutable).parent.path;
    _lib = DynamicLibrary.open('$pasta${s}data${s}dll${s}nucleo.dll');
    _chamar = _lib.lookupFunction<_ChamarC, _ChamarD>('nfse_chamar');
    _chamarJa = _lib.lookupFunction<_ChamarJaC, _ChamarJaC>('nfse_chamar_ja');
    _liberar = _lib.lookupFunction<_LiberarC, _LiberarD>('nfse_liberar');
    _retorno = NativeCallable<_RetornoC>.listener(_aoResponder);
    final p = raiz.toNativeUtf8();
    _lib.lookupFunction<_IniciarC, _IniciarD>('nfse_iniciar')(
      p,
      _retorno.nativeFunction,
    );
    malloc.free(p);
  }

  static Map<String, dynamic> _ler(Pointer<Utf8> json) {
    try {
      return jsonDecode(json.toDartString()) as Map<String, dynamic>;
    } finally {
      _liberar(json);
    }
  }

  static void _aoResponder(int id, Pointer<Utf8> json) {
    try {
      _canal.responder(id, _ler(json));
    } catch (e, pilha) {
      _canal.falhar(id, e, pilha);
    }
  }

  /// Chamada ao núcleo, fora da thread da tela.
  static Future<T> chamar<T>(
    String metodo, [
    Map<String, Object?> args = const {},
  ]) {
    return chamarAcompanhando<T>(metodo, args);
  }

  static Future<T> chamarAcompanhando<T>(
    String metodo,
    Map<String, Object?> args, {
    void Function(Object?)? aoAvisar,
  }) {
    final argsJson = jsonEncode(args);
    final id = _proximo++;
    final resultado = _canal.preparar<T>(id, aoAvisar: aoAvisar);
    final m = metodo.toNativeUtf8();
    final a = argsJson.toNativeUtf8();
    try {
      _chamar(id, m, a);
    } catch (e, pilha) {
      _canal.falhar(id, e, pilha);
    } finally {
      malloc.free(m);
      malloc.free(a);
    }
    return resultado;
  }

  /// Chamada que responde na hora, na thread da tela — só para o que é memória.
  static T ja<T>(String metodo, [Map<String, Object?> args = const {}]) {
    final m = metodo.toNativeUtf8();
    final a = jsonEncode(args).toNativeUtf8();
    try {
      return CanalNucleo.abrir(_ler(_chamarJa(m, a))) as T;
    } finally {
      malloc.free(m);
      malloc.free(a);
    }
  }
}
