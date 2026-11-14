library;

import '../nucleo.dart';

String brlDigitos(String s) {
  final d = s.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.isEmpty) return '';
  final n = BigInt.parse(d);
  final inteiro = (n ~/ BigInt.from(100)).toString();
  final grupos = inteiro.replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (m) => '${m[1]}.',
  );
  return 'R\$ $grupos,${(n % BigInt.from(100)).toString().padLeft(2, '0')}';
}

String brlDecimal(String s) {
  final d = s.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.isEmpty) return '';
  final n = BigInt.parse(d);
  return '${n ~/ BigInt.from(100)}.${(n % BigInt.from(100)).toString().padLeft(2, '0')}';
}

String decimalBrl(String s) {
  final d = double.tryParse(s.trim().replaceAll(',', '.'));
  if (d == null || !d.isFinite) return '';
  final v = d * 100;
  final baixo = v.floor();
  final fracao = v - baixo;
  final centavos = fracao == 0.5
      ? (baixo.isEven ? baixo : baixo + 1)
      : v.round();
  return brlDigitos('$centavos');
}

String moeda(String s) => s.trim().isEmpty
    ? '—'
    : Nucleo.ja<String>('texto.fmt_money_br', {'valor': s});
String dataHora(String s) {
  final r = s.trim().replaceAll('T', ' ');
  if (r.isEmpty) return '—';
  if (r.length >= 19 && RegExp(r'^\d{4}-\d{2}-\d{2} ').hasMatch(r))
    return '${r.substring(8, 10)}/${r.substring(5, 7)}/${r.substring(0, 4)} ${r.substring(11, 19)}';
  return r.length > 19 ? r.substring(0, 19) : r;
}

String isoDia(DateTime? d) => d == null
    ? ''
    : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String diaBr(DateTime? d) => d == null
    ? ''
    : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

const periodos = [
  ('hoje', 'Hoje'),
  ('mes', 'Este mês'),
  ('mes_ant', 'Mês anterior'),
  ('ano', 'Este ano'),
  ('custom', 'Personalizado'),
];
(DateTime?, DateTime?) intervalo(
  String p, {
  DateTime? de,
  DateTime? ate,
  DateTime? agora,
}) {
  final n = agora ?? DateTime.now();
  return switch (p) {
    'hoje' => (
      DateTime(n.year, n.month, n.day),
      DateTime(n.year, n.month, n.day),
    ),
    'mes' => (DateTime(n.year, n.month), DateTime(n.year, n.month + 1, 0)),
    'mes_ant' => (DateTime(n.year, n.month - 1), DateTime(n.year, n.month, 0)),
    'ano' => (DateTime(n.year), DateTime(n.year, 12, 31)),
    'custom' => (de, ate),
    _ => (null, null),
  };
}

/// Percentual digitado só com VÍRGULA: '13.45' -> '13,45' (dígitos + 1 vírgula).
String pctVirgula(String texto) {
  final b = StringBuffer();
  var temVirgula = false;
  for (final c in texto.replaceAll('.', ',').split('')) {
    if (RegExp(r'^[0-9]$').hasMatch(c)) {
      b.write(c);
    } else if (c == ',' && !temVirgula) {
      b.write(c);
      temVirgula = true;
    }
  }
  return b.toString();
}

/// Percentual da copropriedade: somente dígitos e vírgula, de 0 a 100, até duas casas.
String copropriedadeVirgula(String texto) {
  final partes = texto.replaceAll(RegExp(r'[^0-9,]'), '').split(',');
  var inteiro = partes.first.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  if (inteiro.isEmpty && partes.length > 1) inteiro = '0';
  if (inteiro.length > 3 || (int.tryParse(inteiro) ?? 0) > 100) return '100';
  if (partes.length == 1) return inteiro;
  final fracao = partes.skip(1).join();
  final casas = fracao.substring(0, fracao.length > 2 ? 2 : fracao.length);
  if (inteiro == '100' && casas.contains(RegExp(r'[1-9]'))) return '100,00';
  return '$inteiro,$casas';
}

DateTime? lerDataDoCampo(String texto) {
  final s = texto.trim();
  final br = RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(s);
  if (!br && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return null;
  final p = s.split(br ? '/' : '-').map(int.parse).toList();
  final (ano, mes, dia) = br ? (p[2], p[1], p[0]) : (p[0], p[1], p[2]);
  if (ano < 1 || ano > 9999) return null;
  final d = DateTime(ano, mes, dia);
  return d.year == ano && d.month == mes && d.day == dia ? d : null;
}

String dataIsoParaBr(String texto) {
  final d = lerDataDoCampo(texto);
  if (d == null) return texto;
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year.toString().padLeft(4, '0')}';
}

