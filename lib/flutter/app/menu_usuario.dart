/// O usuário logado no topo (foto, nome, etiqueta do nível) e a janela "Menu": foto de
/// perfil (enquadrar: arrastar + zoom) e redefinição da própria senha.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../kit/arquivos.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';
import 'app.dart';

/// Etiqueta do nível com a COR do nível (1 dourado, 2 laranja, 3 vermelho, 4 roxo).
Widget chipNivel(int nivel, [String? texto]) => Ct(
  cor: corDoNivel(nivel),
  raio: BorderRadius.circular(10),
  padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
  child: Tx(
    texto ?? 'Nível $nivel',
    tam: Letra.apoio,
    cor: Colors.white,
    peso: FontWeight.w600,
    largura: TamanhosMenuUsuario.rotuloTextoNivelNivel.largura,
    altura: TamanhosMenuUsuario.rotuloTextoNivelNivel.altura,
    idLayout: 'TamanhosMenuUsuario.rotuloTextoNivelNivel',
  ),
);

/// Cursor de mãozinha SEM roubar clique/hover do controle de baixo.
Widget maozinha(Widget conteudo, {bool ativo = true}) => Stack(
  clipBehavior: Clip.hardEdge,
  children: [
    conteudo,
    Positioned.fill(
      child: PonteiroTransparente(
        child: Gesto(
          cursor: ativo ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: Container(),
        ),
      ),
    ),
  ],
);

class MenuUsuario extends StatelessWidget {
  const MenuUsuario({super.key, required this.app});
  final App app;

  Widget _avatar() {
    final foto = app.foto;
    if (foto == null) return const Icon(Icons.account_circle, size: 40);
    return Ct(
      largura: 40,
      altura: 40,
      raio: BorderRadius.circular(20),
      recorte: Clip.antiAlias,
      child: Image.memory(
        foto,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nome = app.usuario.nome.isEmpty ? '—' : app.usuario.nome;
    final menu = comDica(
      'Menu',
      TooltipVisibility(
        visible: false,
        child: PopupMenuButton<String>(
          enabled: !travado(context),
          tooltip: null,
          padding: const EdgeInsets.all(8),
          clipBehavior: Clip.none,
          onSelected: (_) {},
          onCanceled: () {},
          onOpened: () {},
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              value: 'menu',
              height: 48,
              mouseCursor: SystemMouseCursors.click,
              onTap: () => abrirMenuUsuario(app),
              child: Tx(
                'Menu',
                largura: TamanhosMenuUsuario.rotuloMenu.largura,
                altura: TamanhosMenuUsuario.rotuloMenu.altura,
                idLayout: 'TamanhosMenuUsuario.rotuloMenu',
              ),
            ),
            PopupMenuItem<String>(
              value: 'sair',
              height: 48,
              mouseCursor: SystemMouseCursors.click,
              onTap: app.sair,
              child: Tx(
                'Sair',
                largura: TamanhosMenuUsuario.rotuloSair.largura,
                altura: TamanhosMenuUsuario.rotuloSair.altura,
                idLayout: 'TamanhosMenuUsuario.rotuloSair',
              ),
            ),
          ],
          // O respiro faz o realce do hover passar um pouco da foto e do nome.
          child: maozinha(
            ativo: !travado(context),
            Ct(
              padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
              child: lin(
                [
                  ValueListenableBuilder<int>(
                    valueListenable: app.tiqueCasca,
                    builder: (context, _, _) =>
                        Ct(alinhar: Alignment.center, child: _avatar()),
                  ),
                  Tx(
                    nome.toUpperCase(),
                    peso: FontWeight.w600,
                    largura: TamanhosMenuUsuario.rotuloNomeToUpperCase.largura,
                    altura: TamanhosMenuUsuario.rotuloNomeToUpperCase.altura,
                    idLayout: 'TamanhosMenuUsuario.rotuloNomeToUpperCase',
                  ),
                ],
                espaco: 8,
                justa: true,
                idLayout: 'Grupo.menu_usuario.lin.1',
              ),
            ),
          ),
        ),
      ),
    );
    // Um cartão transparente dá ao realce do hover uma superfície de cantos redondos.
    final realce = Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      clipBehavior: Clip.antiAlias,
      semanticContainer: true,
      borderOnForeground: true,
      child: menu,
    );
    // Só foto + nome abrem o menu; a etiqueta do nível fica ao lado, afastada e inerte.
    return lin(
      [realce, chipNivel(app.usuario.nivel)],
      espaco: 6,
      justa: true,
      idLayout: 'Grupo.menu_usuario.lin.2',
    );
  }
}

