/// Grupos de clientes: a janela de gerenciamento (aberta pela tela de Clientes) e as
/// pequenas janelas de adicionar, renomear e remover.
library;

import 'package:flutter/material.dart';

import '../app/app.dart';
import '../kit/campo.dart';
import '../kit/flet.dart';

const grupoMax = 20; // comprimento máximo do nome de um grupo

/// A LISTA ocupa a janela inteira; no rodapé ficam "Adicionar grupo" (esquerda) e "Editar"
/// (direita). Fora do modo de edição tudo fica apagado — só o "Editar" (senha nível 2)
/// destrava; ele some depois de liberar.
void abrirGrupos(App app) {
  if (app.prestador.isEmpty) {
    app.toast('Selecione um prestador.', erro: true);
    return;
  }
  late final Dialogo d;
  var editavel = false;

  void refazer() {
    app.gruposMudaram();
    d.atualizar();
  }

  List<Widget> linhas() {
    final grupos = ja<List>('cadastro.list_grupos', {
      'prestador': app.prestador,
    }).cast<String>();
    final cor = editavel
        ? null
        : Colors.grey.shade500; // fora do modo Editar: apagado
    return [
      for (final g in grupos)
        Ct(
          // respiro à direita: os botões não ficam por baixo da barra de rolagem
          padding: const EdgeInsets.fromLTRB(0, 0, 14, 0),
          child: lin([
            Expanded(
              child: Tx(
                g,
                cor: cor,
                largura: TamanhosGrupos.rotuloG.largura,
                altura: TamanhosGrupos.rotuloG.altura,
                idLayout: 'TamanhosGrupos.rotuloG',
              ),
            ),
            BotaoIcone(
              Icons.edit,
              dica: 'Renomear',
              desabilitado: !editavel,
              cursorTravado: true,
              aoClicar: () => _renomear(app, g, refazer),
              largura: TamanhosGrupos.botaoRenomear.largura,
              altura: TamanhosGrupos.botaoRenomear.altura,
              idLayout: 'TamanhosGrupos.botaoRenomear',
            ),
            BotaoIcone(
              Icons.delete,
              cor: Colors.red.shade400,
              dica: 'Remover',
              desabilitado: !editavel,
              cursorTravado: true,
              aoClicar: () => _remover(app, g, refazer),
              largura: TamanhosGrupos.botaoRemover2.largura,
              altura: TamanhosGrupos.botaoRemover2.altura,
              idLayout: 'TamanhosGrupos.botaoRemover2',
            ),
          ], idLayout: 'Grupo.grupos.lin.1'),
        ),
      if (grupos.isEmpty)
        Tx(
          'Nenhum grupo cadastrado.',
          italico: true,
          cor: Colors.grey.shade600,
          largura: TamanhosGrupos.rotuloNenhumGrupoCadastrado.largura,
          altura: TamanhosGrupos.rotuloNenhumGrupoCadastrado.altura,
          idLayout: 'TamanhosGrupos.rotuloNenhumGrupoCadastrado',
        ),
    ];
  }

  d = Dialogo(
    titulo: (_) => app.tituloComX('Grupos de clientes'),
    largura: 520,
    alinhamentoAcoes: MainAxisAlignment.spaceBetween,
    conteudo: (_) => SizedBox(
      height: 460,
      child: col([
        Tx(
          'Para renomear ou remover grupos, clique em Editar.',
          tam: Letra.apoio,
          cor: Colors.grey.shade700,
          largura: TamanhosGrupos
              .rotuloParaAdicionarRenomearOuRemoverGruposCliqueEm
              .largura,
          altura: TamanhosGrupos
              .rotuloParaAdicionarRenomearOuRemoverGruposCliqueEm
              .altura,
          idLayout: 'TamanhosGrupos.rotuloParaAdicionarRenomearOuRemoverGruposCliqueEm',
        ),
        // Lista EXPANDIDA com rolagem própria; a caixa fica SEM respiro à direita para a
        // barra de rolagem encostar no canto.
        Expanded(
          child: Ct(
            key: const ValueKey('Grupos.lista'),
            largura: double.infinity,
            borda: Border.all(color: Colors.grey.shade300, width: 1),
            raio: BorderRadius.circular(8),
            padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
            child: col(
              linhas(),
              espaco: 4,
              rolar: true,
              idLayout: 'Grupo.grupos.col.2',
            ),
          ),
        ),
      ], idLayout: 'Grupo.grupos.col.1'),
    ),
    acoes: (_) => [
      Botao(
        'Adicionar grupo',
        icone: Icons.add,
        aoClicar: () => _adicionar(app, refazer),
        largura: TamanhosGrupos.botaoAdicionarGrupo.largura,
        altura: TamanhosGrupos.botaoAdicionarGrupo.altura,
        idLayout: 'TamanhosGrupos.botaoAdicionarGrupo',
      ),
      if (!editavel &&
          ja<List>('cadastro.list_grupos', {
            'prestador': app.prestador,
          }).isNotEmpty)
        Botao.contorno(
          'Editar',
          icone: Icons.edit,
          aoClicar: () => app.exigirNivel(2, () {
            editavel = true;
            refazer();
          }, titulo: 'Editar grupos'),
          largura: TamanhosGrupos.botaoEditar.largura,
          altura: TamanhosGrupos.botaoEditar.altura,
          idLayout: 'TamanhosGrupos.botaoEditar',
        ),
    ],
    idLayout: 'Janela.grupos.Dialogo.1',
  );
  // Esc com a edição liberada: a lista volta a travar (aqui nada fica por salvar). O Esc
  // seguinte fecha.
  d.escCancelaEdicao = () {
    if (!editavel) return false;
    editavel = false;
    refazer();
    return true;
  };
  app.mostrarDialogo(d);
}

