/// XML guardado no Cofre que não abre (ou sumiu), com a linha da nota ainda no índice: o
/// Baiacu oferece buscar de novo a NFS-e autorizada na SEFIN, pela chave de acesso, e trocar a
/// cópia guardada. A SEFIN entrega a nota ao prestador, ao tomador ou ao intermediário dela.
library;

import 'package:flutter/material.dart';

import '../kit/flet.dart';
import 'app.dart';

/// O erro veio de um XML guardado que não abre? Devolve o id da nota (null = outro erro).
int? notaComXmlIlegivel(Object erro) {
  if (erro is! ErroNucleo) return null;
  final dados = erro.dados;
  if (dados is! Map || dados['xml_ilegivel'] != true) return null;
  final id = dados['nota_id'];
  return id is int ? id : null;
}

/// Busca de novo na SEFIN o XML da nota. true = a cópia do Cofre abre agora.
Future<bool> rebuscarXml(
  App app, {
  required String dono,
  required int notaId,
  required String rotulo,
  bool avisar = true,
}) async {
  if (!await app.autorizarAcao('cofre.rebuscar')) return false;
  final h = avisar ? app.toastProgresso('Buscando na SEFIN o XML da $rotulo…') : null;
  try {
    final r = await chamar<Map>('cofre.rebuscar_xml', {
      'dono': dono,
      'nota_id': notaId,
    });
    final ja = r['resultado'] == 'ja_legivel';
    if (h != null) {
      app.toastFim(
        h,
        ja
            ? 'O XML da $rotulo já abre normalmente.'
            : 'XML da $rotulo buscado na SEFIN e guardado de novo no Cofre.',
      );
    }
    app.notasMudaram();
    return true;
  } catch (e) {
    registrar('Busca do XML na SEFIN falhou ($rotulo): $e', nivel: 'error');
    if (h != null) app.toastFim(h, '$e', erro: true);
    if (!avisar) rethrow;
    return false;
  }
}

/// A janela que explica o problema e oferece a busca. `aoRecuperar` repete o que falhou.
void oferecerRebusca(
  App app, {
  required String dono,
  required int notaId,
  required String rotulo,
  VoidCallback? aoRecuperar,
}) {
  late final Dialogo d;
  var buscando = false;

  Future<void> buscar() async {
    if (buscando) return;
    buscando = true;
    d.atualizar();
    final ok = await rebuscarXml(app, dono: dono, notaId: notaId, rotulo: rotulo);
    if (d.aberto) app.fecharEsta(d);
    if (ok && app.viva) aoRecuperar?.call();
  }

  d = Dialogo(
    titulo: (_) => app.tituloComX('XML não abre no Cofre'),
    largura: 460,
    conteudo: (_) => col(
      [
        Tx(
          'O XML guardado da $rotulo não pôde ser lido. O número e os valores continuam no Cofre.',
          tam: Letra.texto,
          idLayout: 'XmlIlegivel.rotuloProblema',
        ),
        Tx(
          'O Baiacu pode buscar de novo a NFS-e autorizada na SEFIN, pela chave de acesso, e trocar a cópia guardada. Nada é transmitido nem alterado na SEFIN.',
          tam: Letra.apoio,
          cor: Colors.grey.shade700,
          idLayout: 'XmlIlegivel.rotuloExplicacao',
        ),
      ],
      justa: true,
      espaco: 8,
      idLayout: 'Grupo.xml_ilegivel.col.1',
    ),
    acoes: (_) => [
      Botao.texto(
        'Cancelar',
        aoClicar: () => app.fecharEsta(d),
        idLayout: 'XmlIlegivel.botaoCancelar',
      ),
      Botao(
        buscando ? 'Buscando…' : 'Buscar na SEFIN',
        icone: Icons.cloud_download_outlined,
        aoClicar: buscando ? null : buscar,
        idLayout: 'XmlIlegivel.botaoBuscar',
      ),
    ],
    idLayout: 'Janela.xml_ilegivel.Dialogo.1',
  );
  app.mostrarDialogo(d);
}