// --------------------------------------------------------------------------- //
// Janela "Menu": foto de perfil + redefinir senha
// --------------------------------------------------------------------------- //
const _fotoView = 260.0; // diâmetro do círculo de enquadramento
const _fotoSaida = 256; // lado (px) da foto recortada que vai ao banco
const _fotoZoomMax = 4.0;
const _fotoMaxArqMb = 100; // tamanho máximo do ARQUIVO escolhido

/// Decodifica a imagem já com a orientação correta e o maior lado limitado.
Future<ui.Image> _abrirImagem(Uint8List dados, {int maxLado = 1600}) async {
  return _imagemDoBuffer(
    await ui.ImmutableBuffer.fromUint8List(dados),
    maxLado,
  );
}

Future<ui.Image> _abrirImagemArquivo(String caminho) async =>
    _imagemDoBuffer(await ui.ImmutableBuffer.fromFilePath(caminho), 1600);

Future<ui.Image> _imagemDoBuffer(ui.ImmutableBuffer buffer, int maxLado) async {
  ui.Codec? codec;
  ui.ImageDescriptor? descricao;
  try {
    descricao = await ui.ImageDescriptor.encoded(buffer);
    final fator = math.min(
      1.0,
      maxLado / math.max(descricao.width, descricao.height),
    );
    codec = await descricao.instantiateCodec(
      targetWidth: math.max(1, (descricao.width * fator).round()),
      targetHeight: math.max(1, (descricao.height * fator).round()),
    );
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descricao?.dispose();
    buffer.dispose();
  }
}

/// O QUADRADO visível no círculo, sobre fundo branco, em [saida]×[saida], como RGBA.
Future<Uint8List> _recortar(
  ui.Image im,
  double ox,
  double oy,
  double zoom,
  double viewport,
  int saida,
) async {
  final (w, h) = (im.width.toDouble(), im.height.toDouble());
  final s = (viewport / math.min(w, h)) * zoom;
  final lado = viewport / s;
  final x0 = math.max(0.0, math.min(-ox / s, w - lado));
  final y0 = math.max(0.0, math.min(-oy / s, h - lado));
  final origem = Rect.fromLTRB(
    x0.roundToDouble(),
    y0.roundToDouble(),
    (x0 + lado).roundToDouble(),
    (y0 + lado).roundToDouble(),
  );
  final destino = Rect.fromLTWH(0, 0, saida.toDouble(), saida.toDouble());
  final gravador = ui.PictureRecorder();
  final tela = Canvas(gravador, destino);
  tela.drawRect(destino, Paint()..color = const Color(0xFFFFFFFF));
  tela.drawImageRect(
    im,
    origem,
    destino,
    Paint()..filterQuality = FilterQuality.high,
  );
  final figura = gravador.endRecording();
  final pronto = await figura.toImage(saida, saida);
  figura.dispose();
  final bytes = await pronto.toByteData(format: ui.ImageByteFormat.rawRgba);
  pronto.dispose();
  return bytes!.buffer.asUint8List();
}

