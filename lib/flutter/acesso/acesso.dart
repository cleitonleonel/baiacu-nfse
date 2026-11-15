/// Telas de ACESSO: login, primeiro acesso (cria o master e mostra a senha mestra), recriação
/// do arquivo de chaves e redefinição do master pela senha mestra.
///
/// Antes de alguém se autenticar o banco cifrado não revela nada — nem se há usuários. O que
/// decide a tela é o ARQUIVO: ainda não existe (primeiro acesso) ou existe.
library;

import 'package:flutter/material.dart';

import '../editor_layout.dart';

import 'package:flutter/services.dart';

import '../estilo.dart';
import '../kit/basico.dart';
import '../kit/campo.dart';
import '../nucleo.dart';
import '../tema.dart';

/// Usuário autenticado (o que o núcleo devolve no login).
class Usuario {
  const Usuario({
    required this.id,
    required this.login,
    required this.nome,
    required this.nivel,
    required this.ativo,
  });

  factory Usuario.deJson(Map<String, dynamic> j) => Usuario(
    id: j['id'] as int,
    login: j['login'] as String,
    nome: j['nome'] as String,
    nivel: j['nivel'] as int,
    ativo: j['ativo'] as bool,
  );

  final int id;
  final String login;
  final String nome;
  final int nivel;
  final bool ativo;

  static const nivelMaster = 4;
  bool get master => nivel >= nivelMaster;
  String get nivelNome => 'Nível $nivel';

  Map<String, Object?> paraJson() => {
    'id': id,
    'login': login,
    'nome': nome,
    'nivel': nivel,
    'ativo': ativo,
  };
}

const loginMax = 20; // comprimento máximo do login
const nomeMax = 20; // comprimento máximo do nome
const politicaSenha =
    'A senha deve ter no mínimo 8 caracteres, com letra maiúscula, letra minúscula, '
    'número e caractere especial.';

const _textoSenhaMestra =
    'Com ela e o arquivo dados.db abre-se o banco inteiro em qualquer '
    'computador e redefine-se o usuário master. Sem ela, se as senhas dos '
    'usuários forem esquecidas, os dados do banco não podem ser recuperados.';

// Cores da marca nas telas de acesso (as mesmas da capa do manual e da página do projeto).
const _corLaranja = Color(0xFFF97316);

void _registrar(String nivel, String msg) {
  Nucleo.chamar<Object?>('registro.registrar', {
    'nome': 'gui',
    'nivel': nivel,
    'msg': msg,
  });
}

/// Só letras ASCII, em maiúsculas, até [loginMax] (o campo de login enquanto se digita).
String mascaraLogin(String t) {
  final b = StringBuffer();
  for (final c in t.runes) {
    final letra = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
    if (letra) b.writeCharCode(c);
  }
  final s = b.toString().toUpperCase();
  return s.length > loginMax ? s.substring(0, loginMax) : s;
}

enum _Tela {
  carregando,
  primeiroAcesso,
  recuperarChaves,
  login,
  redefinirMaster,
  senhaMestra,
}

/// Decide e mostra a tela de acesso; chama [aoEntrar] com o usuário autenticado.
class TelaAcesso extends StatefulWidget {
  const TelaAcesso({super.key, required this.aoEntrar, this.aoPreparar});

  final ValueChanged<Usuario> aoEntrar;
  final VoidCallback? aoPreparar;

  @override
  State<TelaAcesso> createState() => _TelaAcessoState();
}

class _TelaAcessoState extends State<TelaAcesso> {
  _Tela _tela = _Tela.carregando;
  // Primeiro acesso concluído: a senha mestra recém-gerada e o master criado.
  String _senhaMestra = '';
  Usuario? _novoMaster;
  Widget? _cartaoDeTras;

  @override
  void initState() {
    super.initState();
    _decidir();
  }

