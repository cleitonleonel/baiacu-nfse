/// Janelas do programa: um cartão centrado sobre um véu, numa camada própria por cima das
/// telas e por baixo dos avisos do rodapé. Abrir = entrar na pilha; fechar = sair dela.
library;

import 'package:flutter/material.dart';

import '../kit/flet.dart';
import '../editor_layout.dart';

/// Título em LINHA (texto + botões à direita): ocupa a largura do conteúdo da janela.
class LinhaTitulo extends StatelessWidget {
  const LinhaTitulo(this.filhos, {super.key, this.espaco = 8});
  final List<Widget> filhos;
  final double espaco;

  @override
  Widget build(BuildContext context) =>
      lin(filhos, espaco: espaco, idLayout: 'Grupo.dialogo.lin.1');
}

class Dialogo extends ChangeNotifier {
  Dialogo({
    this.idLayout,
    this.titulo,
    required this.conteudo,
    this.largura,
    this.acoes,
    this.alinhamentoAcoes = MainAxisAlignment.end,
    this.marcador,
    this.aoFechar,
    this.escCancelaEdicao,
    this.ancora,
  });

  /// Texto (vira título de corpo 20) ou o controle do título.
  final Widget Function(BuildContext)? titulo;
  Widget Function(BuildContext) conteudo;

  /// Largura declarada pelo conteúdo: é ela que dimensiona o cartão.
  final double? largura;
  final String? idLayout;
  List<Widget> Function(BuildContext)? acoes;
  final MainAxisAlignment alinhamentoAcoes;

  /// "confirmar_emissao", "_modal_obrigatorio_", "novo_usuario", "_enter_fecha_"…
  final String? marcador;

  /// Roda UMA vez quando a janela sai da pilha (por botão, Esc ou "X").
  VoidCallback? aoFechar;

  /// 1º tempo do Esc: devolve true se havia uma edição e ela foi cancelada.
  bool Function()? escCancelaEdicao;

  /// Ponto clicado (coordenadas da janela): abre logo abaixo dele, como um menu.
  final Offset? ancora;

  final List<VoidCallback> _aoDescartar = [];
  bool aberto = false;

  static const double larguraPadrao = 520;

  double get larguraFixa => largura ?? larguraPadrao;

  /// Redesenha esta janela.
  void atualizar() {
    if (aberto) notifyListeners();
  }

  /// Campo de texto que morre com a janela.
  TextEditingController texto([String inicial = '']) {
    final c = TextEditingController(text: inicial);
    _aoDescartar.add(c.dispose);
    return c;
  }

  FocusNode foco() {
    final f = FocusNode();
    _aoDescartar.add(f.dispose);
    return f;
  }

  Suspensa suspensa({String? valor, List<Opcao> opcoes = const []}) {
    final s = Suspensa(valor: valor, opcoes: opcoes);
    s.texto = s.textoDe(s.valor);
    _aoDescartar.add(s.dispose);
    return s;
  }

  void aoDescartar(VoidCallback f) => _aoDescartar.add(f);

  void descartar() {
    aberto = false;
    final lista = List<VoidCallback>.of(_aoDescartar);
    _aoDescartar.clear();
    // Depois do quadro que tira a janela da tela: os campos ainda a usam até lá.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final f in lista) {
        try {
          f();
        } catch (_) {}
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }
}

Widget textoTitulo(String t, {FontWeight? peso, Color? cor}) =>
    Tx(t, tam: Letra.titulo, peso: peso, cor: cor);

const double _calha = 16;

/// O cartão: título, conteúdo e a barra de ações, na largura do conteúdo.
class CartaoDialogo extends StatelessWidget {
  const CartaoDialogo(this.dialogo, {super.key});
  final Dialogo dialogo;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: dialogo,
    builder: (context, _) {
      final d = dialogo;
      final id = d.idLayout ?? 'Janela.${d.marcador ?? 'dialogo'}';
      final ajuste = ajusteLayout(context, id);
      final larguraConteudo = ajuste.largura == null
          ? d.larguraFixa
          : (ajuste.largura! - 32).clamp(1.0, 4000.0);
      // A calha da barra de rolagem sai do respiro direito do cartão (24 = 8 + calha): a barra
      // nunca fica por cima do conteúdo, e sem ela a janela é a mesma de sempre.
      Widget comCalha(Widget w) => Padding(
        padding: const EdgeInsets.only(right: _calha),
        child: w,
      );
      final filhos = <Widget>[];
      final t = d.titulo?.call(context);
      if (t != null) {
        filhos.add(
          comCalha(
            t is LinhaTitulo ? SizedBox(width: larguraConteudo, child: t) : t,
          ),
        );
      }
      final c = d.conteudo(context);
      final corpo = comCalha(
        d.largura != null || ajuste.largura != null
            ? SizedBox(width: larguraConteudo, child: c)
            : c,
      );
      // Se a janela não couber na altura da tela, o título e os botões (Salvar, Exportar…)
      // continuam à vista. Conteúdo de altura própria (abas, listas: a rolagem é lá dentro)
      // encolhe junto com a tela; o resto rola inteiro, com a barra na calha.
      final alturaPropria = c is SizedBox && c.height != null;
      filhos.add(
        Flexible(
          child: alturaPropria ? corpo : Rolagem(justa: true, child: corpo),
        ),
      );
      final acoes = d.acoes?.call(context) ?? const <Widget>[];
      if (acoes.isNotEmpty) {
        filhos.add(
          comCalha(
            lin(
              acoes,
              espaco: 8,
              largura: larguraConteudo,
              quebra: true,
              principal: d.alinhamentoAcoes,
              idLayout: 'Grupo.dialogo.lin.2',
            ),
          ),
        );
      }
      final card = ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height - 16,
        ),
        child: SizedBox(
          width: ajuste.largura,
          height: ajuste.altura,
          child: Ct(
            cor: Theme.of(context).colorScheme.surfaceContainerHigh,
            raio: BorderRadius.circular(16),
            padding: const EdgeInsets.fromLTRB(24, 20, 24 - _calha, 16),
            sombra: [
              BoxShadow(
                blurRadius: 28,
                spreadRadius: 2,
                color: Colors.black.withValues(alpha: 0.35),
              ),
            ],
            child: col(filhos, justa: true, espaco: ajuste.espaco ?? 16),
          ),
        ),
      );
      return GrupoLayoutScope(
        id: id,
        child: alvoLayout(
          context,
          card,
          id: id,
          nome: 'Janela / overlay',
          tipo: 'janela',
          grupo: true,
          propriedades: {'espaco': ajuste.espaco ?? 16},
        ),
      );
    },
  );
}
