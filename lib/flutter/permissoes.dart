/// Perfil por nível recebido do núcleo.
class RegraPermissao {
  RegraPermissao(Map dados)
    : id = dados['id'] as String,
      titulo = dados['rotulo'] as String,
      pai = dados['pai'] as String,
      padrao = dados['padrao'] as int,
      fixa = dados['fixo'] as bool;

  final String id, titulo, pai;
  final int padrao;
  final bool fixa;
}

class Permissoes {
  static Map<String, RegraPermissao> _catalogo = {};
  static Iterable<RegraPermissao> get regras => _catalogo.values;
  static Map<String, int> niveis = {};

  static void carregar(Map resposta) {
    _catalogo = {
      for (final dados in resposta['catalogo'] as List)
        dados['id'] as String: RegraPermissao(dados as Map),
    };
    aplicar(resposta['perfil'] as Map);
  }

  static void aplicar(Map perfil) {
    niveis = Map<String, int>.unmodifiable(
      Map<String, int>.from(perfil['niveis'] as Map),
    );
  }

  static int efetivo(String id, [Map<String, int>? valores]) {
    final dados = valores ?? niveis;
    var nivel = 1;
    var atual = id;
    while (atual.isNotEmpty) {
      final regra = _catalogo[atual];
      if (regra == null) return 4;
      final proprio = regra.fixa ? 4 : dados[atual] ?? regra.padrao;
      if (proprio > nivel) nivel = proprio;
      atual = regra.pai;
    }
    return nivel;
  }
}