/// Só o nome e pronto (Enter também salva).
void _adicionar(App app, VoidCallback refazer) {
  late final Dialogo d;
  late final TextEditingController nome;

  void salvar() {
    if (nome.text.trim().isEmpty) {
      app.toast('Informe o nome do grupo.', erro: true);
      return;
    }
    try {
      ja<Object?>('cadastro.add_grupo', {
        'prestador': app.prestador,
        'nome': nome.text,
      });
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    app.fecharDialogo();
    refazer();
    app.toast('Grupo adicionado.');
  }

  d = Dialogo(
    titulo: (_) => textoTitulo('Adicionar grupo'),
    largura: 360,
    conteudo: (_) => col(
      [
        CampoTexto(
          controle: nome,
          rotulo: 'Nome do grupo',
          largura: TamanhosGrupos.campoNomeDoGrupo.largura,
          maximo: grupoMax,
          focoInicial: true,
          aoEnviar: (_) => salvar(),
          altura: TamanhosGrupos.campoNomeDoGrupo.altura,
          idLayout: 'TamanhosGrupos.campoNomeDoGrupo',
        ),
      ],
      justa: true,
      idLayout: 'Grupo.grupos.col.3',
    ),
    acoes: (_) => [
      Botao.texto(
        'Cancelar',
        aoClicar: app.fecharDialogo,
        largura: TamanhosGrupos.botaoCancelar.largura,
        altura: TamanhosGrupos.botaoCancelar.altura,
        idLayout: 'TamanhosGrupos.botaoCancelar',
      ),
      Botao(
        'Adicionar',
        icone: Icons.add,
        aoClicar: salvar,
        largura: TamanhosGrupos.botaoAdicionar.largura,
        altura: TamanhosGrupos.botaoAdicionar.altura,
        idLayout: 'TamanhosGrupos.botaoAdicionar',
      ),
    ],
    idLayout: 'Janela.grupos.Dialogo.2',
  );
  nome = d.texto();
  app.mostrarDialogo(d);
}

void _renomear(App app, String atual, VoidCallback refazer) {
  late final Dialogo d;
  late final TextEditingController nome;
  d = Dialogo(
    titulo: (_) => textoTitulo('Renomear grupo'),
    conteudo: (_) => CampoTexto(
      controle: nome,
      rotulo: 'Novo nome',
      largura: TamanhosGrupos.campoNovoNome.largura,
      maximo: grupoMax,
      altura: TamanhosGrupos.campoNovoNome.altura,
      idLayout: 'TamanhosGrupos.campoNovoNome',
    ),
    acoes: (_) => [
      Botao.texto(
        'Cancelar',
        aoClicar: app.fecharDialogo,
        largura: TamanhosGrupos.botaoCancelar2.largura,
        altura: TamanhosGrupos.botaoCancelar2.altura,
        idLayout: 'TamanhosGrupos.botaoCancelar2',
      ),
      Botao(
        'Salvar',
        aoClicar: () {
          try {
            ja<Object?>('cadastro.rename_grupo', {
              'prestador': app.prestador,
              'antigo': atual,
              'novo': nome.text,
            });
          } catch (e) {
            app.toast('$e', erro: true);
            return;
          }
          app.fecharDialogo();
          refazer();
        },
        largura: TamanhosGrupos.botaoSalvar.largura,
        altura: TamanhosGrupos.botaoSalvar.altura,
        idLayout: 'TamanhosGrupos.botaoSalvar',
      ),
    ],
    idLayout: 'Janela.grupos.Dialogo.3',
  );
  nome = d.texto(atual);
  app.mostrarDialogo(d);
}

void _remover(App app, String nome, VoidCallback refazer) {
  app.mostrarDialogo(
    Dialogo(
      titulo: (_) => textoTitulo('Remover grupo'),
      conteudo: (_) => Tx(
        'Remover o grupo "$nome"? Os clientes desse grupo ficarão sem grupo.',
        largura:
            TamanhosGrupos.rotuloRemoverOGrupoNomeOsClientesDesseGrupo.largura,
        altura:
            TamanhosGrupos.rotuloRemoverOGrupoNomeOsClientesDesseGrupo.altura,
        idLayout: 'TamanhosGrupos.rotuloRemoverOGrupoNomeOsClientesDesseGrupo',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosGrupos.botaoCancelar3.largura,
          altura: TamanhosGrupos.botaoCancelar3.altura,
          idLayout: 'TamanhosGrupos.botaoCancelar3',
        ),
        Botao(
          'Remover',
          aoClicar: () {
            try {
              ja<Object?>('cadastro.remove_grupo', {
                'prestador': app.prestador,
                'nome': nome,
              });
            } catch (e) {
              app.toast('$e', erro: true);
              return;
            }
            app.fecharDialogo();
            refazer();
          },
          largura: TamanhosGrupos.botaoRemover.largura,
          altura: TamanhosGrupos.botaoRemover.altura,
          idLayout: 'TamanhosGrupos.botaoRemover',
        ),
      ],
      idLayout: 'Janela.grupos.Dialogo.4',
    ),
  );
}
