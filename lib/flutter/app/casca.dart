/// A casca do programa: três camadas FIXAS — telas, janelas e avisos do rodapé — e, na
/// camada das telas, o topo (prestador, usuários, registros, menu do usuário), a faixa do
/// ambiente, o trilho lateral e a tela à vista.
library;

import 'package:flutter/material.dart';

import '../kit/flet.dart';
import '../tema.dart';
import '../telas/cliente_form.dart' show aquecerMunicipios;
import '../telas/cofre.dart';
import '../telas/clientes.dart';
import '../telas/config.dart';
import '../telas/consultar.dart';
import '../telas/emitir.dart';
import 'ajuda.dart';
import 'app.dart';
import 'atualizacao.dart';
import 'menu_usuario.dart';
import 'prestador_novo.dart';
import 'registros.dart';
import 'usuarios.dart';

class Casca extends StatefulWidget {
  const Casca({super.key, required this.app});
  final App app;

  @override
  State<Casca> createState() => _CascaState();
}

class _CascaState extends State<Casca> {
  App get app => widget.app;

  // As telas nascem uma vez e ficam montadas: a navegação só alterna a que está à vista.
  late final Widget _telas = _Telas(app: app);
  late bool _semAnterior;

  void _acessoMudou() {
    if (!mounted || _semAnterior == app.semPrestador) return;
    setState(() => _semAnterior = app.semPrestador);
    if (!_semAnterior) {
      aquecerCatalogos(context);
      aquecerMunicipios();
    }
  }

