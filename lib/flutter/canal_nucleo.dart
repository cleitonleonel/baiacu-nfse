/// Protocolo de respostas do Rust, independente da biblioteca nativa.
library;

import 'dart:async';

class ErroNucleo implements Exception {
  ErroNucleo(this.tipo, this.msg, [this.dados]);
  final String tipo;
  final String msg;
  final Object? dados;

  bool get eValor => tipo == 'ValueError';

  @override
  String toString() => msg;
}

class _Pendente {
  _Pendente(this.aoAvisar);
  final void Function(Object?)? aoAvisar;
  final Completer<Object?> resultado = Completer<Object?>();
}

/// Uma chamada pode produzir vários avisos antes da única resposta final.
class CanalNucleo {
  final Map<int, _Pendente> _pendentes = {};

  Future<T> preparar<T>(int id, {void Function(Object?)? aoAvisar}) {
    if (_pendentes.containsKey(id)) throw StateError('Chamada duplicada: $id');
    final p = _Pendente(aoAvisar);
    _pendentes[id] = p;
    return p.resultado.future.then((valor) => valor as T);
  }

  void responder(int id, Map<String, dynamic> resposta) {
    final p = _pendentes[id];
    if (p == null) return;
    if (resposta.containsKey('aviso')) {
      p.aoAvisar?.call(resposta['aviso']);
      return;
    }
    _pendentes.remove(id);
    try {
      p.resultado.complete(abrir(resposta));
    } catch (erro, pilha) {
      p.resultado.completeError(erro, pilha);
    }
  }

  void falhar(int id, Object erro, StackTrace pilha) {
    _pendentes.remove(id)?.resultado.completeError(erro, pilha);
  }

  static Object? abrir(Map<String, dynamic> resposta) {
    final erro = resposta['erro'];
    if (erro is Map<String, dynamic>) {
      throw ErroNucleo(
        erro['tipo'] as String? ?? 'RuntimeError',
        erro['msg'] as String? ?? '',
        erro['dados'],
      );
    }
    if (!resposta.containsKey('ok')) {
      throw const FormatException('Resposta do núcleo sem resultado.');
    }
    return resposta['ok'];
  }
}
