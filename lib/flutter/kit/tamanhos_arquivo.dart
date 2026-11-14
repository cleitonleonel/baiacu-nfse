/// Unidades curtas para arquivos; mantém a base 1024 usada pelos bancos.
String tamanhoArquivo(num bytes) {
  const unidades = ['B', 'KB', 'MB', 'GB', 'TB'];
  var valor = bytes < 0 ? 0.0 : bytes.toDouble();
  var unidade = 0;
  while (valor >= 1024 && unidade < unidades.length - 1) {
    valor /= 1024;
    unidade++;
  }
  return '${valor.toStringAsFixed(unidade == 0 ? 0 : 1).replaceAll('.', ',')} ${unidades[unidade]}';
}