  @override
  void initState() {
    super.initState();
    _semAnterior = app.semPrestador;
    app.tiqueCasca.addListener(_acessoMudou);
    // Com o programa já na tela e parado: o que as listas grandes (catálogos de serviço,
    // municípios) precisam ter pronto é preparado de antemão, aos poucos.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Versão nova: no máximo uma consulta por dia, sem nunca atrapalhar a entrada.
      app.agendar(
        const Duration(seconds: 8),
        () => procurarAtualizacao(app, automatica: true),
      );
      if (app.semPrestador) return;
      chamar<Object?>('pdf.aquecer_danfse').catchError((Object _) => null);
      chamar<Object?>('emissao.aquecer').catchError((Object _) => null);
      aquecerCatalogos(context);
      aquecerMunicipios();
    });
  }

  @override
  void dispose() {
    app.tiqueCasca.removeListener(_acessoMudou);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camadaApp = app.semPrestador ? _semPrestador() : _comPrestador();
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        // O fundo geral é um elemento próprio, sem filhos.
        Positioned.fill(
          child: ValueListenableBuilder<String?>(
            valueListenable: app.fundoPrevia,
            builder: (context, previa, _) =>
                Ct(cor: corHex(previa ?? aparenciaAtual.fundo)),
          ),
        ),
        Positioned.fill(
          child: ValueListenableBuilder<int>(
            valueListenable: app.tiqueDialogos,
            // Com janela aberta, nada do programa de trás recebe foco nem clique.
            builder: (context, _, filho) => ExcludeFocus(
              excluding: app.dialogos.isNotEmpty,
              child: Travar(se: app.dialogos.isNotEmpty, child: filho!),
            ),
            child: Container(child: camadaApp),
          ),
        ),
        Positioned.fill(child: _CamadaDialogos(app: app)),
        Positioned(left: 14, right: 14, bottom: 14, child: _Avisos(app: app)),
      ],
    );
  }

  Widget _topo(List<Widget> filhos) => Ct(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
    child: lin(filhos, idLayout: 'Grupo.casca.lin.1'),
  );

  Widget _semPrestador() => col(
    [
      _topo([const Expanded(child: SizedBox()), MenuUsuario(app: app)]),
      Expanded(
        child: Ct(
          alinhar: Alignment.center,
          child: col(
            [
              Icon(
                Icons.storefront_outlined,
                size: 72,
                color: Colors.grey.shade400,
              ),
              Tx(
                'Nenhum prestador liberado para este usuário',
                tam: Letra.titulo,
                peso: FontWeight.bold,
                alinhar: TextAlign.center,
                largura: TamanhosNavegacao
                    .rotuloNenhumPrestadorLiberadoParaEsteUsuario
                    .largura,
                altura: TamanhosNavegacao
                    .rotuloNenhumPrestadorLiberadoParaEsteUsuario
                    .altura,
                idLayout: 'TamanhosNavegacao.rotuloNenhumPrestadorLiberadoParaEsteUsuario',
              ),
              Tx(
                app.pode(3) ? 'Libere os prestadores que deseja operar.' : 'Para operar, peça a um usuário de nível 3 para liberar um prestador para você.',
                tam: Letra.texto,
                cor: Colors.grey.shade700,
                alinhar: TextAlign.center,
                largura: TamanhosNavegacao
                    .rotuloParaOperarPecaAUmUsuarioDeNivel
                    .largura,
                altura: TamanhosNavegacao
                    .rotuloParaOperarPecaAUmUsuarioDeNivel
                    .altura,
                idLayout:
                    'TamanhosNavegacao.rotuloParaOperarPecaAUmUsuarioDeNivel',
              ),
              if (app.pode(3))
                Botao(
                  'Liberar prestadores',
                  icone: Icons.add_link,
                  aoClicar: () =>
                      gerirPrestadores(app, app.usuario, app.usuario),
                ),
            ],
            cruzado: CrossAxisAlignment.center,
            espaco: 12,
            justa: true,
            idLayout: 'Grupo.casca.col.2',
          ),
        ),
      ),
    ],
    espaco: 0,
    idLayout: 'Grupo.casca.col.1',
  );

  Widget _comPrestador() => col(
    [
      _topo([
        ListenableBuilder(
          listenable: app.tiqueCasca,
          builder: (context, _) => ListaSuspensa(
            estado: app.ddPrestador,
            rotulo: 'Prestador',
            largura: TamanhosNavegacao.campoPrestador.largura!,
            desabilitado: app.ddPrestadorTravado,
            aoSelecionar: app.aoEscolherPrestador,
            altura: TamanhosNavegacao.campoPrestador.altura,
            idLayout: 'TamanhosNavegacao.campoPrestador',
          ),
        ),
        // Ícones visíveis a todos; o acesso é protegido por senha de nível 3.
        BotaoIcone(
          Icons.add_business,
          dica: 'Adicionar prestador',
          aoClicar: () => app.exigirNivel(
            3,
            () => abrirNovoPrestador(app),
            titulo: 'Adicionar prestador',
          ),
          largura: TamanhosNavegacao.botaoAdicionarPrestador.largura,
          altura: TamanhosNavegacao.botaoAdicionarPrestador.altura,
          idLayout: 'TamanhosNavegacao.botaoAdicionarPrestador',
        ),
        BotaoIcone(
          Icons.group,
          dica: 'Usuários',
          aoClicar: () =>
              app.exigirNivel(3, () => abrirUsuarios(app), titulo: 'Usuários'),
          largura: TamanhosNavegacao.botaoUsuarios.largura,
          altura: TamanhosNavegacao.botaoUsuarios.altura,
          idLayout: 'TamanhosNavegacao.botaoUsuarios',
        ),
        const Expanded(child: SizedBox()),
        BotaoAtualizacao(app: app),
        BotaoRegistros(app: app),
        MenuUsuario(app: app),
      ]),
      ValueListenableBuilder<int>(
        valueListenable: app.tiqueCasca,
        builder: (context, _, _) => _faixaAmbiente(),
      ),
      Expanded(
        child: lin(
          [
            _Trilho(app: app),
            divisorVertical(largura: 1),
            Expanded(
              child: Ct(padding: const EdgeInsets.all(20), child: _telas),
            ),
          ],
          cruzado: CrossAxisAlignment.start,
          idLayout: 'Grupo.casca.lin.2',
        ),
      ),
    ],
    espaco: 0,
    idLayout: 'Grupo.casca.col.3',
  );

  Widget _faixaAmbiente() {
    final producao = app.ambiente == ambProducao;
    return Ct(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      cor: producao ? Colors.green.shade700 : Colors.red.shade700,
      child: lin([
        Icon(
          producao ? Icons.verified : Icons.science_outlined,
          color: Colors.white,
        ),
        Tx(
          'AMBIENTE: ${producao ? 'PRODUÇÃO' : 'HOMOLOGAÇÃO'}',
          tam: Letra.subtitulo,
          peso: FontWeight.bold,
          cor: Colors.white,
          largura: TamanhosNavegacao
              .rotuloAMBIENTEProducaoPRODUCAOHOMOLOGACAO
              .largura,
          altura: TamanhosNavegacao
              .rotuloAMBIENTEProducaoPRODUCAOHOMOLOGACAO
              .altura,
          idLayout:
              'TamanhosNavegacao.rotuloAMBIENTEProducaoPRODUCAOHOMOLOGACAO',
        ),
      ], idLayout: 'Grupo.casca.lin.3'),
    );
  }
}