void abrirMenuUsuario(App app) {
  const v = _fotoView;
  late final Dialogo d;
  ui.Image? img;
  var (ox, oy, zoom) = (0.0, 0.0, 1.0);
  var (px, py, ox0, oy0) = (0.0, 0.0, 0.0, 0.0);
  var (oxI, oyI) = (0.0, 0.0);
  var arrastando = false;
  var remover = false;
  // nova: imagem escolhida agora (ainda não salva).
  var nova = false;
  var pairando = false;
  var carregandoFoto = false;
  var aba = 0;
  var textoHover = 'Alterar foto';
  var temFotoSalva = false;
  var mostrarRemover = false;
  try {
    temFotoSalva =
        ja<String?>('usuarios.get_foto', {'usuario_id': app.usuario.id}) !=
        null;
  } catch (_) {}
  mostrarRemover = temFotoSalva;

  double w() => img?.width.toDouble() ?? 0;
  double h() => img?.height.toDouble() ?? 0;
  double escala() => img == null ? 1.0 : (v / math.min(w(), h())) * zoom;

  void limitar() {
    final s = escala();
    ox = math.min(0.0, math.max(v - w() * s, ox));
    oy = math.min(0.0, math.max(v - h() * s, oy));
  }

  /// Há o que salvar? Foto nova, remoção marcada ou a foto salva re-enquadrada.
  bool mudou() {
    if (nova || remover) return true;
    return img != null &&
        ((zoom - 1.0).abs() > 1e-3 ||
            (ox - oxI).abs() > 0.5 ||
            (oy - oyI).abs() > 0.5);
  }

  /// A foto em ajuste aceita apenas arrasto; o seletor volta depois de salvar.
  String convite() {
    if (img == null) return 'Escolher foto';
    return mudou() ? '' : 'Alterar foto';
  }

  Future<void> carregar(
    Future<ui.Image> decodificar, {
    bool salva = false,
  }) async {
    ui.Image nova_;
    try {
      nova_ = await decodificar;
    } catch (e) {
      app.toast('Não foi possível abrir a imagem: $e', erro: true);
      return;
    }
    if (!app.dialogoAberto(d)) {
      nova_.dispose();
      return;
    }
    img?.dispose();
    img = nova_;
    zoom = 1.0;
    remover = false;
    nova = !salva;
    final s = escala();
    ox = (v - w() * s) / 2; // começa centralizada
    oy = (v - h() * s) / 2;
    oxI = ox;
    oyI = oy;
    pairando = false; // o mouse costuma estar em cima ao voltar do seletor
    mostrarRemover = temFotoSalva;
    d.atualizar();
  }

  Future<void> selecionarImagem() async {
    String? caminho;
    try {
      caminho = await escolherArquivo(
        titulo: 'Escolher foto de perfil',
        extensoes: const ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
      );
    } catch (e) {
      app.toast('Não foi possível abrir o diálogo: $e', erro: true);
      return;
    }
    if (caminho == null || caminho.isEmpty) return;
    try {
      final arquivo = File(caminho);
      if (await arquivo.length() > _fotoMaxArqMb * 1024 * 1024) {
        app.toast(
          'Imagem muito grande — o máximo é $_fotoMaxArqMb MB.',
          erro: true,
        );
        return;
      }
      await carregar(_abrirImagemArquivo(caminho));
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
  }

  Future<void> escolher() async {
    if (carregandoFoto) return;
    carregandoFoto = true;
    pairando = false;
    d.atualizar();
    try {
      await selecionarImagem();
    } finally {
      carregandoFoto = false;
      d.atualizar();
    }
  }

  Future<void> salvar() async {
    String msg;
    try {
      final imagem = img;
      if (imagem != null) {
        final rgba = await _recortar(imagem, ox, oy, zoom, v, _fotoSaida);
        ja<Object?>('usuarios.set_foto_rgba', {
          'usuario_id': app.usuario.id,
          'largura': _fotoSaida,
          'altura': _fotoSaida,
          'rgba': base64Encode(rgba),
        });
        msg = 'Foto de perfil atualizada.';
      } else if (remover) {
        ja<Object?>('usuarios.set_foto', {
          'usuario_id': app.usuario.id,
          'dados': null,
        });
        msg = 'Foto de perfil removida.';
      } else {
        return;
      }
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    app.carregarFoto();
    app.atualizar();
    app.fecharDialogo();
    registrar(
      '${msg.replaceFirst(RegExp(r'\.$'), '')} (usuário ${app.usuario.login})',
    );
    app.toast(msg);
  }

  // Remoção NÃO é imediata: limpa o editor e marca a intenção — só o "Salvar" aplica.
  void marcarRemocao() {
    img?.dispose();
    img = null;
    zoom = 1.0;
    remover = true;
    nova = false;
    pairando = false;
    mostrarRemover = false;
    d.atualizar();
  }

  void aoZoom(double z) {
    if (img == null) return;
    // Zoom em torno do CENTRO do círculo: o ponto central continua o mesmo.
    final sAntigo = escala();
    final cx = (v / 2 - ox) / sAntigo;
    final cy = (v / 2 - oy) / sAntigo;
    zoom = math.max(1.0, math.min(_fotoZoomMax, z));
    final sNovo = escala();
    ox = v / 2 - cx * sNovo;
    oy = v / 2 - cy * sNovo;
    limitar();
    d.atualizar();
  }

  late final TextEditingController fAtual, fNova, fConf;

  Future<void> salvarSenha() async {
    if (fNova.text != fConf.text) {
      app.toast('As senhas não conferem.', erro: true);
      return;
    }
    try {
      await chamar<Object?>('usuarios.trocar_propria_senha', {
        'usuario': app.usuario.paraJson(),
        'senha_atual': fAtual.text,
        'nova_senha': fNova.text,
      });
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    app.fecharDialogo();
    registrar('Senha alterada pelo próprio usuário ${app.usuario.login}');
    app.toast('Senha alterada.');
  }

  Widget painel(Widget conteudo) => Ct(
    padding: const EdgeInsets.fromLTRB(8, 16, 12, 4),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 392),
      child: conteudo,
    ),
  );

  Widget abaFoto() {
    final imagem = img;
    final s = escala();
    final textoConvite = convite();
    if (textoConvite.isNotEmpty) textoHover = textoConvite;
    final editando = imagem != null && mudou();
    final hover = pairando && !arrastando;
    final comZoom = nova;
    final circulo = Ct(
      largura: v,
      altura: v,
      raio: BorderRadius.circular(v / 2),
      cor: Colors.grey.shade200,
      recorte: Clip.antiAlias,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          if (imagem == null)
            Positioned.fill(
              child: Ct(
                alinhar: Alignment.center,
                child: col(
                  [
                    Icon(
                      Icons.account_circle,
                      size: 72,
                      color: Colors.grey.shade400,
                    ),
                    Tx(
                      'Clique para escolher uma imagem',
                      tam: Letra.apoio,
                      cor: Colors.grey.shade600,
                      largura: TamanhosMenuUsuario
                          .rotuloCliqueParaEscolherUmaImagem
                          .largura,
                      altura: TamanhosMenuUsuario
                          .rotuloCliqueParaEscolherUmaImagem
                          .altura,
                      idLayout: 'TamanhosMenuUsuario.rotuloCliqueParaEscolherUmaImagem',
                    ),
                  ],
                  espaco: 6,
                  justa: true,
                  cruzado: CrossAxisAlignment.center,
                  idLayout: 'Grupo.menu_usuario.col.1',
                ),
              ),
            ),
          Positioned(
            left: ox,
            top: oy,
            child: Container(
              child: imagem == null
                  ? null
                  : RawImage(
                      image: imagem,
                      width: w() * s,
                      height: h() * s,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.medium,
                    ),
            ),
          ),
          if (hover)
            Positioned.fill(
              child: ClipRect(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: editando ? 0.6 : 6,
                    sigmaY: editando ? 0.6 : 6,
                    tileMode: TileMode.clamp,
                  ),
                  child: Ct(
                    cor: Colors.black.withValues(alpha: editando ? 0.02 : 0.28),
                    alinhar: Alignment.center,
                    child: editando
                        ? null
                        : Tx(
                            textoHover,
                            tam: Letra.texto,
                            cor: Colors.white,
                            peso: FontWeight.w600,
                            largura:
                                TamanhosMenuUsuario.rotuloTextoHover.largura,
                            altura: TamanhosMenuUsuario.rotuloTextoHover.altura,
                            idLayout: 'TamanhosMenuUsuario.rotuloTextoHover',
                          ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    final gesto = Gesto(
      cursor: carregandoFoto
          ? SystemMouseCursors.progress
          // Windows não tem grab/grabbing nativos; click usa a mão do sistema.
          : Platform.isWindows
          ? SystemMouseCursors.click
          : arrastando
          ? SystemMouseCursors.grabbing
          : editando
          ? SystemMouseCursors.grab
          : SystemMouseCursors.click,
      aoEntrar: () {
        if (arrastando) return;
        pairando = true;
        d.atualizar();
      },
      aoSair: () {
        pairando = false;
        d.atualizar();
      },
      aoTocar: editando || carregandoFoto ? null : escolher,
      aoArrastarInicio: (e) {
        arrastando = true;
        pairando = false; // foto NÍTIDA enquanto posiciona
        px = e.globalPosition.dx;
        py = e.globalPosition.dy;
        ox0 = ox;
        oy0 = oy;
        d.atualizar();
      },
      aoArrastar: (e) {
        if (img == null) return;
        ox = ox0 + (e.globalPosition.dx - px);
        oy = oy0 + (e.globalPosition.dy - py);
        limitar();
        d.atualizar();
      },
      aoArrastarFim: (_) {
        arrastando = false;
        d.atualizar(); // moveu a foto salva: agora há o que salvar
      },
      child: circulo,
    );
    final blocoZoom = col(
      [
        lin(
          [
            Icon(Icons.zoom_out, size: 18, color: Colors.grey.shade600),
            Expanded(
              child: Container(
                child: Slider(
                  autofocus: false,
                  value: zoom.clamp(1.0, _fotoZoomMax),
                  min: 1.0,
                  max: _fotoZoomMax,
                  onChanged: comZoom ? aoZoom : null,
                  onChangeStart: comZoom ? (_) {} : null,
                  onChangeEnd: comZoom ? (_) {} : null,
                ),
              ),
            ),
            Icon(Icons.zoom_in, size: 18, color: Colors.grey.shade600),
          ],
          espaco: 4,
          idLayout: 'Grupo.menu_usuario.lin.3',
        ),
        Tx(
          'Arraste a imagem para posicionar; use o zoom para aproximar.',
          tam: Letra.apoio,
          cor: Colors.grey.shade700,
          largura: TamanhosMenuUsuario
              .rotuloArrasteAImagemParaPosicionarUseOZoom
              .largura,
          altura: TamanhosMenuUsuario
              .rotuloArrasteAImagemParaPosicionarUseOZoom
              .altura,
          idLayout:
              'TamanhosMenuUsuario.rotuloArrasteAImagemParaPosicionarUseOZoom',
        ),
      ],
      justa: true,
      idLayout: 'Grupo.menu_usuario.col.2',
    );
    return col(
      [
        lin(
          [gesto],
          principal: MainAxisAlignment.center,
          idLayout: 'Grupo.menu_usuario.lin.4',
        ),
        Visibility(
          visible: comZoom,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: blocoZoom,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: lin([
            const Expanded(child: SizedBox()),
            if (mostrarRemover)
              Botao.texto(
                null,
                filho: Tx(
                  'Remover foto',
                  cor: Colors.red.shade700,
                  largura: TamanhosMenuUsuario.rotuloRemoverFoto.largura,
                  altura: TamanhosMenuUsuario.rotuloRemoverFoto.altura,
                  idLayout: 'TamanhosMenuUsuario.rotuloRemoverFoto',
                ),
                aoClicar: marcarRemocao,
                largura: TamanhosMenuUsuario.botaoNull.largura,
                altura: TamanhosMenuUsuario.botaoNull.altura,
                idLayout: 'TamanhosMenuUsuario.botaoNull',
              ),
            // "Salvar" só existe quando há o que salvar.
            if (mudou())
              Botao(
                'Salvar',
                icone: Icons.check,
                aoClicar: salvar,
                largura: TamanhosMenuUsuario.botaoSalvar.largura,
                altura: TamanhosMenuUsuario.botaoSalvar.altura,
                idLayout: 'TamanhosMenuUsuario.botaoSalvar',
              ),
          ], idLayout: 'Grupo.menu_usuario.lin.5'),
        ),
      ],
      justa: true,
      idLayout: 'Grupo.menu_usuario.col.3',
    );
  }

  Widget abaSenha() => col(
    [
      col([
        CampoTexto(
          controle: fAtual,
          rotulo: 'Senha atual',
          largura: TamanhosMenuUsuario.campoSenhaAtual.largura,
          senha: true,
          revelarSenha: true,
          altura: TamanhosMenuUsuario.campoSenhaAtual.altura,
          idLayout: 'TamanhosMenuUsuario.campoSenhaAtual',
        ),
        CampoTexto(
          controle: fNova,
          rotulo: 'Nova senha',
          largura: TamanhosMenuUsuario.campoNovaSenha.largura,
          senha: true,
          revelarSenha: true,
          altura: TamanhosMenuUsuario.campoNovaSenha.altura,
          idLayout: 'TamanhosMenuUsuario.campoNovaSenha',
        ),
        CampoTexto(
          controle: fConf,
          rotulo: 'Confirmar nova senha',
          largura: TamanhosMenuUsuario.campoConfirmarNovaSenha.largura,
          senha: true,
          revelarSenha: true,
          altura: TamanhosMenuUsuario.campoConfirmarNovaSenha.altura,
          idLayout: 'TamanhosMenuUsuario.campoConfirmarNovaSenha',
        ),
      ], justa: true),
      lin([
        const Expanded(child: SizedBox()),
        Botao(
          'Salvar',
          icone: Icons.save,
          aoClicar: salvarSenha,
          largura: TamanhosMenuUsuario.botaoSalvar2.largura,
          altura: TamanhosMenuUsuario.botaoSalvar2.altura,
          idLayout: 'TamanhosMenuUsuario.botaoSalvar2',
        ),
      ], idLayout: 'Grupo.menu_usuario.lin.6'),
    ],
    justa: true,
    principal: MainAxisAlignment.spaceBetween,
    idLayout: 'Grupo.menu_usuario.col.4',
  );

  d = Dialogo(
    titulo: (_) => app.tituloComX('Menu'),
    largura: 420,
    conteudo: (_) => DefaultTabController(
      length: 2,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerHeight: 0,
            onTap: (i) {
              aba = i;
              d.atualizar();
            },
            tabs: const [
              Tab(text: 'Foto de perfil', icon: Icon(Icons.account_circle)),
              Tab(text: 'Redefinir senha', icon: Icon(Icons.lock_reset)),
            ],
          ),
          divisor(altura: 1),
          painel(aba == 0 ? abaFoto() : abaSenha()),
        ],
      ),
    ),
    idLayout: 'Janela.menu_usuario.Dialogo.1',
  );
  fAtual = d.texto();
  fNova = d.texto();
  fConf = d.texto();
  d.aoDescartar(() => img?.dispose());
  app.mostrarDialogo(d);

  // Foto atual (se houver) já entra carregada para re-enquadrar.
  if (temFotoSalva) {
    try {
      final b = ja<String?>('usuarios.get_foto', {
        'usuario_id': app.usuario.id,
      });
      if (b != null && b.isNotEmpty)
        carregar(_abrirImagem(base64Decode(b)), salva: true);
    } catch (_) {}
  }
}
