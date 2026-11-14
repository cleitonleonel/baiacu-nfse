/// Campo de texto do programa: o mesmo `TextFormField` com contorno de sempre.
///
/// - contorno neutro de um pixel físico e rótulo de tamanho fixo;
/// - largura padrão de 300 pontos quando ninguém diz outra;
/// - [mascara] roda a cada tecla: se ela muda o texto (maiúsculas, só dígitos, R$…), o campo é
///   reescrito com o cursor no fim;
/// - senha com o "olho" de revelar.
library;

import 'package:flutter/material.dart';

import '../editor_layout.dart';
import '../estilo.dart' show Medida;

import 'flet.dart' show comDica, travado;
import 'contorno_campo.dart';

class CampoTexto extends StatefulWidget {
  const CampoTexto({
    super.key,
    this.idLayout,
    required this.controle,
    this.rotulo,
    this.rotuloNaBorda,
    this.largura,
    this.altura,
    this.compacto = false,
    this.emTabela = false,
    this.expandir = false,
    this.senha = false,
    this.revelarSenha = false,
    this.focoInicial = false,
    this.somenteLeitura = false,
    this.desabilitado = false,
    this.maximo,
    this.ocultarContador = false,
    this.dica,
    this.mascara,
    this.aoMudar,
    this.aoEnviar,
    this.foco,
    this.alinhamento = TextAlign.start,
    this.estilo,
    this.tamanhoTexto,
    this.estiloRotulo,
    this.denso,
    this.preenchimento,
    this.variasLinhas = false,
    this.minLinhas = 1,
    this.maxLinhas,
    this.prefixo,
    this.iconePrefixo,
    this.sufixo,
    this.textoSufixo,
    this.dicaMouse,
    this.erro,
    this.aoFocar,
    this.aoDesfocar,
    this.selecionarAoFocar = false,
  });

  final TextEditingController controle;
  final String? rotulo;
  final String? rotuloNaBorda;
  final double? largura;
  final double? altura;

  /// Controles de paginação usam a altura compacta explicitamente.
  final bool compacto;

  /// A grade da tabela fornece o contorno e o cabeçalho da célula.
  final bool emTabela;
  final bool expandir;
  final bool senha;
  final bool revelarSenha;
  final bool focoInicial;
  final bool somenteLeitura;
  final bool desabilitado;
  final int? maximo;
  final bool ocultarContador;
  final String? dica;
  final String Function(String texto)? mascara;
  final ValueChanged<String>? aoMudar;
  final ValueChanged<String>? aoEnviar;
  final FocusNode? foco;
  final TextAlign alinhamento;
  final TextStyle? estilo;
  final double? tamanhoTexto;
  final TextStyle? estiloRotulo;
  final bool? denso;
  final EdgeInsetsGeometry? preenchimento;
  final bool variasLinhas;
  final int minLinhas;
  final int? maxLinhas;
  final String? prefixo;
  final Widget? iconePrefixo;
  final Widget? sufixo;
  final Widget? textoSufixo;

  /// Dica do mouse (o balãozinho escuro).
  final String? dicaMouse;

  /// Mensagem de erro sob o campo.
  final String? erro;
  final VoidCallback? aoFocar;
  final VoidCallback? aoDesfocar;
  final bool selecionarAoFocar;

  final String? idLayout;

  @override
  State<CampoTexto> createState() => _CampoTextoState();
}

class _CampoTextoState extends State<CampoTexto> {
  bool _revelada = false;
  FocusNode? _focoProprio;

  FocusNode get _foco => widget.foco ?? (_focoProprio ??= FocusNode());
  FocusNode? _ouvido;
  bool _tinhaFoco = false;

