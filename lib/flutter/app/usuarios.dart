/// Gestão de usuários (globais, independem do prestador). A lista é atualizada NO LUGAR,
/// sem fechar/reabrir a janela.
library;

import 'package:flutter/material.dart';

import '../acesso/acesso.dart' show loginMax, mascaraLogin, nomeMax;
import '../kit/campo.dart';
import '../kit/flet.dart';
import 'app.dart';
import 'codigo_autorizacao.dart';
import 'menu_usuario.dart';
import 'permissoes_nivel.dart';

const _porPagina = 25;
const _nomesNivel = {1: 'Nível 1', 2: 'Nível 2', 3: 'Nível 3', 4: 'Nível 4'};

List<Usuario> _listar() => [
  for (final u in jaLista('usuarios.listar')) Usuario.deJson(u),
];

void abrirUsuarios(App app) {
  if (!app.temPermissao('usuarios.listar')) {
    app.exigirPermissao('usuarios.listar', () => abrirUsuarios(app));
    return;
  }
  late final Dialogo d;
  var lista = _listar();
  var pagina = 0;

  void recarregar() {
    lista = _listar();
    d.atualizar();
  }

  void acao(String metodo, String nome, Map<String, Object?> args) {
    final chave = metodo == 'usuarios.definir_ativo'
        ? 'usuarios.ativar'
        : metodo;
    final por = app.autorizadorDaAcao(chave);
    if (por == null) {
      app.exigirPermissao(chave, () => acao(metodo, nome, args));
      return;
    }
    try {
      ja<Object?>(metodo, {...args, 'por': por.paraJson()});
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    registrar('Usuários: $nome executada');
    recarregar();
  }

  Widget linha(Usuario u) {
    final podeGerir = !u.master && u.id != app.usuario.id;
    // Sempre em LINHA ÚNICA: o que estoura vira "…" com o texto completo na dica.
    final login = '${u.ativo ? '● ' : '○ '}${u.login.toUpperCase()}';
    final nome = (u.nome.isEmpty ? '—' : u.nome).toUpperCase();
    return Ct(
      altura: 36,
      alinhar: Alignment.centerLeft,
      // Linha fina embaixo de cada usuário, para separar um do outro.
      borda: Border(bottom: BorderSide(color: Colors.grey.shade300, width: 1)),
      child: lin(
        [
          TxCorte(
            login,
            largura: 190,
            cor: u.ativo ? null : Colors.grey.shade500,
          ),
          TxCorte(nome, largura: 200),
          Ct(
            largura: 78,
            alinhar: Alignment.centerLeft,
            child: chipNivel(u.nivel),
          ),
          Expanded(
            child: podeGerir
                ? IconButtonTheme(
                    data: IconButtonThemeData(
                      style: const ButtonStyle(
                        fixedSize: WidgetStatePropertyAll(Size(32, 32)),
                        minimumSize: WidgetStatePropertyAll(Size(32, 32)),
                        maximumSize: WidgetStatePropertyAll(Size(32, 32)),
                        padding: WidgetStatePropertyAll(EdgeInsets.zero),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    child: lin(
                      [
                        BotaoIcone(
                          Icons.arrow_upward,
                          dica: 'Promover',
                          tamanho: 18,
                          aoClicar: () => acao(
                            'usuarios.promover',
                            'promover',
                            {'usuario_id': u.id},
                          ),
                          largura: TamanhosUsuarios.botaoPromover.largura,
                          altura: TamanhosUsuarios.botaoPromover.altura,
                          idLayout: 'TamanhosUsuarios.botaoPromover',
                        ),
                        BotaoIcone(
                          Icons.arrow_downward,
                          dica: 'Rebaixar',
                          tamanho: 18,
                          aoClicar: () => acao(
                            'usuarios.rebaixar',
                            'rebaixar',
                            {'usuario_id': u.id},
                          ),
                          largura: TamanhosUsuarios.botaoRebaixar.largura,
                          altura: TamanhosUsuarios.botaoRebaixar.altura,
                          idLayout: 'TamanhosUsuarios.botaoRebaixar',
                        ),
                        BotaoIcone(
                          u.ativo ? Icons.toggle_on : Icons.toggle_off,
                          dica: 'Ativar/Desativar',
                          tamanho: 18,
                          aoClicar: () => acao(
                            'usuarios.definir_ativo',
                            'definir_ativo',
                            {'usuario_id': u.id, 'ativo': !u.ativo},
                          ),
                          largura:
                              TamanhosUsuarios.botaoAtivarDesativar.largura,
                          altura: TamanhosUsuarios.botaoAtivarDesativar.altura,
                          idLayout: 'TamanhosUsuarios.botaoAtivarDesativar',
                        ),
                        BotaoIcone(
                          Icons.password,
                          dica: 'Redefinir senha',
                          tamanho: 18,
                          aoClicar: () => _redefinirSenha(app, u, recarregar),
                          largura: TamanhosUsuarios.botaoRedefinirSenha.largura,
                          altura: TamanhosUsuarios.botaoRedefinirSenha.altura,
                          idLayout: 'TamanhosUsuarios.botaoRedefinirSenha',
                        ),
                        BotaoIcone(
                          Icons.pin,
                          dica: 'Redefinir código de autorização',
                          tamanho: 18,
                          aoClicar: () => app.exigirPermissao(
                            'usuarios.senha',
                            () => abrirDefinirCodigo(app, alvo: u),
                          ),
                          largura: TamanhosUsuarios.botaoRedefinirCodigo.largura,
                          altura: TamanhosUsuarios.botaoRedefinirCodigo.altura,
                          idLayout: TamanhosUsuarios.botaoRedefinirCodigo.id,
                        ),
                        BotaoIcone(
                          Icons.storefront,
                          dica: 'Prestadores que pode operar',
                          tamanho: 18,
                          aoClicar: () => gerirPrestadores(app, u),
                          largura: TamanhosUsuarios
                              .botaoPrestadoresQuePodeOperar
                              .largura,
                          altura: TamanhosUsuarios
                              .botaoPrestadoresQuePodeOperar
                              .altura,
                          idLayout:
                              'TamanhosUsuarios.botaoPrestadoresQuePodeOperar',
                        ),
                        BotaoIcone(
                          Icons.delete_forever,
                          cor: Colors.red.shade400,
                          dica: 'Excluir (apagar) usuário',
                          tamanho: 18,
                          aoClicar: () =>
                              _confirmarExclusao(app, u, recarregar),
                          largura: TamanhosUsuarios
                              .botaoExcluirApagarUsuario
                              .largura,
                          altura:
                              TamanhosUsuarios.botaoExcluirApagarUsuario.altura,
                          idLayout:
                              'TamanhosUsuarios.botaoExcluirApagarUsuario',
                        ),
                      ],
                      espaco: 0,
                      principal: MainAxisAlignment.center,
                      idLayout: 'Grupo.usuarios.lin.2:${u.id}',
                    ),
                  )
                : (u.id == app.usuario.id && !u.master)
                ? Center(
                    child: BotaoIcone(
                      Icons.storefront,
                      dica: 'Prestadores que pode operar',
                      tamanho: 18,
                      aoClicar: () => gerirPrestadores(app, u),
                      idLayout:
                          'TamanhosUsuarios.botaoPrestadoresQuePodeOperar:${u.id}:proprio',
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
        espaco: 8,
        idLayout: 'Grupo.usuarios.lin.1:${u.id}',
      ),
    );
  }

  Widget cabecalho(String t, [double? w]) => Tx(
    t,
    largura: TamanhosUsuarios.rotuloT.largura ?? (w),
    tam: Letra.apoio,
    peso: FontWeight.bold,
    cor: Colors.grey.shade700,
    alinhar: t == 'Ações' ? TextAlign.center : TextAlign.start,
    altura: TamanhosUsuarios.rotuloT.altura,
    idLayout: 'TamanhosUsuarios.rotuloT:$t',
  );

  d = Dialogo(
    titulo: (_) => app.tituloComX('Usuários'),
    largura: 742,
    alinhamentoAcoes: MainAxisAlignment.start,
    conteudo: (_) {
      final total = lista.length;
      final paginas = total == 0 ? 1 : ((total + _porPagina - 1) ~/ _porPagina);
      pagina = pagina.clamp(0, paginas - 1);
      final visiveis = lista
          .skip(pagina * _porPagina)
          .take(_porPagina)
          .toList();
      return SizedBox(
        height: 420,
        child: col(
          [
            // Cabeçalho das colunas — larguras espelham as das linhas (235/235/78).
            lin(
              [
                cabecalho('Login', 190),
                cabecalho('Nome', 200),
                cabecalho('Nível', 78),
                Expanded(child: cabecalho('Ações')),
              ],
              espaco: 8,
              idLayout: 'Grupo.usuarios.lin.3',
            ),
            Expanded(
              child: col(
                total == 0
                    ? [
                        Tx(
                          'Nenhum usuário cadastrado ainda.',
                          italico: true,
                          cor: Colors.grey.shade600,
                          largura: TamanhosUsuarios
                              .rotuloNenhumUsuarioCadastradoAinda
                              .largura,
                          altura: TamanhosUsuarios
                              .rotuloNenhumUsuarioCadastradoAinda
                              .altura,
                          idLayout: 'TamanhosUsuarios.rotuloNenhumUsuarioCadastradoAinda',
                        ),
                      ]
                    : [for (final u in visiveis) linha(u)],
                espaco: 2,
                justa: true,
                rolar: true,
                idLayout: 'Grupo.usuarios.col.2',
              ),
            ),
            if (paginas > 1)
              lin(
                [
                  BotaoIcone(
                    Icons.chevron_left,
                    dica: 'Página anterior',
                    desabilitado: pagina <= 0,
                    aoClicar: () {
                      pagina--;
                      d.atualizar();
                    },
                    largura: TamanhosUsuarios.botaoPaginaAnterior.largura,
                    altura: TamanhosUsuarios.botaoPaginaAnterior.altura,
                    idLayout: 'TamanhosUsuarios.botaoPaginaAnterior',
                  ),
                  Tx(
                    'Página ${pagina + 1} de $paginas — $total usuário(s)',
                    tam: Letra.apoio,
                    peso: FontWeight.w600,
                    largura: TamanhosUsuarios
                        .rotuloPaginaPagina1DePaginasTotalUsuarioS
                        .largura,
                    altura: TamanhosUsuarios
                        .rotuloPaginaPagina1DePaginasTotalUsuarioS
                        .altura,
                    idLayout: 'TamanhosUsuarios.rotuloPaginaPagina1DePaginasTotalUsuarioS',
                  ),
                  BotaoIcone(
                    Icons.chevron_right,
                    dica: 'Próxima página',
                    desabilitado: pagina >= paginas - 1,
                    aoClicar: () {
                      pagina++;
                      d.atualizar();
                    },
                    largura: TamanhosUsuarios.botaoProximaPagina.largura,
                    altura: TamanhosUsuarios.botaoProximaPagina.altura,
                    idLayout: 'TamanhosUsuarios.botaoProximaPagina',
                  ),
                ],
                espaco: 4,
                idLayout: 'Grupo.usuarios.lin.4',
              ),
          ],
          espaco: 8,
          idLayout: 'Grupo.usuarios.col.1',
        ),
      );
    },
    acoes: (_) => [
      SizedBox(
        width: 710,
        child: Row(
          children: [
            if (app.usuario.nivel == 4)
              Botao.contorno(
                'Permissões de nível',
                icone: Icons.admin_panel_settings,
                aoClicar: () => abrirPermissoesNivel(app),
                idLayout: 'Usuarios.botaoPermissoesDeNivel',
              ),
            const Spacer(),
            Botao(
              'Adicionar usuário',
              icone: Icons.person_add,
              aoClicar: () => _novoUsuario(app, recarregar),
              idLayout: 'Usuarios.botaoAdicionarUsuario',
            ),
          ],
        ),
      ),
    ],
    idLayout: 'Janela.usuarios.Dialogo.1',
  );
  app.mostrarDialogo(d);
}

void _novoUsuario(App app, VoidCallback recarregar) {
  final por = app.autorizadorDaAcao('usuarios.adicionar');
  if (por == null) {
    app.exigirPermissao(
      'usuarios.adicionar',
      () => _novoUsuario(app, recarregar),
    );
    return;
  }
  final teto = por.nivel - 1;
  final niveis = [
    for (final n in const [1, 2, 3])
      if (n <= teto) n,
  ];
  if (niveis.isEmpty) {
    app.toast('Você não pode cadastrar usuários desse nível.', erro: true);
    return;
  }
  late final Dialogo d;
  late final TextEditingController login, nome, senha, conf;
  late final Suspensa nivel;
  late final ConferenciaCodigo codigo;
  // Multi-seleção dos prestadores que o novo usuário poderá operar.
  final podeVincular = app.temPermissao('usuarios.prestadores');
  final prestadores = podeVincular
      ? jaLista('cadastro.list_prestadores_para_vincular')
      : <Map<String, dynamic>>[];
  final escolhidos = <String>{};

  Future<void> criar() async {
    final msg = ja<String?>('usuarios.validar_credenciais_novas', {
      'login': login.text,
      'senha': senha.text,
      'confirma': conf.text,
      'nome': nome.text,
    });
    if (msg != null && msg.isNotEmpty) {
      app.toast(msg, erro: true);
      return;
    }
    if (!codigo.pronto) {
      app.toast(
        codigo.completo
            ? 'Escolha um código de autorização disponível.'
            : 'Informe o código de autorização: 2 letras ou números.',
        erro: true,
      );
      return;
    }
    final docs = escolhidos.toList()..sort();
    if (docs.isNotEmpty && !await app.autorizarAcao('usuarios.prestadores'))
      return;
    if (!d.aberto) return;
    Usuario novo;
    try {
      novo = Usuario.deJson(
        Map<String, dynamic>.from(
          await chamar<Map>('usuarios.criar', {
            'login': login.text,
            'nome': nome.text,
            'nivel': int.tryParse(nivel.valor ?? '1') ?? 1,
            'senha': senha.text,
            'prestadores': docs,
            'criado_por': por.paraJson(),
            'codigo': codigo.codigo,
          }),
        ),
      );
    } catch (e) {
      // Outra conta pode ter ficado com o código depois da conferência: confere de novo.
      if ('$e'.contains('código')) codigo.recusado();
      app.toast('$e', erro: true);
      return;
    }
    registrar(
      'Usuário criado: #${novo.id} ${novo.login} (nível ${novo.nivel}) '
      'prestadores=[${docs.map((x) => "'$x'").join(', ')}]',
    );
    app.fecharEsta(d);
    recarregar();
    app.toast("Usuário '${novo.login}' criado.");
  }

  d = Dialogo(
    marcador: 'novo_usuario',
    titulo: (_) => app.tituloComX('Adicionar usuário'),
    largura: 620,
    conteudo: (_) => col(
      [
        lin(
          [
            CampoTexto(
              controle: login,
              rotulo: 'Login (só letras)',
              largura: TamanhosUsuarios.campoLoginSoLetras.largura,
              maximo: loginMax,
              focoInicial: true,
              mascara: mascaraLogin,
              altura: TamanhosUsuarios.campoLoginSoLetras.altura,
              idLayout: 'TamanhosUsuarios.campoLoginSoLetras',
            ),
            CampoTexto(
              controle: nome,
              rotulo: 'Nome',
              largura: TamanhosUsuarios.campoNome.largura,
              maximo: nomeMax,
              mascara: (s) => s.toUpperCase(),
              altura: TamanhosUsuarios.campoNome.altura,
              idLayout: 'TamanhosUsuarios.campoNome',
            ),
            ListaSuspensa(
              estado: nivel,
              rotulo: 'Nível',
              largura: TamanhosUsuarios.campoNivel.largura!,
              altura: TamanhosUsuarios.campoNivel.altura,
              idLayout: 'TamanhosUsuarios.campoNivel',
            ),
          ],
          quebra: true,
          cruzado: CrossAxisAlignment.start,
          idLayout: 'Grupo.usuarios.lin.5',
        ),
        lin(
          [
            CampoTexto(
              controle: senha,
              rotulo: 'Senha',
              largura: TamanhosUsuarios.campoSenha.largura,
              senha: true,
              revelarSenha: true,
              altura: TamanhosUsuarios.campoSenha.altura,
              idLayout: 'TamanhosUsuarios.campoSenha',
            ),
            CampoTexto(
              controle: conf,
              rotulo: 'Confirmar',
              largura: TamanhosUsuarios.campoConfirmar.largura,
              senha: true,
              revelarSenha: true,
              altura: TamanhosUsuarios.campoConfirmar.altura,
              idLayout: 'TamanhosUsuarios.campoConfirmar',
            ),
          ],
          quebra: true,
          cruzado: CrossAxisAlignment.start,
          idLayout: 'Grupo.usuarios.lin.6',
        ),
        col(
          [
            codigo.campo(
              idLayout: 'TamanhosUsuarios.campoCodigo',
              largura: TamanhosUsuarios.campoCodigo.largura,
            ),
            codigo.situacao(idLayout: 'Usuarios.novo.situacaoCodigo'),
            Tx(
              explicacaoCodigo,
              tam: Letra.apoio,
              cor: Colors.grey.shade700,
              idLayout: 'Usuarios.novo.rotuloExplicacaoCodigo',
            ),
          ],
          espaco: 4,
          justa: true,
          idLayout: 'Grupo.usuarios.col.codigo',
        ),
        Ct(
          borda: Border.all(color: Colors.grey.shade400, width: 1),
          raio: BorderRadius.circular(8),
          padding: const EdgeInsets.all(8),
          child: col(
            [
              Tx(
                'Prestadores que este usuário pode operar:',
                tam: Letra.apoio,
                cor: Colors.grey.shade700,
                largura: TamanhosUsuarios
                    .rotuloPrestadoresQueEsteUsuarioPodeOperar
                    .largura,
                altura: TamanhosUsuarios
                    .rotuloPrestadoresQueEsteUsuarioPodeOperar
                    .altura,
                idLayout: 'TamanhosUsuarios.rotuloPrestadoresQueEsteUsuarioPodeOperar',
              ),
              if (prestadores.isEmpty)
                Tx(
                  podeVincular
                      ? 'Nenhum prestador cadastrado.'
                      : 'Um usuário autorizado poderá vincular prestadores depois.',
                  italico: true,
                  cor: Colors.orange.shade800,
                  largura: TamanhosUsuarios
                      .rotuloNenhumPrestadorCadastradoCrieUmPrestadorAntes
                      .largura,
                  altura: TamanhosUsuarios
                      .rotuloNenhumPrestadorCadastradoCrieUmPrestadorAntes
                      .altura,
                  idLayout: 'TamanhosUsuarios.rotuloNenhumPrestadorCadastradoCrieUmPrestadorAntes',
                )
              else
                col(
                  [
                    for (final p in prestadores)
                      Marcar(
                        idLayout: 'Checkbox.usuarios.1',
                        valor: escolhidos.contains(p['documento']),
                        rotulo: p['display'] as String,
                        aoMudar: (v) {
                          final doc = p['documento'] as String;
                          if (v == true) {
                            escolhidos.add(doc);
                          } else {
                            escolhidos.remove(doc);
                          }
                          d.atualizar();
                        },
                      ),
                  ],
                  espaco: 0,
                  rolar: true,
                  altura: 120,
                  justa: true,
                  idLayout: 'Grupo.usuarios.col.4',
                ),
            ],
            justa: true,
            espaco: 8,
            idLayout: 'Grupo.usuarios.col.prestadores',
          ),
        ),
      ],
      justa: true,
      espaco: 12,
      rolar: true,
      idLayout: 'Grupo.usuarios.col.3',
    ),
    acoes: (_) => [
      Botao(
        'Adicionar usuário',
        icone: Icons.person_add,
        aoClicar: criar,
        largura: TamanhosUsuarios.botaoAdicionarUsuario2.largura,
        altura: TamanhosUsuarios.botaoAdicionarUsuario2.altura,
        idLayout: 'TamanhosUsuarios.botaoAdicionarUsuario2',
      ),
    ],
    idLayout: 'Janela.usuarios.Dialogo.2',
  );
  login = d.texto();
  nome = d.texto();
  senha = d.texto();
  conf = d.texto();
  codigo = ConferenciaCodigo(controle: d.texto(), aoMudar: d.atualizar);
  nivel = d.suspensa(
    valor: '${niveis.last}',
    opcoes: [for (final n in niveis) Opcao('$n', _nomesNivel[n]!)],
  );
  app.mostrarDialogo(d);
}

/// Ver/adicionar/remover os prestadores que o usuário pode operar, no lugar.
void gerirPrestadores(App app, Usuario alvo) {
  final por = app.autorizadorDaAcao('usuarios.prestadores');
  if (por == null) {
    app.exigirPermissao(
      'usuarios.prestadores',
      () => gerirPrestadores(app, alvo),
    );
    return;
  }
  if (alvo.master) {
    app.toast('O master já opera todos os prestadores.', erro: true);
    return;
  }
  late final Dialogo d;
  final todos = jaLista('cadastro.list_prestadores_para_vincular');
  final nomes = {
    for (final p in todos) p['documento'] as String: p['display'] as String,
  };
  late final Suspensa ddAdd;
  var vinculados = <String>[];
  var permitidos = <String>{};

  void refazer() {
    vinculados = ja<List>('usuarios.prestadores_vinculados', {
      'usuario_id': alvo.id,
    }).cast<String>().toList()..sort();
    permitidos = ja<List>('usuarios.prestadores_permitidos', {
      'usuario': alvo.paraJson(),
    }).cast<String>().toSet();
    ddAdd.opcoes = [
      for (final p in todos)
        if (!permitidos.contains(p['documento']))
          Opcao(p['documento'] as String, p['display'] as String),
    ];
    ddAdd.por(null);
    d.atualizar();
    ddAdd.avisar();
  }

  void vincular(String doc, bool ligar) {
    try {
      ja<Object?>(
        ligar
            ? 'usuarios.vincular_prestador'
            : 'usuarios.desvincular_prestador',
        {'usuario_id': alvo.id, 'prestador': doc, 'por': por.paraJson()},
      );
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    registrar(
      'Prestador ${formatarDocumento(doc)} '
      '${ligar ? 'liberado para o' : 'removido do'} usuário #${alvo.id} ${alvo.login}',
    );
    refazer();
    if (alvo.id == app.usuario.id) {
      app.recarregarPrestadores();
      if (ligar && app.prestador.isEmpty) app.trocarPrestador(doc);
      if (!ligar && app.prestador == doc) {
        app.trocarPrestador(app.ddPrestador.opcoes.firstOrNull?.chave ?? '');
      }
    }
  }

  d = Dialogo(
    titulo: (_) =>
        app.tituloComX("Prestadores de '${alvo.login.toUpperCase()}'"),
    largura: 560,
    conteudo: (_) => SizedBox(
      height: 380,
      child: col(
        [
          Tx(
            'Prestadores que este usuário pode alternar/operar.',
            tam: Letra.apoio,
            cor: Colors.grey.shade600,
            largura: TamanhosUsuarios
                .rotuloPrestadoresQueEsteUsuarioPodeAlternarOperar
                .largura,
            altura: TamanhosUsuarios
                .rotuloPrestadoresQueEsteUsuarioPodeAlternarOperar
                .altura,
            idLayout: 'TamanhosUsuarios.rotuloPrestadoresQueEsteUsuarioPodeAlternarOperar',
          ),
          Expanded(
            child: col(
              [
                for (final doc in vinculados)
                  lin([
                    const Icon(Icons.storefront, size: 16),
                    Expanded(
                      child: Tx(
                        nomes[doc] ?? formatarDocumento(doc),
                        largura: TamanhosUsuarios
                            .rotuloNomesDocFormatarDocumentoDoc
                            .largura,
                        altura: TamanhosUsuarios
                            .rotuloNomesDocFormatarDocumentoDoc
                            .altura,
                        idLayout: 'TamanhosUsuarios.rotuloNomesDocFormatarDocumentoDoc',
                      ),
                    ),
                    BotaoIcone(
                      Icons.link_off,
                      cor: Colors.red.shade400,
                      dica: 'Remover acesso',
                      tamanho: 18,
                      aoClicar: () => vincular(doc, false),
                      largura: TamanhosUsuarios.botaoRemoverAcesso.largura,
                      altura: TamanhosUsuarios.botaoRemoverAcesso.altura,
                      idLayout: 'TamanhosUsuarios.botaoRemoverAcesso',
                    ),
                  ], idLayout: 'Grupo.usuarios.lin.7'),
                if (permitidos.isEmpty)
                  Tx(
                    'Este usuário ainda não opera nenhum prestador.',
                    italico: true,
                    cor: Colors.orange.shade800,
                    largura: TamanhosUsuarios
                        .rotuloEsteUsuarioAindaNaoOperaNenhumPrestador
                        .largura,
                    altura: TamanhosUsuarios
                        .rotuloEsteUsuarioAindaNaoOperaNenhumPrestador
                        .altura,
                    idLayout: 'TamanhosUsuarios.rotuloEsteUsuarioAindaNaoOperaNenhumPrestador',
                  ),
              ],
              espaco: 8,
              justa: true,
              rolar: true,
              idLayout: 'Grupo.usuarios.col.6',
            ),
          ),
          divisor(),
          lin(
            [
              ListaSuspensa(
                estado: ddAdd,
                rotulo: 'Liberar outro prestador',
                largura: 365,
                altura: TamanhosUsuarios.campoLiberarOutroPrestador.altura,
                idLayout: 'TamanhosUsuarios.campoLiberarOutroPrestador',
              ),
              Botao(
                'Liberar',
                icone: Icons.add_link,
                desabilitado: ddAdd.opcoes.isEmpty,
                aoClicar: () {
                  final doc = ddAdd.valor;
                  if (doc == null || doc.isEmpty) {
                    app.toast('Selecione um prestador.', erro: true);
                    return;
                  }
                  vincular(doc, true);
                },
                largura: TamanhosUsuarios.botaoLiberar.largura,
                altura: TamanhosUsuarios.botaoLiberar.altura,
                idLayout: 'TamanhosUsuarios.botaoLiberar',
              ),
            ],
            quebra: true,
            idLayout: 'Grupo.usuarios.lin.8',
          ),
        ],
        justa: true,
        espaco: 8,
        idLayout: 'Grupo.usuarios.col.5',
      ),
    ),
    idLayout: 'Janela.usuarios.Dialogo.3',
  );
  ddAdd = d.suspensa();
  app.mostrarDialogo(d);
  refazer();
}

/// Confirma e EXCLUI (apaga) o usuário — não apenas desativa.
void _confirmarExclusao(App app, Usuario alvo, VoidCallback recarregar) {
  final por = app.autorizadorDaAcao('usuarios.excluir');
  if (por == null) {
    app.exigirPermissao(
      'usuarios.excluir',
      () => _confirmarExclusao(app, alvo, recarregar),
    );
    return;
  }
  void remover() {
    try {
      ja<Object?>('usuarios.excluir', {
        'usuario_id': alvo.id,
        'por': por.paraJson(),
      });
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    registrar(
      'Usuário #${alvo.id} ${alvo.login} EXCLUÍDO (por nível ${por.nivel})',
    );
    app.fecharDialogo(); // fecha SÓ a confirmação
    recarregar(); // a lista (que segue aberta) é atualizada
    app.toast("Usuário '${alvo.login.toUpperCase()}' excluído.");
  }

  app.mostrarDialogo(
    Dialogo(
      titulo: (_) => LinhaTitulo([
        Icon(Icons.warning_amber, color: Colors.red.shade700),
        textoTitulo('Excluir usuário'),
      ], espaco: 10),
      largura: 440,
      conteudo: (_) => col(
        [
          Tx(
            "Apagar DEFINITIVAMENTE o usuário '${alvo.login.toUpperCase()}' "
            '(${alvo.nome.toUpperCase()})?',
            largura: TamanhosUsuarios
                .rotuloApagarDEFINITIVAMENTEOUsuarioAlvoLoginToUpperCaseAlvo
                .largura,
            altura: TamanhosUsuarios
                .rotuloApagarDEFINITIVAMENTEOUsuarioAlvoLoginToUpperCaseAlvo
                .altura,
            idLayout: 'TamanhosUsuarios.rotuloApagarDEFINITIVAMENTEOUsuarioAlvoLoginToUpperCaseAlvo',
          ),
          Tx(
            'Isso remove o usuário do sistema (não é apenas desativar) e não pode ser desfeito.',
            tam: Letra.apoio,
            cor: Colors.grey.shade700,
            largura:
                TamanhosUsuarios.rotuloIssoRemoveOUsuarioDoSistemaNaoE.largura,
            altura:
                TamanhosUsuarios.rotuloIssoRemoveOUsuarioDoSistemaNaoE.altura,
            idLayout: 'TamanhosUsuarios.rotuloIssoRemoveOUsuarioDoSistemaNaoE',
          ),
        ],
        justa: true,
        espaco: 8,
        idLayout: 'Grupo.usuarios.col.7',
      ),
      acoes: (_) => [
        Botao.texto(
          'Cancelar',
          aoClicar: app.fecharDialogo,
          largura: TamanhosUsuarios.botaoCancelar.largura,
          altura: TamanhosUsuarios.botaoCancelar.altura,
          idLayout: 'TamanhosUsuarios.botaoCancelar',
        ),
        Botao(
          'Excluir',
          icone: Icons.delete_forever,
          cor: Colors.white,
          fundo: Colors.red.shade700,
          aoClicar: remover,
          largura: TamanhosUsuarios.botaoExcluir.largura,
          altura: TamanhosUsuarios.botaoExcluir.altura,
          idLayout: 'TamanhosUsuarios.botaoExcluir',
        ),
      ],
      idLayout: 'Janela.usuarios.Dialogo.4',
    ),
  );
}

void _redefinirSenha(App app, Usuario alvo, VoidCallback recarregar) {
  final por = app.autorizadorDaAcao('usuarios.senha');
  if (por == null) {
    app.exigirPermissao(
      'usuarios.senha',
      () => _redefinirSenha(app, alvo, recarregar),
    );
    return;
  }
  late final Dialogo d;
  late final TextEditingController nova;

  Future<void> salvar() async {
    try {
      await chamar<Object?>('usuarios.redefinir_senha', {
        'usuario_id': alvo.id,
        'nova_senha': nova.text,
        'por': por.paraJson(),
      });
    } catch (e) {
      app.toast('$e', erro: true);
      return;
    }
    app.fecharEsta(d); // fecha SÓ este diálogo
    recarregar();
    app.toast('Senha de ${alvo.login.toUpperCase()} redefinida.');
  }

  d = Dialogo(
    titulo: (_) => textoTitulo('Redefinir senha'),
    largura: 360,
    conteudo: (_) => col(
      [
        CampoTexto(
          controle: nova,
          rotulo: 'Nova senha de ${alvo.login.toUpperCase()}',
          largura:
              TamanhosUsuarios.campoNovaSenhaDeAlvoLoginToUpperCase.largura,
          senha: true,
          revelarSenha: true,
          altura: TamanhosUsuarios.campoNovaSenhaDeAlvoLoginToUpperCase.altura,
          idLayout: 'TamanhosUsuarios.campoNovaSenhaDeAlvoLoginToUpperCase',
        ),
      ],
      justa: true,
      idLayout: 'Grupo.usuarios.col.8',
    ),
    acoes: (_) => [
      Botao.texto(
        'Cancelar',
        aoClicar: app.fecharDialogo,
        largura: TamanhosUsuarios.botaoCancelar2.largura,
        altura: TamanhosUsuarios.botaoCancelar2.altura,
        idLayout: 'TamanhosUsuarios.botaoCancelar2',
      ),
      Botao(
        'Salvar',
        icone: Icons.save,
        aoClicar: salvar,
        largura: TamanhosUsuarios.botaoSalvar.largura,
        altura: TamanhosUsuarios.botaoSalvar.altura,
        idLayout: 'TamanhosUsuarios.botaoSalvar',
      ),
    ],
    idLayout: 'Janela.usuarios.Dialogo.5',
  );
  nova = d.texto();
  app.mostrarDialogo(d);
}
