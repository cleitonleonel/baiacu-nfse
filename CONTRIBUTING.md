# Como contribuir com o Baiacu NFS-e

Obrigado por querer ajudar! Toda melhoria entra pelo repositório oficial, para que todo mundo receba a mesma versão pela atualização automática.

## Relatar um erro ou pedir uma melhoria

Abra um chamado em [Issues](https://github.com/williamlala/baiacu-nfse/issues) ou escreva para emissorbaiacu@gmail.com. Num erro, conte:

- o que você estava fazendo e o que esperava acontecer;
- a mensagem que apareceu (o botão **Registros**, no topo, mostra o histórico);
- a versão do programa (em **Configurações › Avançado › Atualizações**).

**Nunca** envie a senha, o arquivo do certificado (.pfx), o banco (`database\`) ou dados de clientes.

## Enviar uma alteração (pull request)

1. Faça um *fork* do repositório e crie um *branch* para a sua alteração.
2. Mantenha o padrão do código: textos para o usuário em português, curtos e diretos; comentários explicando o porquê.
3. Antes de enviar, confira que o projeto compila e que a análise passa:
   - núcleo: `cargo check` e `cargo test --lib` na pasta `rust`;
   - tela: `dart analyze lib`.
4. Abra o *pull request* explicando o que muda e por quê. Ele é revisado antes de entrar no programa.

Ao enviar uma contribuição, você concorda com a seção 4 da [licença](LICENSE.md): a contribuição passa a fazer parte do Programa, e o *fork* serve só para preparar *pull requests*, não para publicar uma versão independente.

## Compilar

- **Rust** (estável) e **Flutter 3.44.8**, no Windows 10 ou 11 com o Visual Studio (C++).
- No projeto local, as bibliotecas estáticas ficam em `NFSe/extras/terceiros/`. Para outra disposição, informe `OPENSSL_LIB_DIR` e `BAIACU_NATIVE_LIBS`. Os cabeçalhos e licenças ficam em `rust/terceiros/`.