  void _focoMudou() {
    final f = _ouvido;
    if (f == null || f.hasFocus == _tinhaFoco) return;
    _tinhaFoco = f.hasFocus;
    if (widget.rotuloNaBorda != null) setState(() {});
    if (_tinhaFoco) {
      if (widget.selecionarAoFocar) {
        widget.controle.selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.controle.text.length,
        );
      }
      widget.aoFocar?.call();
    } else {
      widget.aoDesfocar?.call();
    }
  }

  void _ouvir() {
    final f = _foco;
    if (identical(f, _ouvido)) return;
    _ouvido?.removeListener(_focoMudou);
    _ouvido = f..addListener(_focoMudou);
    _tinhaFoco = f.hasFocus;
  }

  @override
  void dispose() {
    _ouvido?.removeListener(_focoMudou);
    _focoProprio?.dispose();
    super.dispose();
  }

  void _mudou(String texto) {
    final mascara = widget.mascara;
    if (mascara != null) {
      final novo = mascara(texto);
      if (novo != texto) {
        widget.controle.value = TextEditingValue(
          text: novo,
          selection: TextSelection.collapsed(offset: novo.length),
        );
        texto = novo;
      }
    }
    widget.aoMudar?.call(texto);
    if (widget.rotuloNaBorda != null) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    _ouvir();
    final ajuste = ajusteLayout(context, widget.idLayout);
    final inerte = widget.desabilitado || travado(context);
    final InputBorder contorno = widget.emTabela
        ? InputBorder.none
        : ContornoCampo(densidade: MediaQuery.devicePixelRatioOf(context));
    Widget? olho;
    if (widget.senha && widget.revelarSenha) {
      olho = MouseRegion(
        cursor: inerte ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          child: Icon(_revelada ? Icons.visibility_off : Icons.visibility),
          onTap: inerte ? null : () => setState(() => _revelada = !_revelada),
        ),
      );
    }
    var estilo = widget.estilo ?? const TextStyle();
    if (widget.tamanhoTexto != null) {
      estilo = estilo.copyWith(fontSize: widget.tamanhoTexto);
    }
    estilo = ajuste.estilo(estilo);
    final varias = widget.variasLinhas;
    // Contador e erro ficam abaixo do contorno, sem comprimir a area de entrada.
    final temApoio =
        (widget.maximo != null && !widget.ocultarContador) ||
        (widget.erro?.isNotEmpty ?? false);
    final altura = varias
        ? ajuste.altura ?? widget.altura
        : temApoio
        ? null
        : widget.compacto
        ? widget.altura ?? Medida.controleDePagina
        : Medida.campo;
    final preencherAltura = varias && altura != null;
    Widget campo = TextFormField(
      controller: widget.controle,
      focusNode: _foco,
      style: estilo,
      autofocus: widget.focoInicial,
      enabled: !inerte,
      readOnly: widget.somenteLeitura,
      obscureText: widget.senha && !_revelada,
      obscuringCharacter: '•',
      textAlign: ajuste.alinhamento ?? widget.alinhamento,
      maxLength: widget.maximo,
      buildCounter: widget.ocultarContador
          ? (
              _, {
              required currentLength,
              required isFocused,
              required maxLength,
            }) => null
          : null,
      expands: preencherAltura,
      minLines: preencherAltura ? null : widget.minLinhas,
      maxLines: preencherAltura
          ? null
          : widget.maxLinhas ?? (varias ? null : 1),
      keyboardType: varias ? TextInputType.multiline : TextInputType.text,
      cursorWidth: 2.0,
      clipBehavior: Clip.hardEdge,
      scrollPadding: const EdgeInsets.all(20.0),
      onChanged: _mudou,
      onFieldSubmitted: varias ? null : widget.aoEnviar,
      decoration: InputDecoration(
        enabled: !inerte,
        contentPadding:
            widget.preenchimento ??
            (widget.emTabela
                ? const EdgeInsets.symmetric(horizontal: 6, vertical: 8)
                : null),
        isDense: widget.denso,
        label:
            widget.emTabela ||
                ajuste.oculto ||
                (widget.rotulo == null && ajuste.texto == null)
            ? null
            : Tooltip(
                message: ajuste.exibir(widget.rotulo ?? ''),
                child: Text(
                  widget.rotuloNaBorda != null &&
                          (_foco.hasFocus || widget.controle.text.isNotEmpty)
                      ? widget.rotuloNaBorda!
                      : ajuste.exibir(widget.rotulo ?? ''),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
        labelStyle: PadraoControles.rotulo.copyWith(
          color: widget.estiloRotulo?.color,
        ),
        floatingLabelStyle: PadraoControles.rotuloFlutuante.copyWith(
          color: widget.estiloRotulo?.color,
        ),
        border: contorno,
        enabledBorder: contorno,
        focusedBorder: contorno,
        disabledBorder: contorno,
        errorBorder: contorno,
        focusedErrorBorder: contorno,
        filled: false,
        hintText: widget.dica,
        hintStyle: widget.emTabela && widget.estilo?.color != null
            ? TextStyle(color: widget.estilo!.color)
            : null,
        errorText: widget.erro,
        prefixText: widget.prefixo,
        prefixIcon: widget.iconePrefixo,
        suffixIcon: widget.sufixo ?? olho,
        suffix: widget.textoSufixo,
      ),
    );
    if (widget.expandir && ajuste.largura == null) {
      return alvoLayout(
        context,
        comDica(widget.dicaMouse, SizedBox(height: altura, child: campo)),
        id: widget.idLayout,
        nome: widget.rotulo ?? 'Campo',
        tipo: 'campo',
        propriedades: {
          ...propriedadesTexto(
            context,
            ajuste.exibir(widget.rotulo ?? ''),
            estilo: Theme.of(context).textTheme.bodyLarge?.merge(estilo),
            alinhamento: ajuste.alinhamento ?? widget.alinhamento,
          ),
          'alturaUniforme': !varias,
        },
      );
    }
    if ((ajuste.largura ?? widget.largura) == null) {
      campo = ConstrainedBox(
        constraints: const BoxConstraints.tightFor(width: 300),
        child: campo,
      );
    }
    campo = comDica(widget.dicaMouse, campo);
    if (altura != null ||
        ajuste.largura != null ||
        ajuste.altura != null ||
        widget.largura != null ||
        widget.altura != null) {
      campo = SizedBox(
        width: ajuste.largura ?? widget.largura,
        height: altura,
        child: campo,
      );
    }
    final resultado = alvoLayout(
      context,
      campo,
      id: widget.idLayout,
      nome: widget.rotulo ?? 'Campo',
      tipo: 'campo',
      propriedades: {
        ...propriedadesTexto(
          context,
          ajuste.exibir(widget.rotulo ?? ''),
          estilo: Theme.of(context).textTheme.bodyLarge?.merge(estilo),
          alinhamento: ajuste.alinhamento ?? widget.alinhamento,
        ),
        'alturaUniforme': !varias,
      },
    );
    return widget.expandir && ajuste.largura != null
        ? Align(
            alignment: Alignment.topLeft,
            widthFactor: 1,
            heightFactor: 1,
            child: resultado,
          )
        : resultado;
  }
}