  Future<void> _decidir() async {
    final estado = await Nucleo.chamar<String>('banco.estado');
    _Tela tela;
    if (estado == 'novo') {
      tela = _Tela.primeiroAcesso;
    } else if (!await Nucleo.chamar<bool>('banco.destrancado') &&
        !await Nucleo.chamar<bool>('chaves.arquivo_integro')) {
      tela = _Tela.recuperarChaves;
    } else {
      tela = _Tela.login;
    }
    if (!mounted) return;
    setState(() => _tela = tela);
    final confirmar = widget.aoPreparar;
    if (confirmar != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) confirmar();
      });
    }
  }

  void _ir(_Tela tela) => setState(() => _tela = tela);

  @override
  Widget build(BuildContext context) {
    final Widget conteudo = switch (_tela) {
      _Tela.carregando => const SizedBox.shrink(),
      _Tela.login => _Login(
        aoEntrar: widget.aoEntrar,
        aoRedefinir: () => _ir(_Tela.redefinirMaster),
      ),
      _Tela.primeiroAcesso => _PrimeiroAcesso(
        aoCriar: (usuario, senhaMestra, cartao) {
          setState(() {
            _novoMaster = usuario;
            _senhaMestra = senhaMestra;
            _cartaoDeTras = cartao;
            _tela = _Tela.senhaMestra;
          });
        },
      ),
      _Tela.recuperarChaves => _RecuperarChaves(
        aoContinuar: () => _ir(_Tela.login),
      ),
      _Tela.redefinirMaster => _RedefinirMaster(
        aoVoltar: () => _ir(_Tela.login),
      ),
      _Tela.senhaMestra => _PopupSenhaMestra(
        senha: _senhaMestra,
        fundo: _cartaoDeTras!,
        aoConcluir: () => widget.aoEntrar(_novoMaster!),
      ),
    };
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        const Positioned.fill(child: _FundoAcesso()),
        KeyedSubtree(key: ValueKey(_tela), child: conteudo),
      ],
    );
  }
}

/// Ocupa a página inteira e centraliza o cartão nos dois eixos.
Widget _centro(Widget cartao) =>
    Container(alignment: Alignment.center, child: cartao);

/// Fundo limpo das telas de acesso: degradê suave na cor do tema e dois círculos bem claros
/// nos cantos, sem textura.
class _FundoAcesso extends StatelessWidget {
  const _FundoAcesso();

  @override
  Widget build(BuildContext context) {
    final cor = Theme.of(context).colorScheme.primary;
    Widget bola(double tamanho, double opacidade) => Container(
      width: tamanho,
      height: tamanho,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: comOpacidade(cor, opacidade),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFFFBFBFE),
            Color.lerp(Colors.white, cor, 0.07)!,
          ],
        ),
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(right: -160, top: -160, child: bola(460, 0.06)),
          Positioned(left: -120, bottom: -140, child: bola(340, 0.05)),
        ],
      ),
    );
  }
}

/// Preferência da animação do baiacu no login ("0" = desligada; padrão: ligada). Vale para o
/// computador, como as outras de Personalização.
const metaAnimacaoLogin = 'ui.animacao_login';

/// Centro do corpo redondo do baiacu, em fração da imagem (impresso por
/// extras/baiacu/separar_espinhos.py, que separa as camadas). Os espinhos crescem a partir dele.
const _centroCorpo = Alignment(0.5773 * 2 - 1, 0.5144 * 2 - 1);

/// O baiacu solto, sem moldura. Com [espinhos] (0 a 1), desenha as duas camadas: os espinhos
/// saem para fora conforme o valor e o corpo estufa um pouco.
class _MarcaBaiacu extends StatelessWidget {
  const _MarcaBaiacu({this.tamanho = 132, this.espinhos});

  final double tamanho;
  final Animation<double>? espinhos;

  Widget _imagem(String nome) => Image.asset(
    'assets/images/$nome.png',
    width: tamanho,
    height: tamanho,
    filterQuality: FilterQuality.medium,
    gaplessPlayback: true,
  );

  @override
  Widget build(BuildContext context) {
    final t = espinhos;
    if (t == null) return _imagem('puffer');
    final inteiro = _imagem('puffer');
    final corpo = _imagem('puffer_corpo');
    final pontas = _imagem('puffer_espinhos');
    // Parado, a imagem original (as bordas cortadas das duas camadas, sobrepostas, deixariam um
    // fio mais claro na base dos espinhos); as camadas só durante a animação.
    return AnimatedBuilder(
      animation: t,
      builder: (context, _) => t.value == 0 ? inteiro : Stack(
        clipBehavior: Clip.none,
        children: [
          Transform.scale(
            scale: 1 + 0.05 * t.value,
            alignment: _centroCorpo,
            child: corpo,
          ),
          Transform.scale(
            scale: 1 + 0.17 * t.value,
            alignment: _centroCorpo,
            child: pontas,
          ),
        ],
      ),
    );
  }
}

