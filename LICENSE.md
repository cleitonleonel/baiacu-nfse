# Licença do Baiacu NFS-e: código-fonte disponível

Versão 1.0

Copyright © 2026 williamlala (autor do Baiacu NFS-e). Todos os direitos reservados.

O código do Baiacu NFS-e é público para que qualquer pessoa possa conferir o que o programa faz e ajudar a melhorá-lo **no repositório oficial**. Ele **não** é um software livre: copiar o programa para criar ou distribuir uma versão independente não é permitido.

## 1. Definições

- **Programa:** o código-fonte, as imagens, os textos e a documentação deste repositório, menos os componentes de terceiros listados na seção 8.
- **Repositório oficial:** https://github.com/williamlala/baiacu-nfse
- **Versão oficial:** o programa e o instalador publicados pelo autor nas *Releases* do repositório oficial.
- **Autor:** o titular dos direitos indicado acima.

## 2. O que você pode fazer, de graça

1. Instalar e usar a versão oficial, inclusive numa empresa e para fins comerciais (por exemplo, emitir as notas da sua empresa ou dos seus clientes).
2. Ler, estudar e conferir o código-fonte.
3. Baixar o código e compilá-lo no seu computador para estudar, testar ou procurar um erro, sem distribuir o resultado a ninguém.
4. Fazer um *fork* no GitHub e alterar o código **somente** para propor essas alterações ao repositório oficial, por *pull request*.

## 3. O que você não pode fazer sem autorização do autor por escrito

1. Distribuir, publicar, vender, alugar ou sublicenciar o Programa, alterado ou não, em código-fonte ou compilado (inclusive executáveis e instaladores compilados por você).
2. Criar, publicar ou distribuir um programa derivado ou concorrente feito, no todo ou em parte, a partir do código do Programa.
3. Oferecer o Programa, alterado ou não, como serviço online a terceiros.
4. Usar o nome "Baiacu NFS-e", o logotipo ou o ícone do baiacu em outro produto, ou de um jeito que faça um trabalho seu parecer oficial.
5. Remover ou alterar os avisos de direitos autorais e esta licença.

Um *fork* no GitHub não é uma versão independente: ele serve só para preparar *pull requests*. Os direitos que os Termos de Serviço do GitHub dão a todos (ver o repositório e fazer *fork* dentro do GitHub) continuam valendo, nos limites desta licença.

## 4. Contribuições

Ao enviar uma contribuição (*pull request*, código num *issue*, correção, texto ou imagem), você declara que ela é sua ou que você tem o direito de enviá-la. Você também concede ao autor, de graça, para sempre, em qualquer lugar e de forma irrevogável, o direito de usar, alterar, distribuir e sublicenciar essa contribuição como parte do Programa, inclusive sob outra licença.

Contribuir não dá direito a pagamento nem torna você coautor ou titular do Programa. O seu nome continua no histórico do repositório.

## 5. Sem garantia

O Programa é oferecido **no estado em que se encontra**, sem garantia de qualquer tipo e sem garantia de continuidade. Quem usa o Programa é responsável por conferir as notas emitidas e por cumprir as próprias obrigações fiscais. Na máxima extensão permitida pela lei, o autor não responde por perdas, multas, lucros cessantes ou outros danos decorrentes do uso do Programa.

## 6. Fim da licença

Quem descumprir esta licença perde, automaticamente, as permissões da seção 2.

## 7. Lei aplicável

Esta licença segue as leis brasileiras, em especial a Lei 9.609/1998 (programas de computador) e a Lei 9.610/1998 (direitos autorais).

## 8. Componentes de terceiros

Os componentes abaixo **não** estão sob esta licença: cada um segue a licença própria, que prevalece sobre esta no que for dele.

| Componente | Onde | Licença |
|---|---|---|
| Leiaute e desenho da DANFSe, derivados do BrazilFiscalReport | `rust/recursos/danfse/`, `rust/src/danfse.rs`, `rust/src/danfse_dados.rs`, `rust/src/pdf.rs` | LGPL-3.0 (`rust/recursos/danfse/LICENSE`, que se apoia na GPL-3.0 em `LICENSE-GPL`) |
| Segmentação do QR Code, segundo o python-qrcode | `rust/recursos/danfse/` | BSD-3-Clause (`rust/recursos/danfse/LICENSE-QR`) |
| SumatraPDF 3.7, com modificações | `bin/sumatrapdf/` | GPL-3.0 (`bin/sumatrapdf/COPYING`; partes BSD em `COPYING.BSD`; alterações em `sumatra-mod.patch`) |
| OpenSSL 3.5.4 | `rust/terceiros/openssl/` | Apache-2.0 (`rust/terceiros/openssl/LICENSE.txt`) |
| libxml2 2.11.9 | `rust/terceiros/libxml2/` | MIT (`rust/terceiros/libxml2/Copyright`) |
| Trechos do Flutter (lista suspensa) | `lib/flutter/kit/menu_suspenso.dart` | BSD-3-Clause (The Flutter Authors) |
| Pacotes do Flutter (pub.dev) e do Rust (crates.io) | baixados na compilação (`pubspec.lock`, `rust/Cargo.lock`) | a licença de cada pacote |

No programa instalado, os textos dessas licenças ficam em `data\licencas\` e em `bin\sumatrapdf\`.

As permissões que essas licenças dão sobre os componentes delas continuam valendo. Por exemplo, a LGPL-3.0 permite alterar a parte da DANFSe e recompilar o programa com essa alteração.

## 9. Contato

Para pedir uma autorização que esta licença não dá: emissorbaiacu@gmail.com