String dataBrParaIso(String texto) {
  final d = lerDataDoCampo(texto);
  if (d == null) return texto;
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// Decimal EXATO (inteiro + número de casas): o bastante para os cálculos de percentual que
/// a tela mostra enquanto se digita, com o mesmo arredondamento comercial do núcleo.
class Dec {
  const Dec(this.v, this.casas);
  final BigInt v;
  final int casas;

  static final zero = Dec(BigInt.zero, 0);
  static final _cem = Dec(BigInt.from(100), 0);

  /// '0,65' / '0.65 %' / '' -> decimal (0 se vazio/inválido).
  static Dec ouZero(String? texto) {
    final cru = (texto ?? '')
        .trim()
        .replaceAll('%', '')
        .replaceAll(',', '.')
        .trim();
    final m = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?$').firstMatch(cru);
    if (m == null || ((m[2] ?? '').isEmpty && (m[3] ?? '').isEmpty))
      return zero;
    final inteiro = m[2] ?? '';
    final fracao = m[3] ?? '';
    var n = BigInt.parse('${inteiro.isEmpty ? '0' : inteiro}$fracao');
    if (m[1] == '-') n = -n;
    return Dec(n, fracao.length);
  }

  Dec operator *(Dec o) => Dec(v * o.v, casas + o.casas);

  Dec operator +(Dec o) {
    final c = casas > o.casas ? casas : o.casas;
    return Dec(_na(c) + o._na(c), c);
  }

  Dec operator -(Dec o) {
    final c = casas > o.casas ? casas : o.casas;
    return Dec(_na(c) - o._na(c), c);
  }

  BigInt _na(int c) => v * BigInt.from(10).pow(c - casas);

  bool get positivo => v > BigInt.zero;

  /// Duas casas, arredondamento comercial (0,005 sobe).
  Dec dinheiro() {
    if (casas <= 2) return Dec(_na(2), 2);
    final divisor = BigInt.from(10).pow(casas - 2);
    final negativo = v.isNegative;
    final abs = v.abs();
    var q = abs ~/ divisor;
    final resto = abs % divisor;
    if (resto * BigInt.two >= divisor) q += BigInt.one;
    return Dec(negativo ? -q : q, 2);
  }

  /// base × percentual ÷ 100, em dinheiro.
  static Dec percentual(Dec base, Dec pct) =>
      Dec((base * pct).v, (base * pct).casas + _cem.casas + 2).dinheiro();

  /// '1234.50'
  String fixo2() {
    final d = dinheiro();
    final abs = d.v.abs();
    final cem = BigInt.from(100);
    return '${d.v.isNegative ? '-' : ''}${abs ~/ cem}.${(abs % cem).toString().padLeft(2, '0')}';
  }
}

/// Sobra de percentual: guarda só se difere do herdado do prestador ('' = herda).
String sobraPercentual(String? mostrado, String? herdado) {
  final s = (mostrado ?? '').trim().replaceAll('%', '');
  if (s.isEmpty) return '';
  if (herdado != null && herdado.isNotEmpty) {
    final a = double.tryParse(s.replaceAll(',', '.'));
    final b = double.tryParse(herdado.replaceAll(',', '.'));
    if (a != null && b != null && a == b) return '';
  }
  return s;
}

const _acentos = {
  'á': 'a',
  'à': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ā': 'a',
  'ă': 'a',
  'ą': 'a',
  'ç': 'c',
  'ć': 'c',
  'č': 'c',
  'ď': 'd',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ė': 'e',
  'ę': 'e',
  'ě': 'e',
  'í': 'i',
  'ì': 'i',
  'î': 'i',
  'ï': 'i',
  'ī': 'i',
  'į': 'i',
  'ñ': 'n',
  'ń': 'n',
  'ň': 'n',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ō': 'o',
  'ő': 'o',
  'ř': 'r',
  'ś': 's',
  'š': 's',
  'ş': 's',
  'ť': 't',
  'ţ': 't',
  'ú': 'u',
  'ù': 'u',
  'û': 'u',
  'ü': 'u',
  'ū': 'u',
  'ů': 'u',
  'ű': 'u',
  'ų': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ź': 'z',
  'ż': 'z',
  'ž': 'z',
};

final Map<int, int> _acentosPorCodigo = {
  for (final e in _acentos.entries) e.key.codeUnitAt(0): e.value.codeUnitAt(0),
};

/// Normaliza para busca: minúsculas e sem acentos ('São' -> 'sao').
String semAcento(String s) {
  final m = s.toLowerCase();
  final n = m.length;
  // Só letras sem acento (o caso mais comum): não há o que trocar.
  var i = 0;
  while (i < n && m.codeUnitAt(i) < 0x80) {
    i++;
  }
  if (i == n) return m;
  final b = StringBuffer(m.substring(0, i));
  for (; i < n; i++) {
    final c = m.codeUnitAt(i);
    b.writeCharCode(c < 0x80 ? c : (_acentosPorCodigo[c] ?? c));
  }
  return b.toString();
}

final _naoAlfanumerico = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

List<String> termosBusca(String s) =>
    semAcento(s).split(_naoAlfanumerico).where((t) => t.isNotEmpty).toList();

String buscaCompacta(String s) => termosBusca(s).join();

/// Como a BUSCA das listas enxerga um texto — a regra do programa em Python: sem acento, sem
/// maiúsculas e sem pontuação. "9903" acha "99.03.01 - Locação…", "sao pau" acha "São Paulo" e
/// "11222333" acha "11.222.333/0001-81".
class TextoDeBusca {
  TextoDeBusca(String texto) : palavras = termosBusca(texto).join(' ');
  final String palavras;
  late final String junto = palavras.replaceAll(' ', '');

  /// O texto casa com o que foi digitado? [termos] são as palavras digitadas (`termosBusca`) e
  /// [consulta], elas emendadas. Vale o texto corrido ou todas as palavras, em qualquer ordem.
  bool casa(String consulta, List<String> termos) =>
      junto.contains(consulta) || termos.every(palavras.contains);
}