/// "Baiacu NFS-e", com o NFS-e em laranja.
Widget _tituloMarca(BuildContext context) => Text.rich(
  TextSpan(
    children: [
      TextSpan(
        text: 'Baiacu ',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
      ),
      const TextSpan(text: 'NFS-e', style: TextStyle(color: _corLaranja)),
    ],
  ),
  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
);

Widget _cartao({
  required double largura,
  required double espaco,
  required List<Widget> itens,
  bool marca = true,
}) {
  return Container(
    width: largura,
    padding: const EdgeInsets.fromLTRB(32, 28, 32, 30),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE8E8F0)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x14000000),
          blurRadius: 32,
          offset: Offset(0, 12),
        ),
      ],
    ),
    child: Builder(
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        spacing: espaco,
        children: [
          if (marca) const _MarcaBaiacu(tamanho: 88),
          ...itensVisiveisLayout(context, itens),
        ],
      ),
    ),
  );
}

// ------------------------------------------------------------------------------------- //
// Login
// ------------------------------------------------------------------------------------- //
class _Login extends StatefulWidget {
  const _Login({required this.aoEntrar, required this.aoRedefinir});

  final ValueChanged<Usuario> aoEntrar;
  final VoidCallback aoRedefinir;

  @override
  State<_Login> createState() => _LoginState();
}

class _LoginState extends State<_Login> with SingleTickerProviderStateMixin {
  final _login = TextEditingController();
  // Login certo: os espinhos saem e voltam (0,7 s) antes de abrir o programa.
  late final _baiacu = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final Animation<double> _espinhos = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 40,
    ),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 10),
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeInOutCubic)),
      weight: 50,
    ),
  ]).animate(_baiacu);
  final _senha = TextEditingController();
  final _focoSenha = FocusNode();
  String _erro = '';
  bool _entrando = false;

  @override
  void dispose() {
    _login.dispose();
    _senha.dispose();
    _focoSenha.dispose();
    _baiacu.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // As duas camadas já carregadas: a troca do desenho não pisca na hora da animação.
    precacheImage(const AssetImage('assets/images/puffer_corpo.png'), context);
    precacheImage(const AssetImage('assets/images/puffer_espinhos.png'), context);
  }

  /// Os espinhos saem e voltam. Pula se a animação foi desligada em Configurações ›
  /// Personalização, ou se o Windows pede menos animação.
  Future<void> _comemorar() async {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    try {
      final v = await Nucleo.chamar<String>('banco.get_meta', {
        'chave': metaAnimacaoLogin,
      });
      if (v == '0' || !mounted) return;
    } catch (_) {
      // Sem a preferência gravada: anima (é o padrão).
    }
    try {
      await _baiacu.forward(from: 0).orCancel;
    } on TickerCanceled {
      // A tela saiu antes do fim: segue o login.
    }
  }

  Future<void> _entrar() async {
    if (_entrando) return;
    _entrando = true;
    try {
      final r = await Nucleo.chamar<Map<String, dynamic>?>('usuarios.entrar', {
        'login': _login.text,
        'senha': _senha.text,
      });
      if (!mounted) return;
      if (r == null) {
        _registrar(
          'warning',
          "Tentativa de login falhou para '${_login.text}'",
        );
        setState(() {
          _erro = 'Usuário ou senha inválidos.';
          _senha.text = '';
        });
        _focoSenha.requestFocus(); // volta o foco ao campo de senha
        return;
      }
      final u = Usuario.deJson(r);
      await Nucleo.chamar<Object?>('registro.definir_usuario', {
        'operador_id': u.id,
      });
      _registrar(
        'info',
        "Login: #${u.id} ${u.login} '${u.nome}' (nível ${u.nivel})",
      );
      setState(() => _erro = '');
      await _comemorar();
      if (!mounted) return;
      widget.aoEntrar(u);
    } finally {
      _entrando = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cartao = _cartao(
      largura: 400,
      espaco: 14,
      marca: false,
      itens: [
        _MarcaBaiacu(espinhos: _espinhos),
        Builder(builder: _tituloMarca),
        texto(
          'Entre com seu usuário e senha.',
          cor: Colors.grey[600],
          idLayout: 'Acesso.texto2',
        ),
        const SizedBox(height: 2),
        CampoTexto(
          controle: _login,
          mascara: (s) => s.toUpperCase(),
          rotulo: 'Usuário',
          largura: TamanhosAcesso.campoUsuario.largura,
          focoInicial: true,
          altura: TamanhosAcesso.campoUsuario.altura,
          idLayout: 'TamanhosAcesso.campoUsuario',
        ),
        CampoTexto(
          controle: _senha,
          rotulo: 'Senha',
          largura: TamanhosAcesso.campoSenha.largura,
          senha: true,
          revelarSenha: true,
          foco: _focoSenha,
          aoEnviar: (_) => _entrar(),
          altura: TamanhosAcesso.campoSenha.altura,
          idLayout: 'TamanhosAcesso.campoSenha',
        ),
        texto(_erro, cor: Colors.red[600], idLayout: 'Acesso.texto3'),
        // mais alto que o padrão (~40): botão encorpado
        BotaoInflavel(
          rotulo: 'Entrar',
          icone: Icons.login,
          aoApertar: _entrar,
          largura: TamanhosAcesso.botaoGeral.largura,
          altura: TamanhosAcesso.botaoGeral.altura,
          idLayout: 'TamanhosAcesso.botaoGeral',
        ),
      ],
    );
    // Recuperação de acesso FORA do cartão, no canto INFERIOR ESQUERDO da tela: redefine
    // senha/login/nome do MASTER mediante a SENHA MESTRA.
    final redefinir = ElementoLayoutGenerico(
      width: TamanhosAcesso.botaoAcao.largura,
      height: TamanhosAcesso.botaoAcao.altura,
      child: TextButton(
        onPressed: widget.aoRedefinir,
        onLongPress: () {},
        onHover: (_) {},
        clipBehavior: Clip.none,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            const Icon(Icons.key, size: 16),
            texto(
              'Redefinir usuário master (senha mestra)',
              tamanho: Letra.apoio,
              idLayout: 'Acesso.texto4',
            ),
          ],
        ),
      ),
      idLayout: 'TamanhosAcesso.botaoAcao',
    );
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        _centro(cartao),
        Positioned(left: 16, bottom: 16, child: redefinir),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------- //
