# OpenSSL 3.5.4 (Windows x64)

As bibliotecas estaticas existentes `libcrypto.lib` e `libssl.lib` sao do OpenSSL
3.5.4. Os cabecalhos em `include/openssl` acompanham a mesma versao, evitando a
dependencia de uma instalacao em `C:/Program Files/OpenSSL-Win64`.

Fonte oficial dos cabecalhos:
https://www.openssl.org/source/openssl-3.5.4.tar.gz

SHA-256 conferido com o arquivo `.sha256` publicado pelo OpenSSL:
`967311f84955316969bdb1d8d4b983718ef42338639c621ec4c34fddef355e99`.

Os arquivos `.h.in` foram processados pelo `util/dofile.pl` oficial, com a
configuracao `perl Configure VC-WIN64A`, usando Perl do Strawberry Perl.
Nao e necessario instalar Perl ou OpenSSL para compilar este projeto: os
cabecalhos gerados ja estao incluidos. A licenca esta em `LICENSE.txt`.

Ao atualizar o OpenSSL, atualize as duas bibliotecas e os cabecalhos juntos.