/// As cinco telas, todas montadas; só a da vez aparece, recebe foco e anima.
class _Telas extends StatelessWidget {
  const _Telas({required this.app});
  final App app;

  @override
  Widget build(BuildContext context) {
    final telas = <Widget>[
      TelaEmitir(app: app),
      TelaClientes(app: app),
      TelaConsultar(app: app),
      TelaConfig(app: app),
      TelaCofre(app: app),
    ];
    return ValueListenableBuilder<int>(
      valueListenable: app.tiqueCasca,
      builder: (context, _, _) => Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 0; i < telas.length; i++)
            Offstage(
              offstage: app.navAtual != i,
              child: TickerMode(
                enabled: app.navAtual == i,
                child: ExcludeFocus(
                  excluding: app.navAtual != i,
                  child: TravaDaVez(aVista: app.navAtual == i, child: telas[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------- //
// Trilho lateral
// --------------------------------------------------------------------------- //
class _Trilho extends StatefulWidget {
  const _Trilho({required this.app});
  final App app;

  @override
  State<_Trilho> createState() => _TrilhoState();
}

class _TrilhoState extends State<_Trilho> {
  // Medidas do trilho com rótulo sempre visível: respiro de 8 em cima; cada destino =
  // pílula de 32 + 4 + rótulo de 16 + 12 = 64.
  static const _topo = 8.0;
  static const _destinoH = 64.0;
  static const _alinhamentoGrupo = -0.9;

  /// Qual botão do rodapé do trilho está sob o mouse ('config', 'ajuda' ou nenhum).
  String _pairando = '';

  App get app => widget.app;

  /// Os botões do rodapé do trilho: Configurações e, abaixo, Ajuda.
  Widget _rodape(BuildContext context) => col(
    [
      _botaoRodape(
        context,
        id: 'config',
        selecionado: app.navAtual == 3,
        icone: Icons.settings_outlined,
        iconeSel: Icons.settings,
        rotulo: 'Configurações',
        tamanho: TamanhosNavegacao.rotuloConfiguracoes,
        aoTocar: () => app.irPara(3),
      ),
      _botaoRodape(
        context,
        id: 'ajuda',
        selecionado: false,
        icone: Icons.help_outline,
        iconeSel: Icons.help,
        rotulo: 'Ajuda',
        tamanho: TamanhosNavegacao.rotuloAjuda,
        aoTocar: () => abrirAjuda(app),
      ),
    ],
    espaco: 0,
    cruzado: CrossAxisAlignment.center,
    idLayout: 'Grupo.casca.col.rodape',
  );

  Widget _botaoRodape(
    BuildContext context, {
    required String id,
    required bool selecionado,
    required IconData icone,
    required IconData iconeSel,
    required String rotulo,
    required Tamanho tamanho,
    required VoidCallback aoTocar,
  }) {
    final esquema = Theme.of(context).colorScheme;
    final Color? fundo = selecionado
        ? esquema.secondaryContainer
        : (_pairando == id ? comOpacidade(Colors.indigo, 0.10) : null);
    return Gesto(
      cursor: SystemMouseCursors.click,
      aoTocar: aoTocar,
      aoEntrar: () => setState(() => _pairando = id),
      aoSair: () => setState(() {
        if (_pairando == id) _pairando = '';
      }),
      child: Ct(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
        child: col(
          [
            Ct(
              largura: 56,
              altura: 32,
              raio: BorderRadius.circular(16),
              alinhar: Alignment.center,
              cor: fundo,
              child: Icon(
                selecionado ? iconeSel : icone,
                size: 24,
                color: selecionado
                    ? esquema.onSecondaryContainer
                    : esquema.onSurfaceVariant,
              ),
            ),
            const Ct(altura: 4),
            // Rótulo em onSurface nos dois estados, como os destinos.
            Tx(
              rotulo,
              tema: (t) => t.labelMedium,
              cor: esquema.onSurface,
              semQuebra: true,
              largura: tamanho.largura,
              altura: tamanho.altura,
              idLayout: tamanho.id,
            ),
            const Ct(altura: 12),
          ],
          espaco: 0,
          justa: true,
          cruzado: CrossAxisAlignment.center,
          idLayout: 'Grupo.casca.col.4.$id',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: app.tiqueCasca,
    builder: (context, _, _) {
      const destinos = [
        (Icons.receipt_long_outlined, Icons.receipt_long, 'Emitir'),
        (Icons.people_outline, Icons.people, 'Clientes'),
        (Icons.search, Icons.manage_search, 'Consultar'),
        (Icons.lock_outlined, Icons.lock, 'Cofre'),
      ];
      // Sem prestador ativo (instalação nova, ou o último foi excluído) não há o que emitir,
      // cadastrar, consultar nem sincronizar: os quatro destinos ficam apagados e só as
      // Configurações (Personalização e Avançado › Backup) continuam disponíveis.
      final semAtivo = app.prestador.isEmpty;
      final parado = travado(context) || semAtivo;
      // Tema ESCOPADO do trilho: primary translúcido vira a cor de hover dos destinos.
      final trilho = Theme(
        data: temaTrilho(),
        child: Builder(
          builder: (context) => LayoutBuilder(
            builder: (context, _) => NavigationRail(
              labelType: NavigationRailLabelType.all,
              extended: false,
              minWidth: 92,
              groupAlignment: _alinhamentoGrupo,
              backgroundColor: Colors.transparent,
              leadingAtTop: true,
              trailing: _rodape(context),
              trailingAtBottom: true,
              scrollable: false,
              selectedIndex: semAtivo ? null : App.navTrilho[app.navAtual],
              onDestinationSelected: parado
                  ? null
                  : (i) => app.irPara(App.trilhoNav[i]),
              destinations: [
                for (final (icone, iconeSel, rotulo) in destinos)
                  NavigationRailDestination(
                    disabled: parado,
                    icon: Icon(icone),
                    selectedIcon: Icon(iconeSel),
                    label: Text(rotulo),
                  ),
              ],
            ),
          ),
        ),
      );
      // MÃOZINHA só sobre os botões: uma camada do tamanho exato do grupo de destinos,
      // posicionada pela mesma conta do trilho, que possui o cursor e deixa os cliques e
      // o hover atravessarem.
      return Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Container(child: trilho),
          Positioned.fill(
            child: PonteiroTransparente(
              child: col(
                [
                  const Ct(altura: _topo),
                  Expanded(
                    child: Ct(
                      alinhar: const Alignment(0, _alinhamentoGrupo),
                      child: Gesto(
                        cursor: semAtivo
                            ? SystemMouseCursors.basic
                            : SystemMouseCursors.click,
                        child: Ct(altura: destinos.length * _destinoH),
                      ),
                    ),
                  ),
                  // O rodapé: Configurações e Ajuda.
                  const Ct(altura: _destinoH * 2),
                ],
                espaco: 0,
                idLayout: 'Grupo.casca.col.5',
              ),
            ),
          ),
        ],
      );
    },
  );
}

// --------------------------------------------------------------------------- //
// Janelas e avisos
// --------------------------------------------------------------------------- //
class _CamadaDialogos extends StatelessWidget {
  const _CamadaDialogos({required this.app});
  final App app;

  static const _alturaEstimadaAncorado = 470.0;

  Widget _entrada(BuildContext context, Dialogo d, bool topo) {
    Widget corpo;
    final ancora = d.ancora;
    if (ancora == null) {
      // Véu MODAL: absorve o clique fora do cartão, com a seta normal do mouse.
      corpo = Gesto(
        cursor: SystemMouseCursors.basic,
        aoTocar: () {},
        child: Ct(
          cor: Colors.black.withValues(alpha: 0.45),
          alinhar: Alignment.center,
          child: CartaoDialogo(d),
        ),
      );
    } else {
      // Janela ancorada (transitória): abre logo abaixo do ponto clicado, véu leve, e o
      // clique fora FECHA — comportamento de menu.
      final tamanho = MediaQuery.sizeOf(context);
      final largura = d.larguraFixa + 48;
      final x = (ancora.dx - 24).clamp(
        8.0,
        (tamanho.width - largura - 8).clamp(8.0, double.infinity),
      );
      final y = (ancora.dy + 18).clamp(
        8.0,
        (tamanho.height - _alturaEstimadaAncorado).clamp(8.0, double.infinity),
      );
      corpo = Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(
            child: Gesto(
              cursor: SystemMouseCursors.basic,
              aoTocar: app.fecharDialogo,
              child: Ct(cor: Colors.black.withValues(alpha: 0.10)),
            ),
          ),
          Positioned(left: x, top: y, child: CartaoDialogo(d)),
        ],
      );
    }
    // Foco preso na janela do TOPO: as de baixo ficam inertes.
    return Positioned.fill(
      key: ObjectKey(d),
      child: ExcludeFocus(
        excluding: !topo,
        child: Travar(
          se: !topo,
          child: FocusScope(autofocus: true, child: Container(child: corpo)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: app.tiqueDialogos,
    builder: (context, _, _) {
      if (app.dialogos.isEmpty) return const SizedBox.shrink();
      return Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (final d in app.dialogos)
            _entrada(context, d, d == app.dialogos.last),
        ],
      );
    },
  );
}

class _Avisos extends StatelessWidget {
  const _Avisos({required this.app});
  final App app;

  Widget _barra(Aviso a) => Gesto(
    key: ObjectKey(a),
    cursor: SystemMouseCursors.click,
    // Clicar no aviso fecha na hora; o registro continua no histórico.
    aoTocar: () => app.expirarAviso(a),
    child: Ct(
      cor: a.erro
          ? Colors.red.shade700
          : a.aviso
          ? corAviso
          : Colors.grey.shade900,
      raio: BorderRadius.circular(8),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: lin([
        if (a.progresso)
          anel(tamanho: 16, traco: 2, cor: Colors.white)
        else if (a.feito && !a.erro)
          const Icon(Icons.check_circle_outline, color: Colors.white, size: 18)
        else if (a.erro)
          const Icon(Icons.error_outline, color: Colors.white, size: 18)
        else if (a.aviso)
          const Icon(Icons.info_outline, color: Colors.white, size: 18),
        Expanded(
          child: Tx(
            a.msg,
            cor: Colors.white,
            largura: TamanhosNavegacao.rotuloAMsg.largura,
            altura: TamanhosNavegacao.rotuloAMsg.altura,
            idLayout: 'TamanhosNavegacao.rotuloAMsg',
          ),
        ),
      ], idLayout: 'Grupo.casca.lin.4'),
    ),
  );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: app.tiqueAvisos,
    builder: (context, _, _) => col(
      [for (final a in app.avisos) _barra(a)],
      espaco: 6,
      justa: true,
      idLayout: 'Grupo.casca.col.6',
    ),
  );
}