// Arquivo de chaves sumiu ou está corrompido
// ------------------------------------------------------------------------------------- //
/// Aberta SOZINHA quando o dados.key sumiu ou está corrompido: sem ele nenhuma senha de usuário
/// abre o banco, então a SENHA MESTRA abre o dados.db e o arquivo é refeito a partir da cópia
/// guardada dentro dele — todos voltam a entrar com as senhas de sempre.
class _RecuperarChaves extends StatefulWidget {
  const _RecuperarChaves({required this.aoContinuar});

  final VoidCallback aoContinuar;

  @override
  State<_RecuperarChaves> createState() => _RecuperarChavesState();
}

class _RecuperarChavesState extends State<_RecuperarChaves> {
  final _mestra = TextEditingController();
  String _erro = '';

  @override
  void dispose() {
    _mestra.dispose();
    super.dispose();
  }

  Future<void> _aplicar() async {
    final abriu = await Nucleo.chamar<bool>('chaves.destrancar_com_mestra', {
      'senha': _mestra.text,
    });
    if (!mounted) return;
    if (!abriu) {
      _registrar('warning', 'Recriação do dados.key: senha mestra incorreta.');
      setState(() => _erro = 'Senha mestra incorreta.');
      return;
    }
    await Nucleo.chamar<Object?>(
      'banco.trancar',
    ); // o banco só fica aberto depois do login
    _registrar(
      'warning',
      'dados.key recriado a partir do banco com a senha mestra.',
    );
    widget.aoContinuar();
  }

