import 'dart:io';

class OrigemElemento {
  const OrigemElemento(this.arquivo, this.linha, this.relativo);
  final File arquivo;
  final int linha;
  final String relativo;

  Future<void> abrir() async {
    if (!await arquivo.exists())
      throw FileSystemException('Arquivo não encontrado', arquivo.path);
    final candidatos = [
      '${Platform.environment['ProgramFiles'] ?? r'C:\Program Files'}/Microsoft VS Code/Code.exe',
      '${Platform.environment['LOCALAPPDATA'] ?? ''}/Programs/Microsoft VS Code/Code.exe',
    ];
    for (final exe in candidatos) {
      if (await File(exe).exists()) {
        await Process.start(exe, [
          '--reuse-window',
          '--goto',
          '${arquivo.path}:$linha',
        ], mode: ProcessStartMode.detached);
        return;
      }
    }
    await Process.start('notepad.exe', [
      arquivo.path,
    ], mode: ProcessStartMode.detached);
  }
}

/// Resolve apenas ao selecionar um elemento. Não faz I/O durante cada quadro.
class IndiceFontes {
  IndiceFontes(this.raiz);
  final Directory raiz;
  Map<File, List<String>>? _fontes;
  Map<File, String>? _compactas;
  final Map<String, OrigemElemento?> _cache = {};

  void limpar() {
    _fontes = null;
    _compactas = null;
    _cache.clear();
  }

  OrigemElemento? localizar(String id, String nome) {
    final chave = '$id\n$nome';
    if (_cache.containsKey(chave)) return _cache[chave];
    final lib = Directory('${raiz.path}/lib/flutter');
    if (!lib.existsSync()) return null;
    _fontes ??= {
      for (final f
          in lib
              .listSync(recursive: true, followLinks: false)
              .whereType<File>())
        if (f.path.endsWith('.dart')) f: f.readAsLinesSync(),
    };
    final branco = RegExp(r'\s+');
    _compactas ??= {
      for (final e in _fontes!.entries)
        e.key: e.value.join('\n').replaceAll(branco, ''),
    };
    var base = id.split(':').first.split('.espaco.').first;
    if (base.contains('.item.')) {
      final parte = Uri.decodeComponent(base.split('.item.').last);
      base = int.tryParse(parte) == null ? parte : base.split('.item.').first;
    }
    if (base.isEmpty) return null;
    // Colunas e células repetidas têm um ID por campo/coluna gerado em tempo de execução.
    // Localiza a declaração do prefixo no código para permitir abrir sua origem no desenvolver.
    if (!_compactas!.values.any((texto) => texto.contains(base))) {
      var prefixo = base;
      while (prefixo.split('.').length > 2) {
        prefixo = prefixo.substring(0, prefixo.lastIndexOf('.'));
        if (_compactas!.values.any((texto) => texto.contains('$prefixo.'))) {
          base = '$prefixo.';
          break;
        }
      }
    }
    final candidatos = _fontes!.entries
        .where((e) => _compactas![e.key]!.contains(base))
        .toList();
    int prioridade(File f) {
      final caminho = f.path.replaceAll('\\', '/');
      if (caminho.endsWith('/estilo.dart')) return 3;
      if (caminho.contains('/kit/') || caminho.endsWith('/editor_layout.dart'))
        return 2;
      return 1;
    }

    candidatos.sort((a, b) => prioridade(a.key).compareTo(prioridade(b.key)));
    if (candidatos.isEmpty) return _cache[chave] = null;
    final fonte = candidatos.first;
    final ids = [
      for (var i = 0; i < fonte.value.length; i++)
        if (fonte.value[i].replaceAll(branco, '').contains(base)) i,
    ];
    if (ids.isEmpty) {
      for (var i = 0; i + 1 < fonte.value.length; i++) {
        if ((fonte.value[i] + fonte.value[i + 1])
            .replaceAll(branco, '')
            .contains(base))
          ids.add(i);
      }
    }
    if (ids.isEmpty) ids.add(0);
    final texto = nome.replaceAll("'", r"\'");
    final textos = [
      for (var i = 0; i < fonte.value.length; i++)
        if (nome.isNotEmpty &&
            (fonte.value[i].contains("'$texto'") ||
                fonte.value[i].contains('"$nome"')))
          i,
    ];
    if (textos.isEmpty && nome.length >= 20) {
      final inicio = nome.substring(0, nome.length < 50 ? nome.length : 50);
      for (var i = 0; i < fonte.value.length; i++) {
        if (fonte.value[i].contains(inicio)) textos.add(i);
      }
    }
    var indice = ids.first;
    if (textos.isNotEmpty) {
      int distancia(int i) =>
          ids.map((n) => (n - i).abs()).reduce((a, b) => a < b ? a : b);
      textos.sort((a, b) => distancia(a).compareTo(distancia(b)));
      indice = textos.first;
    }
    final relativo = fonte.key.path
        .substring(raiz.path.length + 1)
        .replaceAll('\\', '/');
    return _cache[chave] = OrigemElemento(
      fonte.key.absolute,
      indice + 1,
      relativo,
    );
  }
}