  @override
  Widget build(BuildContext context) {
    return _centro(
      _cartao(
        largura: 430,
        espaco: 12,
        itens: [
          texto(
            'Arquivo de chaves',
            tamanho: Letra.titulo,
            peso: FontWeight.bold,
            idLayout: 'Acesso.texto5',
          ),
          texto(
            'O arquivo de chaves (dados.key) não foi encontrado ou está corrompido. '
            'Digite a SENHA MESTRA para o sistema recriá-lo a partir do banco. Os '
            'usuários continuam com as mesmas senhas.',
            cor: Colors.grey[700],
            idLayout: 'Acesso.texto6',
          ),
          texto(
            'Os traços (-) da senha mestra são opcionais e maiúsculas/minúsculas não importam.',
            tamanho: Letra.apoio,
            cor: Colors.grey[600],
            idLayout: 'Acesso.texto7',
          ),
          CampoTexto(
            controle: _mestra,
            rotulo: 'Senha mestra',
            largura: TamanhosAcesso.campoSenhaMestra.largura,
            focoInicial: true,
            senha: true,
            revelarSenha: true,
            aoEnviar: (_) => _aplicar(),
            altura: TamanhosAcesso.campoSenhaMestra.altura,
            idLayout: 'TamanhosAcesso.campoSenhaMestra',
          ),
          texto(_erro, cor: Colors.red[600], idLayout: 'Acesso.texto8'),
          SizedBox(
            width: 360,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 10,
              children: [
                BotaoInflavel(
                  rotulo: 'Recriar chaves',
                  icone: Icons.key,
                  aoApertar: _aplicar,
                  largura: TamanhosAcesso.botaoGeral2.largura,
                  altura: TamanhosAcesso.botaoGeral2.altura,
                  idLayout: 'TamanhosAcesso.botaoGeral2',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------------------------- //
// Redefinir o master com a senha mestra
// ------------------------------------------------------------------------------------- //
/// Redefine SENHA (e, se informados, LOGIN e NOME) do usuário MASTER mediante a SENHA MESTRA,
/// que abre o banco sem ninguém logado — é o caminho de resgate do sistema.
class _RedefinirMaster extends StatefulWidget {
  const _RedefinirMaster({required this.aoVoltar});

  final VoidCallback aoVoltar;

  @override
  State<_RedefinirMaster> createState() => _RedefinirMasterState();
}

class _RedefinirMasterState extends State<_RedefinirMaster> {
  final _mestra = TextEditingController();
  final _login = TextEditingController();
  final _nome = TextEditingController();
  final _senha = TextEditingController();
  final _confirma = TextEditingController();
  String _erro = '';

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_tecla);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_tecla);
    for (final c in [_mestra, _login, _nome, _senha, _confirma]) {
      c.dispose();
    }
    super.dispose();
  }

  // Esc = "Voltar".
  bool _tecla(KeyEvent e) {
    if (editorLayoutAtivo) return false;
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
      widget.aoVoltar();
    }
    return false;
  }

  Future<void> _aplicar() async {
    final politica = await Nucleo.chamar<String>('usuarios.validar_senha', {
      'senha': _senha.text,
    });
    String erro = '';
    if (politica.isNotEmpty) {
      erro = politica;
    } else if (_senha.text != _confirma.text) {
      erro = 'As senhas não conferem.';
    } else if (!await Nucleo.chamar<bool>('chaves.destrancar_com_mestra', {
      'senha': _mestra.text,
    })) {
      _registrar('warning', 'Redefinição do master: senha mestra incorreta.');
      erro = 'Senha mestra incorreta.';
    } else {
      try {
        final u = await Nucleo.chamar<Map<String, dynamic>>(
          'usuarios.redefinir_senha_master',
          {
            'nova_senha': _senha.text,
            'novo_login': _login.text,
            'novo_nome': _nome.text,
          },
        );
        _registrar(
          'warning',
          "Usuário master REDEFINIDO via senha mestra (login='${u['login']}').",
        );
      } on ErroNucleo catch (e) {
        erro = e.msg;
      } finally {
        await Nucleo.chamar<Object?>(
          'banco.trancar',
        ); // o banco só fica aberto depois do login
      }
      if (erro.isEmpty) {
        widget.aoVoltar();
        return;
      }
    }
    if (mounted) setState(() => _erro = erro);
  }

  @override
  Widget build(BuildContext context) {
    return _centro(
      _cartao(
        largura: 430,
        espaco: 12,
        itens: [
          texto(
            'Redefinir usuário master',
            tamanho: Letra.titulo,
            peso: FontWeight.bold,
            idLayout: 'Acesso.texto9',
          ),
          texto(
            'Use a SENHA MESTRA (anotada quando o banco foi criado) para redefinir a '
            'senha — e, se quiser, o login e o nome — do master.',
            cor: Colors.grey[700],
            idLayout: 'Acesso.texto10',
          ),
          texto(
            'Os traços (-) da senha mestra são opcionais e maiúsculas/minúsculas não importam. $politicaSenha',
            tamanho: Letra.apoio,
            cor: Colors.grey[600],
            idLayout: 'Acesso.texto11',
          ),
          CampoTexto(
            controle: _mestra,
            rotulo: 'Senha mestra',
            largura: TamanhosAcesso.campoSenhaMestra2.largura,
            senha: true,
            revelarSenha: true,
            focoInicial: true,
            altura: TamanhosAcesso.campoSenhaMestra2.altura,
            idLayout: 'TamanhosAcesso.campoSenhaMestra2',
          ),
          CampoTexto(
            controle: _login,
            rotulo: 'Novo login do master (opcional, só letras)',
            largura:
                TamanhosAcesso.campoNovoLoginDoMasterOpcionalSoLetras.largura,
            maximo: loginMax,
            mascara: mascaraLogin,
            altura:
                TamanhosAcesso.campoNovoLoginDoMasterOpcionalSoLetras.altura,
            idLayout: 'TamanhosAcesso.campoNovoLoginDoMasterOpcionalSoLetras',
          ),
          CampoTexto(
            controle: _nome,
            rotulo: 'Novo nome do master (opcional)',
            mascara: (s) => s.toUpperCase(),
            largura: TamanhosAcesso.campoNovoNomeDoMasterOpcional.largura,
            maximo: nomeMax,
            altura: TamanhosAcesso.campoNovoNomeDoMasterOpcional.altura,
            idLayout: 'TamanhosAcesso.campoNovoNomeDoMasterOpcional',
          ),
          CampoTexto(
            controle: _senha,
            rotulo: 'Nova senha do master',
            largura: TamanhosAcesso.campoNovaSenhaDoMaster.largura,
            senha: true,
            revelarSenha: true,
            altura: TamanhosAcesso.campoNovaSenhaDoMaster.altura,
            idLayout: 'TamanhosAcesso.campoNovaSenhaDoMaster',
          ),
          CampoTexto(
            controle: _confirma,
            rotulo: 'Confirmar nova senha',
            largura: TamanhosAcesso.campoConfirmarNovaSenha.largura,
            senha: true,
            revelarSenha: true,
            aoEnviar: (_) => _aplicar(),
            altura: TamanhosAcesso.campoConfirmarNovaSenha.altura,
            idLayout: 'TamanhosAcesso.campoConfirmarNovaSenha',
          ),
          texto(_erro, cor: Colors.red[600], idLayout: 'Acesso.texto12'),
          SizedBox(
            width: 360,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 10,
              children: [
                ElementoLayoutGenerico(
                  width: TamanhosAcesso.botaoVoltar.largura,
                  height: TamanhosAcesso.botaoVoltar.altura,
                  child: TextButton(
                    onPressed: widget.aoVoltar,
                    onLongPress: () {},
                    onHover: (_) {},
                    clipBehavior: Clip.none,
                    child: Text(
                      ajusteLayout(
                        context,
                        'TamanhosAcesso.botaoVoltar',
                      ).exibir('Voltar'),
                    ),
                  ),
                  idLayout: 'TamanhosAcesso.botaoVoltar',
                  textoOriginal: 'Voltar',
                ),
                ElementoLayoutGenerico(
                  width: TamanhosAcesso.botaoRedefinir.largura,
                  height: TamanhosAcesso.botaoRedefinir.altura,
                  child: FilledButton.icon(
                    onPressed: _aplicar,
                    onLongPress: () {},
                    onHover: (_) {},
                    clipBehavior: Clip.none,
                    icon: const Icon(Icons.key),
                    label: Text(
                      ajusteLayout(
                        context,
                        'TamanhosAcesso.botaoRedefinir',
                      ).exibir('Redefinir'),
                    ),
                  ),
                  idLayout: 'TamanhosAcesso.botaoRedefinir',
                  textoOriginal: 'Redefinir',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------------------------- //
// Primeiro acesso
// ------------------------------------------------------------------------------------- //
class _PrimeiroAcesso extends StatefulWidget {
  const _PrimeiroAcesso({required this.aoCriar}) : cenario = null;

  /// O mesmo cartão, já preenchido e desabilitado: é o cenário atrás do popup da senha mestra.
  const _PrimeiroAcesso.cenario(List<String> this.cenario) : aoCriar = null;

  /// (master criado, senha mestra recém-gerada, o cartão — vira o cenário do popup)
  final void Function(Usuario usuario, String senhaMestra, Widget cartao)?
  aoCriar;
  final List<String>? cenario;

  @override
  State<_PrimeiroAcesso> createState() => _PrimeiroAcessoState();
}

class _PrimeiroAcessoState extends State<_PrimeiroAcesso> {
  late final _nome = TextEditingController(text: widget.cenario?[0]);
  late final _login = TextEditingController(text: widget.cenario?[1]);
  late final _senha = TextEditingController(text: widget.cenario?[2]);
  late final _confirma = TextEditingController(text: widget.cenario?[3]);
  String _erro = '';
  bool _criando = false;

  @override
  void dispose() {
    for (final c in [_nome, _login, _senha, _confirma]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _criar() async {
    if (_criando) return;
    _criando = true;
    try {
      var msg = await Nucleo.chamar<String>(
        'usuarios.validar_credenciais_novas',
        {
          'login': _login.text,
          'senha': _senha.text,
          'confirma': _confirma.text,
          'nome': _nome.text,
        },
      );
      if (msg.isEmpty && _nome.text.trim().isEmpty) {
        msg = 'Informe o nome do usuário.';
      }
      if (msg.isNotEmpty) {
        if (mounted) setState(() => _erro = msg);
        return;
      }
      var senhaMestra = '';
      Usuario u;
      try {
        senhaMestra = await Nucleo.chamar<String>('chaves.criar_banco');
        u = Usuario.deJson(
          await Nucleo.chamar<Map<String, dynamic>>('usuarios.criar', {
            'login': _login.text,
            'nome': _nome.text,
            'nivel': 4,
            'senha': _senha.text,
            'criado_por': null,
          }),
        );
      } on ErroNucleo catch (e) {
        _registrar('error', 'Falha no primeiro acesso: ${e.msg}');
        if (senhaMestra.isNotEmpty) {
          // banco recém-nascido e vazio: recomeça do zero
          await Nucleo.chamar<Object?>('chaves.desfazer_criacao');
        }
        if (mounted) setState(() => _erro = e.msg);
        return;
      }
      await Nucleo.chamar<Object?>('registro.definir_usuario', {
        'operador_id': u.id,
      });
      _registrar('info', 'Primeiro acesso: master #${u.id} ${u.login} criado.');
      if (mounted) {
        widget.aoCriar!(
          u,
          senhaMestra,
          _PrimeiroAcesso.cenario([
            _nome.text,
            _login.text,
            _senha.text,
            _confirma.text,
          ]),
        );
      }
    } finally {
      _criando = false;
    }
  }

  Widget _montar({bool desabilitado = false}) {
    return _cartao(
      largura: 430,
      espaco: 12,
      itens: [
        texto(
          'Primeiro acesso',
          tamanho: Letra.titulo,
          peso: FontWeight.bold,
          idLayout: 'Acesso.texto13',
        ),
        texto(
          'Crie o usuário MASTER do sistema. Este usuário é único e terá acesso ao sistema inteiro',
          cor: Colors.grey[700],
          idLayout: 'Acesso.texto14',
        ),
        texto(
          '$politicaSenha Antes de o sistema abrir será mostrada a senha '
          'mestra de recuperação, para anotar.',
          tamanho: Letra.apoio,
          cor: Colors.grey[600],
          idLayout: 'Acesso.texto15',
        ),
        CampoTexto(
          controle: _nome,
          rotulo: 'Seu nome',
          largura: TamanhosAcesso.campoSeuNome.largura,
          focoInicial: !desabilitado,
          maximo: nomeMax,
          desabilitado: desabilitado,
          altura: TamanhosAcesso.campoSeuNome.altura,
          idLayout: 'TamanhosAcesso.campoSeuNome',
        ),
        CampoTexto(
          controle: _login,
          rotulo: 'Usuário (login, só letras)',
          largura: TamanhosAcesso.campoUsuarioLoginSoLetras.largura,
          maximo: loginMax,
          mascara: mascaraLogin,
          desabilitado: desabilitado,
          altura: TamanhosAcesso.campoUsuarioLoginSoLetras.altura,
          idLayout: 'TamanhosAcesso.campoUsuarioLoginSoLetras',
        ),
        CampoTexto(
          controle: _senha,
          rotulo: 'Senha',
          largura: TamanhosAcesso.campoSenha2.largura,
          senha: true,
          revelarSenha: true,
          desabilitado: desabilitado,
          altura: TamanhosAcesso.campoSenha2.altura,
          idLayout: 'TamanhosAcesso.campoSenha2',
        ),
        CampoTexto(
          controle: _confirma,
          rotulo: 'Confirmar senha',
          largura: TamanhosAcesso.campoConfirmarSenha.largura,
          senha: true,
          revelarSenha: true,
          desabilitado: desabilitado,
          altura: TamanhosAcesso.campoConfirmarSenha.altura,
          idLayout: 'TamanhosAcesso.campoConfirmarSenha',
        ),
        texto(_erro, cor: Colors.red[600], idLayout: 'Acesso.texto16'),
        BotaoInflavel(
          rotulo: 'Criar master e entrar',
          icone: Icons.person_add,
          aoApertar: desabilitado ? null : _criar,
          largura: TamanhosAcesso.botaoGeral3.largura,
          altura: TamanhosAcesso.botaoGeral3.altura,
          idLayout: 'TamanhosAcesso.botaoGeral3',
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) =>
      widget.cenario != null ? _montar(desabilitado: true) : _centro(_montar());
}

/// Popup mostrado UMA vez, ANTES de o sistema abrir, quando o banco acaba de nascer (primeiro
/// acesso): a senha mestra foi gerada agora e não fica guardada em lugar nenhum. [fundo] é a
/// tela de onde se veio, que fica só de cenário.
class _PopupSenhaMestra extends StatefulWidget {
  const _PopupSenhaMestra({
    required this.senha,
    required this.fundo,
    required this.aoConcluir,
  });

  final String senha;
  final Widget fundo;
  final VoidCallback aoConcluir;

  @override
  State<_PopupSenhaMestra> createState() => _PopupSenhaMestraState();
}

class _PopupSenhaMestraState extends State<_PopupSenhaMestra> {
  late final _campo = TextEditingController(text: widget.senha);
  bool _copiada = false;

  @override
  void dispose() {
    _campo.dispose();
    super.dispose();
  }

  Future<void> _copiar() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.senha));
      if (mounted) setState(() => _copiada = true);
    } catch (e) {
      _registrar('error', 'Falha ao copiar para a área de transferência: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final popup = Card(
      child: Container(
        width: 560,
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 14,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            texto(
              'Proteção do cofre de senhas',
              tamanho: Letra.titulo,
              peso: FontWeight.bold,
              idLayout: 'Acesso.texto17',
            ),
            texto(
              'O banco deste sistema é criptografado por inteiro: cadastros, usuários e '
              'senhas só abrem com a senha de um usuário ou com a senha mestra abaixo.',
              cor: Colors.grey[800],
              idLayout: 'Acesso.texto18',
            ),
            Row(
              spacing: 4,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: CampoTexto(
                    controle: _campo,
                    rotulo: 'Senha mestra de recuperação',
                    somenteLeitura: true,
                    expandir: true,
                    alinhamento: TextAlign.center,
                    estilo: const TextStyle(
                      fontSize: Letra.senhaMestra,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Consolas',
                    ),
                    largura:
                        TamanhosAcesso.campoSenhaMestraDeRecuperacao.largura,
                    altura: TamanhosAcesso.campoSenhaMestraDeRecuperacao.altura,
                    idLayout: 'TamanhosAcesso.campoSenhaMestraDeRecuperacao',
                  ),
                ),
                ElementoLayoutGenerico(
                  width: TamanhosAcesso.botaoAcao2.largura,
                  height: TamanhosAcesso.botaoAcao2.altura,
                  child: IconButton(
                    onPressed: _copiar,
                    tooltip: _copiada ? 'Copiada' : 'Copiar',
                    icon: Icon(_copiada ? Icons.check : Icons.content_copy),
                  ),
                  idLayout: 'TamanhosAcesso.botaoAcao2',
                ),
              ],
            ),
            texto(
              'Anote e guarde FORA do computador (papel). Ela NÃO será mostrada novamente.',
              peso: FontWeight.bold,
              cor: Colors.red[700],
              idLayout: 'Acesso.texto19',
            ),
            texto(
              _textoSenhaMestra,
              tamanho: Letra.apoio,
              cor: Colors.grey[700],
              idLayout: 'Acesso.texto20',
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 10,
              children: [
                BotaoInflavel(
                  rotulo: 'Anotei, entrar',
                  icone: Icons.check,
                  aoApertar: widget.aoConcluir,
                  altura: TamanhosAcesso.botaoGeral4.altura,
                  largura: TamanhosAcesso.botaoGeral4.largura,
                  idLayout: 'TamanhosAcesso.botaoGeral4',
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        _centro(widget.fundo),
        Container(
          alignment: Alignment.center,
          color: comOpacidade(Colors.black, 0.45),
          child: popup,
        ),
      ],
    );
  }
}
