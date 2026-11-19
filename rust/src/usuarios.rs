//! Usuários com níveis de acesso.
//!
//! Níveis: 1=Operador, 2=Operador+, 3=Admin, 4=Master. Há **um único master global**, criado no
//! primeiro acesso; os demais usuários são globais e operam os prestadores que um nível superior
//! liberar para eles (tabela usuario_prestadores). Senhas só como hash PBKDF2-SHA256 + sal.
//!
//! Regras de autoridade:
//!   - você só cadastra/gerencia usuários de nível INFERIOR ao seu;
//!   - promover sobe 1 nível por vez, e o resultado fica abaixo de quem promove (teto 3 — master
//!     só nasce no primeiro acesso);
//!   - não é possível desativar/excluir o último master ativo.
use chrono::Local;
use rusqlite::{Connection, OptionalExtension, Row, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use unicode_normalization::UnicodeNormalization;

use crate::banco;
use crate::chaves;
use crate::erro::{Erro, Res};

pub const NIVEL_MASTER: i64 = 4;
const PBKDF2_ITER: u32 = 200_000;
pub const LOGIN_MAX: usize = 20; // comprimento máximo do login
pub const NOME_MAX: usize = 20; // comprimento máximo do nome
// A senha do usuário é o que ABRE o banco cifrado: quem levar dados.db + dados.key pode tentar
// senhas à vontade, então senha curta não é aceitável.
pub const SENHA_MIN: usize = 8;
pub const POLITICA_SENHA: &str = "A senha deve ter no mínimo 8 caracteres, com letra maiúscula, \
                                  letra minúscula, número e caractere especial.";
pub const FOTO_MAX_BYTES: usize = 3 * 1024 * 1024; // 3 MB — avatar não precisa de mais que isso

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Usuario {
    pub id: i64,
    pub login: String,
    pub nome: String,
    pub nivel: i64,
    pub ativo: bool,
}

impl Usuario {
    pub fn is_master(&self) -> bool {
        self.nivel >= NIVEL_MASTER
    }

    pub fn nivel_nome(&self) -> String {
        format!("Nível {}", self.nivel)
    }
}

/// Usuários moram no BANCO ÚNICO (database/dados.db, tabelas usuarios/usuario_prestadores). O banco
/// é cifrado: só há conexão depois de `entrar()` (ou da senha mestra) destrancá-lo.
fn db() -> Res<Connection> {
    let con = banco::conn()?;
    criar_tabelas(&con)?;
    Ok(con)
}

pub fn criar_tabelas(con: &Connection) -> Res<()> {
    con.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS usuarios (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            login TEXT NOT NULL UNIQUE,
            nome TEXT NOT NULL,
            nivel INTEGER NOT NULL CHECK (nivel BETWEEN 1 AND 4),
            senha_salt BLOB NOT NULL,
            senha_hash BLOB NOT NULL,
            ativo INTEGER NOT NULL DEFAULT 1,
            criado_em TEXT NOT NULL,
            criado_por TEXT,
            foto BLOB
        );
        CREATE TABLE IF NOT EXISTS usuario_prestadores (
            usuario_id INTEGER NOT NULL,
            prestador TEXT NOT NULL,
            PRIMARY KEY (usuario_id, prestador),
            FOREIGN KEY (usuario_id) REFERENCES usuarios(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS usuario_codigo (
            usuario_id INTEGER PRIMARY KEY,
            codigo TEXT NOT NULL UNIQUE
        );
        ",
    )?;
    Ok(())
}

// ------------------------------------------------------------------------------- //
// Código de autorização: 2 letras ou números, único por conta, escolhido pelo usuário.
// Na autorização, quem autoriza digita o código seguido da senha ("AD" + "senha"); o
// código identifica UMA conta e só ela tem a senha conferida. Maiúsculas e minúsculas
// valem o mesmo no código; a senha continua diferenciando.
// ------------------------------------------------------------------------------- //
pub const CODIGO_TAM: usize = 2;
const SUGESTOES_MAX: usize = 3;
const ALFABETO_CODIGO: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/// Código canônico: letras ASCII e algarismos, em maiúsculas, no máximo 2.
pub fn normalizar_codigo(codigo: &str) -> String {
    codigo
        .trim()
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| c.to_ascii_uppercase())
        .take(CODIGO_TAM)
        .collect()
}

fn codigo_valido(codigo: &str) -> bool {
    codigo.len() == CODIGO_TAM && codigo.bytes().all(|b| ALFABETO_CODIGO.contains(&b))
}

const CODIGO_INVALIDO: &str = "O código de autorização deve ter 2 letras ou números.";

/// Até 3 códigos livres parecidos com `codigo`: primeiro o segundo caractere vizinho, depois o
/// código invertido e, por fim, o primeiro caractere vizinho. Letras sugerem letras e
/// algarismos sugerem algarismos antes de misturar os dois.
pub fn sugerir_codigos(codigo: &str, ocupados: &std::collections::HashSet<String>) -> Vec<String> {
    let alvo = normalizar_codigo(codigo);
    if !codigo_valido(&alvo) {
        return Vec::new();
    }
    let alvo = alvo.as_bytes();
    let posicao = |c: u8| {
        let i = ALFABETO_CODIGO.iter().position(|&x| x == c).unwrap_or(0) as i32;
        (c.is_ascii_digit(), i)
    };
    let distancia = |a: u8, b: u8| {
        let ((da, pa), (db, pb)) = (posicao(a), posicao(b));
        (pa - pb).abs() + if da == db { 0 } else { 40 }
    };
    let mut candidatos: Vec<(i32, bool, u8, String)> = Vec::new();
    for &a in ALFABETO_CODIGO {
        for &b in ALFABETO_CODIGO {
            let c = String::from_utf8(vec![a, b]).unwrap_or_default();
            if (a, b) == (alvo[0], alvo[1]) || ocupados.contains(&c) {
                continue;
            }
            let peso = if (a, b) == (alvo[1], alvo[0]) {
                3
            } else {
                distancia(a, alvo[0]) * 4 + distancia(b, alvo[1]) * 2
            };
            // No empate, manter o primeiro caractere vem antes, e o caractere seguinte vem
            // antes do anterior (AD → AE antes de AC).
            let antes = u8::from(a < alvo[0] || (a == alvo[0] && b < alvo[1]));
            candidatos.push((peso, a != alvo[0], antes, c));
        }
    }
    candidatos.sort();
    candidatos.into_iter().take(SUGESTOES_MAX).map(|(_, _, _, c)| c).collect()
}

fn codigos_em_uso(con: &Connection, exceto: Option<i64>) -> Res<std::collections::HashSet<String>> {
    // Só contas que existem: uma versão anterior que excluiu a conta deixa o código órfão.
    let mut st = con.prepare(
        "SELECT c.codigo FROM usuario_codigo c JOIN usuarios u ON u.id = c.usuario_id \
         WHERE c.usuario_id <> ?1",
    )?;
    let it = st.query_map([exceto.unwrap_or(0)], |r| r.get::<_, String>(0))?;
    Ok(it.collect::<Result<_, _>>()?)
}

fn em_uso(codigo: &str, sugestoes: &[String]) -> Erro {
    let mut msg = format!("O código {codigo} já está em uso.");
    if !sugestoes.is_empty() {
        msg.push_str(&format!(" Disponíveis: {}.", sugestoes.join(", ")));
    }
    Erro::valor(msg)
}

/// Resultado da conferência de um código digitado (cadastro ou troca).
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ConferenciaCodigo {
    pub codigo: String,
    pub valido: bool,
    pub disponivel: bool,
    pub sugestoes: Vec<String>,
}

/// Confere se `codigo` pode ser usado. `usuario_id` = a conta que vai usá-lo (o código atual
/// dela conta como disponível).
pub fn conferir_codigo(codigo: &str, usuario_id: Option<i64>) -> Res<ConferenciaCodigo> {
    let codigo = normalizar_codigo(codigo);
    if !codigo_valido(&codigo) {
        return Ok(ConferenciaCodigo { codigo, valido: false, disponivel: false, sugestoes: Vec::new() });
    }
    let ocupados = codigos_em_uso(&db()?, usuario_id)?;
    let disponivel = !ocupados.contains(&codigo);
    let sugestoes = if disponivel { Vec::new() } else { sugerir_codigos(&codigo, &ocupados) };
    Ok(ConferenciaCodigo { codigo, valido: true, disponivel, sugestoes })
}

/// O código de autorização da conta (None = ainda não definido).
pub fn codigo_de(usuario_id: i64) -> Res<Option<String>> {
    Ok(db()?
        .query_row(
            "SELECT codigo FROM usuario_codigo WHERE usuario_id = ?1",
            [usuario_id],
            |r| r.get(0),
        )
        .optional()?)
}

/// Grava o código na transação de quem chama. Código ocupado volta com até 3 sugestões.
fn gravar_codigo(con: &Connection, usuario_id: i64, codigo: &str) -> Res<String> {
    let codigo = normalizar_codigo(codigo);
    if !codigo_valido(&codigo) {
        return Err(Erro::valor(CODIGO_INVALIDO));
    }
    let ocupados = codigos_em_uso(con, Some(usuario_id))?;
    if ocupados.contains(&codigo) {
        return Err(em_uso(&codigo, &sugerir_codigos(&codigo, &ocupados)));
    }
    con.execute(
        "DELETE FROM usuario_codigo WHERE codigo = ?1 AND usuario_id NOT IN (SELECT id FROM usuarios)",
        [&codigo],
    )?;
    con.execute(
        "INSERT INTO usuario_codigo (usuario_id, codigo) VALUES (?1, ?2) \
         ON CONFLICT(usuario_id) DO UPDATE SET codigo = excluded.codigo",
        params![usuario_id, codigo],
    )?;
    Ok(codigo)
}

/// Define (ou troca) o código de autorização da conta.
pub fn definir_codigo(usuario_id: i64, codigo: &str) -> Res<String> {
    let mut con = db()?;
    let tx = con.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let gravado = gravar_codigo(&tx, usuario_id, codigo)?;
    tx.commit()?;
    Ok(gravado)
}

/// Autorização por "código + senha" num campo só: os 2 primeiros caracteres são o código (sem
/// diferenciar maiúsculas), o restante é a senha. Só a conta do código tem a senha conferida.
pub fn autenticar_por_codigo(credencial: &str) -> Res<Option<Usuario>> {
    let mut caracteres = credencial.chars();
    let codigo: String = caracteres.by_ref().take(CODIGO_TAM).collect::<String>().to_ascii_uppercase();
    let senha: String = caracteres.collect();
    if !codigo_valido(&codigo) || senha.is_empty() {
        return Ok(None);
    }
    let linha: Option<(Usuario, Vec<u8>, Vec<u8>)> = {
        let con = db()?;
        con.query_row(
            "SELECT u.id, u.login, u.nome, u.nivel, u.ativo, u.senha_salt, u.senha_hash \
             FROM usuario_codigo c JOIN usuarios u ON u.id = c.usuario_id WHERE c.codigo = ?1",
            [&codigo],
            |r| Ok((usuario(r)?, r.get(5)?, r.get(6)?)),
        )
        .optional()?
    };
    Ok(match linha {
        Some((u, sal, guardado)) if u.ativo && iguais(&hash(&senha, &sal), &guardado) => Some(u),
        _ => None,
    })
}

const COLUNAS: &str = "id, login, nome, nivel, ativo";

fn usuario(r: &Row) -> rusqlite::Result<Usuario> {
    Ok(Usuario {
        id: r.get(0)?,
        login: r.get(1)?,
        nome: r.get(2)?,
        nivel: r.get(3)?,
        ativo: r.get::<_, i64>(4)? != 0,
    })
}

/// Restauração de backup (`banco::restaurar_de`): o MASTER continua sendo o DESTA instalação —
/// login, nome, senha, foto e a chave dele — e o master que veio no backup é descartado.
/// `con_novo` é o banco restaurado, ainda fora do lugar.
pub fn levar_master_para(con_novo: &mut Connection) -> Res<()> {
    struct Master {
        id: i64,
        login: String,
        nome: String,
        nivel: i64,
        senha_salt: Vec<u8>,
        senha_hash: Vec<u8>,
        ativo: i64,
        criado_em: String,
        criado_por: Option<String>,
        foto: Option<Vec<u8>>,
    }
    let (m, ch, codigo) = {
        let atual = db()?;
        let m: Option<Master> = atual
            .query_row(
                "SELECT id, login, nome, nivel, senha_salt, senha_hash, ativo, criado_em, criado_por, foto \
                 FROM usuarios WHERE nivel >= ?1 ORDER BY ativo DESC, id LIMIT 1",
                [NIVEL_MASTER],
                |r| {
                    Ok(Master {
                        id: r.get(0)?,
                        login: r.get(1)?,
                        nome: r.get(2)?,
                        nivel: r.get(3)?,
                        senha_salt: r.get(4)?,
                        senha_hash: r.get(5)?,
                        ativo: r.get(6)?,
                        criado_em: r.get(7)?,
                        criado_por: r.get(8)?,
                        foto: r.get(9)?,
                    })
                },
            )
            .optional()?;
        let ch: Option<(Vec<u8>, i64, Vec<u8>, Vec<u8>)> = match &m {
            Some(m) => atual
                .query_row(
                    "SELECT sal, n, kek, embrulho FROM chave_usuario WHERE usuario_id = ?1",
                    [m.id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
                )
                .optional()?,
            None => None,
        };
        let codigo: Option<String> = match &m {
            Some(m) => atual
                .query_row(
                    "SELECT codigo FROM usuario_codigo WHERE usuario_id = ?1",
                    [m.id],
                    |r| r.get(0),
                )
                .optional()?,
            None => None,
        };
        (m, ch, codigo)
    };
    let Some(m) = m else { return Ok(()) };
    criar_tabelas(con_novo)?;
    let slot = chaves::slot_de(con_novo, &m.login)?;
    let tx = con_novo.transaction()?;
    // Saem o master do backup e quem, no backup, usa o login do master atual.
    let saem: Vec<i64> = {
        let mut st = tx.prepare("SELECT id FROM usuarios WHERE nivel >= ?1 OR login = ?2")?;
        let it = st.query_map(params![NIVEL_MASTER, m.login], |r| r.get(0))?;
        it.collect::<Result<_, _>>()?
    };
    for id in saem {
        for (tabela, coluna) in [
            ("usuario_prestadores", "usuario_id"),
            ("chave_usuario", "usuario_id"),
            ("usuario_codigo", "usuario_id"),
            ("usuarios", "id"),
        ] {
            tx.execute(&format!("DELETE FROM {tabela} WHERE {coluna} = ?1"), [id])?;
        }
    }
    // Mantém o id quando está livre (o registro e o "último prestador" o referenciam).
    let livre: Option<i64> = tx
        .query_row("SELECT 1 FROM usuarios WHERE id = ?1", [m.id], |r| r.get(0))
        .optional()?;
    let livre = livre.is_none();
    let novo_id = if livre {
        tx.execute(
            "INSERT INTO usuarios (id, login, nome, nivel, senha_salt, senha_hash, ativo, criado_em, \
             criado_por, foto) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![m.id, m.login, m.nome, m.nivel, m.senha_salt, m.senha_hash, m.ativo, m.criado_em, m.criado_por, m.foto],
        )?;
        m.id
    } else {
        tx.execute(
            "INSERT INTO usuarios (login, nome, nivel, senha_salt, senha_hash, ativo, criado_em, \
             criado_por, foto) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                m.login,
                m.nome,
                m.nivel,
                m.senha_salt,
                m.senha_hash,
                m.ativo,
                m.criado_em,
                m.criado_por,
                m.foto
            ],
        )?;
        tx.last_insert_rowid()
    };
    if let Some((sal, n, kek, embrulho)) = ch {
        tx.execute(
            "INSERT OR REPLACE INTO chave_usuario (usuario_id, slot, sal, n, kek, embrulho) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![novo_id, slot, sal, n, kek, embrulho],
        )?;
    }
    if let Some(codigo) = codigo {
        // O master leva o código dele; a conta do backup que usava o mesmo escolhe outro no
        // próximo acesso.
        tx.execute("DELETE FROM usuario_codigo WHERE codigo = ?1", [&codigo])?;
        tx.execute(
            "INSERT INTO usuario_codigo (usuario_id, codigo) VALUES (?1, ?2)",
            params![novo_id, codigo],
        )?;
    }
    tx.commit()?;
    Ok(())
}

/// Bytes da foto de perfil do usuário (None = sem foto).
pub fn get_foto(usuario_id: i64) -> Res<Option<Vec<u8>>> {
    let con = db()?;
    let foto: Option<Option<Vec<u8>>> = con
        .query_row(
            "SELECT foto FROM usuarios WHERE id = ?1",
            [usuario_id],
            |r| r.get(0),
        )
        .optional()?;
    Ok(foto.flatten())
}

/// Grava/remove a foto de perfil (None remove).
pub fn set_foto(usuario_id: i64, dados: Option<&[u8]>) -> Res<()> {
    if dados.is_some_and(|d| d.len() > FOTO_MAX_BYTES) {
        return Err(Erro::valor(
            "A imagem é muito grande (máx. 3 MB). Use uma foto menor.",
        ));
    }
    let con = db()?;
    con.execute(
        "UPDATE usuarios SET foto = ?1 WHERE id = ?2",
        params![dados, usuario_id],
    )?;
    Ok(())
}

fn hash(senha: &str, sal: &[u8]) -> Vec<u8> {
    let mut saida = vec![0u8; 32];
    // Mesmo PBKDF2-HMAC-SHA256, salt, 200 mil iterações e saída; aproveita
    // a implementação nativa já vinculada. O caminho anterior continua disponível.
    if openssl::pkcs5::pbkdf2_hmac(
        senha.as_bytes(),
        sal,
        PBKDF2_ITER as usize,
        openssl::hash::MessageDigest::sha256(),
        &mut saida,
    )
    .is_err()
    {
        pbkdf2::pbkdf2_hmac::<Sha256>(senha.as_bytes(), sal, PBKDF2_ITER, &mut saida);
    }
    saida
}

#[cfg(test)]
mod testes_hash {
    use super::*;
    #[test]
    fn pbkdf2_nativo_preserva_hashes_existentes() {
        for senha in ["SenhaFicticia@2026", "Senha com ç e 日本語", "abc\0def", ""] {
            for sal in [&b"salt de teste"[..], &[0u8; 16][..], &[0x51u8; 32][..]] {
                let mut esperado = vec![0u8; 32];
                pbkdf2::pbkdf2_hmac::<Sha256>(senha.as_bytes(), sal, PBKDF2_ITER, &mut esperado);
                assert_eq!(hash(senha, sal), esperado);
            }
        }
    }
}

/// Comparação em tempo constante (o `secrets.compare_digest`).
fn iguais(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Login canônico: SOMENTE letras ASCII, em MAIÚSCULAS, sem acentos/números/símbolos, no máx.
/// LOGIN_MAX caracteres. É o que vai ao banco e é usado na comparação — por isso o login não
/// diferencia maiúsculas de minúsculas.
pub fn normalizar_login(login: &str) -> String {
    login
        .trim()
        .nfkd()
        .filter(|c| c.is_ascii_alphabetic())
        .map(|c| c.to_ascii_uppercase())
        .take(LOGIN_MAX)
        .collect()
}

/// Nome em MAIÚSCULAS, no máx. NOME_MAX caracteres (acentos preservados).
pub fn normalizar_nome(nome: &str) -> String {
    nome.trim().to_uppercase().chars().take(NOME_MAX).collect()
}

/// "" se a senha atende à política; senão a mensagem para mostrar ao usuário.
pub fn validar_senha(senha: &str) -> &'static str {
    let fraca = senha.chars().count() < SENHA_MIN
        || !senha.chars().any(char::is_uppercase)
        || !senha.chars().any(char::is_lowercase)
        || !senha.chars().any(char::is_numeric)
        || !senha
            .chars()
            .any(|c| !c.is_alphanumeric() && !c.is_whitespace());
    if fraca { POLITICA_SENHA } else { "" }
}

pub fn validar_credenciais_novas(login: &str, senha: &str, confirma: &str, nome: &str) -> String {
    if login.trim().chars().any(|c| !c.is_ascii_alphabetic()) {
        return "Login deve conter apenas letras (sem acentos, números ou símbolos).".into();
    }
    let n = normalizar_login(login).len();
    if !(3..=LOGIN_MAX).contains(&n) {
        return format!("Login deve ter de 3 a {LOGIN_MAX} letras.");
    }
    if nome.trim().chars().count() > NOME_MAX {
        return format!("Nome deve ter no máximo {NOME_MAX} caracteres.");
    }
    let politica = validar_senha(senha);
    if !politica.is_empty() {
        return politica.into();
    }
    if senha != confirma {
        return "As senhas não conferem.".into();
    }
    String::new()
}

pub fn tem_usuarios() -> Res<bool> {
    let con = db()?;
    let r: Option<i64> = con
        .query_row("SELECT 1 FROM usuarios LIMIT 1", [], |r| r.get(0))
        .optional()?;
    Ok(r.is_some())
}

pub fn autenticar(login: &str, senha: &str) -> Res<Option<Usuario>> {
    let login = normalizar_login(login);
    if login.is_empty() || senha.is_empty() {
        return Ok(None);
    }
    let linha: Option<(Usuario, Vec<u8>, Vec<u8>)> = {
        let con = db()?;
        con.query_row(
            &format!("SELECT {COLUNAS}, senha_salt, senha_hash FROM usuarios WHERE login = ?1"),
            [&login],
            |r| Ok((usuario(r)?, r.get(5)?, r.get(6)?)),
        )
        .optional()?
    };
    Ok(match linha {
        Some((u, sal, guardado)) if u.ativo && iguais(&hash(senha, &sal), &guardado) => Some(u),
        _ => None,
    })
}

/// Login completo. Com o banco trancado, a senha primeiro o ABRE (pela chave do usuário no
/// dados.key) e só então é conferida contra o cadastro; se a conferência falhar, o banco volta
/// a ficar trancado.
pub fn entrar(login: &str, senha: &str) -> Res<Option<Usuario>> {
    let login = normalizar_login(login);
    if login.is_empty() || senha.is_empty() {
        return Ok(None);
    }
    let mut abriu = false;
    if banco::estado() == "cifrado" && !banco::destrancado() {
        if !chaves::destrancar_com_usuario(&login, senha)? {
            return Ok(None);
        }
        abriu = true;
    }
    let u = autenticar(&login, senha)?;
    if u.is_none() && abriu {
        banco::trancar();
    }
    crate::permissoes::definir_sessao(u.as_ref())?;
    Ok(u)
}

/// Autorização por SENHA apenas (sem login): procura entre os usuários ATIVOS com nível >=
/// `nivel_minimo` algum cuja senha confira.
///
/// Devolve (usuário, ambíguo). ambíguo = 2+ usuários diferentes têm a MESMA senha (caso raro):
/// a ação é autorizada, mas o autor fica indeterminado — devolve-se o de MENOR nível que
/// satisfaz e quem chamou registra o aviso. O master (nível 4) satisfaz qualquer nível exigido.
pub fn autenticar_por_senha(senha: &str, nivel_minimo: i64) -> Res<(Option<Usuario>, bool)> {
    if senha.is_empty() {
        return Ok((None, false));
    }
    let linhas: Vec<(Usuario, Vec<u8>, Vec<u8>)> = {
        let con = db()?;
        let mut st = con.prepare(&format!(
            "SELECT {COLUNAS}, senha_salt, senha_hash FROM usuarios WHERE ativo = 1 AND nivel >= ?1 \
             ORDER BY nivel, id"
        ))?;
        let it = st.query_map([nivel_minimo], |r| Ok((usuario(r)?, r.get(5)?, r.get(6)?)))?;
        it.collect::<Result<_, _>>()?
    };
    let mut conferem = linhas
        .into_iter()
        .filter(|(_, sal, guardado)| iguais(&hash(senha, sal), guardado));
    match conferem.next() {
        None => Ok((None, false)),
        Some((u, _, _)) => Ok((Some(u), conferem.next().is_some())),
    }
}

/// Busca um usuário pelo login (único global).
pub fn por_login(login: &str) -> Res<Option<Usuario>> {
    let login = normalizar_login(login);
    if login.is_empty() {
        return Ok(None);
    }
    let con = db()?;
    Ok(con
        .query_row(
            &format!("SELECT {COLUNAS} FROM usuarios WHERE login = ?1"),
            [&login],
            usuario,
        )
        .optional()?)
}

/// Prestadores concedidos ao usuário (tabela usuario_prestadores), em ordem.
pub fn prestadores_vinculados(usuario_id: i64) -> Res<Vec<String>> {
    let con = db()?;
    let mut st = con.prepare(
        "SELECT prestador FROM usuario_prestadores WHERE usuario_id = ?1 AND prestador <> '' ORDER BY prestador",
    )?;
    let it = st.query_map([usuario_id], |r| r.get::<_, String>(0))?;
    Ok(it.collect::<Result<_, _>>()?)
}

/// Prestadores que o usuário pode alternar/operar. Para o master devolve [] — quem chama
/// interpreta como "todos os prestadores".
pub fn prestadores_permitidos(u: &Usuario) -> Res<Vec<String>> {
    if u.is_master() {
        return Ok(Vec::new());
    }
    let mut v = prestadores_vinculados(u.id)?;
    v.sort();
    Ok(v)
}

/// Concede a um usuário o direito de operar um prestador.
pub fn vincular_prestador(usuario_id: i64, prestador: &str, por: &Usuario) -> Res<()> {
    let prestador = prestador.trim();
    if prestador.is_empty() {
        return Err(Erro::valor("Prestador inválido."));
    }
    exigir_gerencia_de_vinculo(usuario_id, por)?;
    let con = db()?;
    con.execute(
        "INSERT OR IGNORE INTO usuario_prestadores (usuario_id, prestador) VALUES (?1, ?2)",
        params![usuario_id, prestador],
    )?;
    Ok(())
}

/// Remove o direito do usuário de operar um prestador.
pub fn desvincular_prestador(usuario_id: i64, prestador: &str, por: &Usuario) -> Res<()> {
    exigir_gerencia_de_vinculo(usuario_id, por)?;
    let con = db()?;
    con.execute(
        "DELETE FROM usuario_prestadores WHERE usuario_id = ?1 AND prestador = ?2",
        params![usuario_id, prestador.trim()],
    )?;
    Ok(())
}

fn exigir_gerencia_de_vinculo(usuario_id: i64, por: &Usuario) -> Res<()> {
    let alvo = por_id(usuario_id)?;
    if alvo.is_master() {
        return Err(Erro::valor("O master já opera todos os prestadores."));
    }
    if alvo.id == por.id {
        return Ok(());
    }
    exigir_gerencia(&alvo, por)
}

/// Prestador DELETADO: remove os vínculos de todos os usuários com ele. Os usuários em si
/// continuam.
pub fn esquecer_prestador(prestador: &str) -> Res<()> {
    let prestador = prestador.trim();
    if prestador.is_empty() {
        return Ok(());
    }
    let con = db()?;
    con.execute(
        "DELETE FROM usuario_prestadores WHERE prestador = ?1",
        [prestador],
    )?;
    Ok(())
}

/// Cadastra um usuário GLOBAL (independente de prestador). Os prestadores que ele pode operar
/// são definidos na criação. `criado_por = None` só no primeiro acesso (1º master, nível 4).
pub fn criar(
    login: &str,
    nome: &str,
    nivel: i64,
    senha: &str,
    prestadores: &[String],
    criado_por: Option<&Usuario>,
) -> Res<Usuario> {
    criar_com_codigo(login, nome, nivel, senha, prestadores, criado_por, None)
}

/// `criar` com o código de autorização gravado na mesma transação: código inválido ou já usado
/// não deixa a conta nascer.
pub fn criar_com_codigo(
    login: &str,
    nome: &str,
    nivel: i64,
    senha: &str,
    prestadores: &[String],
    criado_por: Option<&Usuario>,
    codigo: Option<&str>,
) -> Res<Usuario> {
    let codigo = codigo.map(normalizar_codigo).filter(|c| !c.is_empty());
    if codigo.as_deref().is_some_and(|c| !codigo_valido(c)) {
        return Err(Erro::valor(CODIGO_INVALIDO));
    }
    let login = normalizar_login(login);
    let nome = normalizar_nome(nome);
    let mut nivel = nivel;
    if login.len() < 3 {
        return Err(Erro::valor(
            "Login deve ter ao menos 3 letras (sem acentos, números ou símbolos).",
        ));
    }
    if nome.is_empty() {
        return Err(Erro::valor("Informe o nome do usuário."));
    }
    if !validar_senha(senha).is_empty() {
        return Err(Erro::valor(validar_senha(senha)));
    }
    // sem duplicatas, na ordem em que vieram
    let mut vinculos: Vec<String> = Vec::new();
    for p in prestadores
        .iter()
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
    {
        if !vinculos.iter().any(|v| v == p) {
            vinculos.push(p.to_string());
        }
    }
    match criado_por {
        None => {
            nivel = NIVEL_MASTER;
            vinculos.clear();
        }
        Some(por) => {
            if !(1..=3).contains(&nivel) {
                return Err(Erro::valor(
                    "Novos usuários devem ter nível 1, 2 ou 3 (o master é único).",
                ));
            }
            if nivel >= por.nivel {
                return Err(Erro::valor(format!(
                    "{} só cadastra usuários de nível inferior ao seu.",
                    por.nivel_nome()
                )));
            }
        }
    }
    let novo_id = {
        let mut con = db()?;
        let sal = chaves::aleatorio(16);
        let senha_hash = hash(senha, &sal);
        let tx = con.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if criado_por.is_none()
            && tx.query_row("SELECT EXISTS(SELECT 1 FROM usuarios)", [], |r| {
                r.get::<_, bool>(0)
            })?
        {
            return Err(Erro::valor(
                "Cadastro inicial indisponível: já existem usuários.",
            ));
        }
        let inserido = tx.execute(
            "INSERT INTO usuarios (login, nome, nivel, senha_salt, senha_hash, ativo, criado_em, criado_por) \
             VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?7)",
            params![
                login,
                nome,
                nivel,
                sal,
                senha_hash,
                Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
                criado_por.map(|p| p.login.as_str()).unwrap_or("bootstrap"),
            ],
        );
        match inserido {
            Ok(_) => {}
            Err(rusqlite::Error::SqliteFailure(e, _))
                if e.code == rusqlite::ErrorCode::ConstraintViolation =>
            {
                return Err(Erro::valor(format!(
                    "Já existe um usuário com o login '{login}'."
                )));
            }
            Err(e) => return Err(e.into()),
        }
        let id = tx.last_insert_rowid();
        for p in &vinculos {
            tx.execute(
                "INSERT OR IGNORE INTO usuario_prestadores (usuario_id, prestador) VALUES (?1, ?2)",
                params![id, p],
            )?;
        }
        if let Some(c) = &codigo {
            gravar_codigo(&tx, id, c)?;
        }
        tx.commit()?;
        id
    };
    if banco::destrancado() {
        chaves::definir_senha(novo_id, &login, senha)?;
    }
    let novo = Usuario {
        id: novo_id,
        login,
        nome,
        nivel,
        ativo: true,
    };
    if criado_por.is_none() {
        crate::permissoes::definir_sessao(Some(&novo))?;
    }
    Ok(novo)
}

pub fn listar() -> Res<Vec<Usuario>> {
    let con = db()?;
    let mut st = con.prepare(&format!(
        "SELECT {COLUNAS} FROM usuarios ORDER BY nivel DESC, login"
    ))?;
    let it = st.query_map([], usuario)?;
    Ok(it.collect::<Result<_, _>>()?)
}

pub fn por_id(usuario_id: i64) -> Res<Usuario> {
    let con = db()?;
    por_id_em(&con, usuario_id)
}

fn por_id_em(con: &Connection, usuario_id: i64) -> Res<Usuario> {
    con.query_row(
        &format!("SELECT {COLUNAS} FROM usuarios WHERE id = ?1"),
        [usuario_id],
        usuario,
    )
    .optional()?
    .ok_or_else(|| Erro::valor("Usuário não encontrado."))
}

fn exigir_gerencia(alvo: &Usuario, por: &Usuario) -> Res<()> {
    // Usuários são globais (independem de prestador); a regra é só de nível.
    if alvo.nivel >= por.nivel {
        return Err(Erro::valor(format!(
            "{} só gerencia usuários de nível inferior ao seu.",
            por.nivel_nome()
        )));
    }
    Ok(())
}

fn ativos_master() -> Res<i64> {
    let con = db()?;
    Ok(con.query_row(
        "SELECT COUNT(*) FROM usuarios WHERE nivel = ?1 AND ativo = 1",
        [NIVEL_MASTER],
        |r| r.get(0),
    )?)
}

pub fn definir_ativo(usuario_id: i64, ativo: bool, por: &Usuario) -> Res<()> {
    let alvo = por_id(usuario_id)?;
    exigir_gerencia(&alvo, por)?;
    if !ativo && alvo.is_master() && alvo.ativo && ativos_master()? <= 1 {
        return Err(Erro::valor(
            "Não é possível desativar o último master ativo.",
        ));
    }
    {
        let con = db()?;
        con.execute(
            "UPDATE usuarios SET ativo = ?1 WHERE id = ?2",
            params![ativo as i64, usuario_id],
        )?;
    }
    if banco::destrancado() {
        chaves::sincronizar()?; // usuário inativo não tem chave no dados.key
    }
    Ok(())
}

pub fn promover(usuario_id: i64, por: &Usuario) -> Res<Usuario> {
    let alvo = por_id(usuario_id)?;
    exigir_gerencia(&alvo, por)?;
    let novo = alvo.nivel + 1;
    if novo > 3 {
        return Err(Erro::valor(
            "O nível máximo de promoção é 3 (o master é único).",
        ));
    }
    if novo >= por.nivel {
        return Err(Erro::valor(format!(
            "{} só promove até o nível {}.",
            por.nivel_nome(),
            por.nivel - 1
        )));
    }
    {
        let con = db()?;
        con.execute(
            "UPDATE usuarios SET nivel = ?1 WHERE id = ?2",
            params![novo, alvo.id],
        )?;
    }
    por_id(usuario_id)
}

pub fn rebaixar(usuario_id: i64, por: &Usuario) -> Res<Usuario> {
    let alvo = por_id(usuario_id)?;
    exigir_gerencia(&alvo, por)?;
    if alvo.nivel <= 1 {
        return Err(Erro::valor(format!("'{}' já é nível 1.", alvo.login)));
    }
    {
        let con = db()?;
        con.execute(
            "UPDATE usuarios SET nivel = ?1 WHERE id = ?2",
            params![alvo.nivel - 1, alvo.id],
        )?;
    }
    por_id(usuario_id)
}

pub fn excluir(usuario_id: i64, por: &Usuario) -> Res<()> {
    let alvo = por_id(usuario_id)?;
    exigir_gerencia(&alvo, por)?;
    if alvo.is_master() && ativos_master()? <= 1 {
        return Err(Erro::valor("Não é possível excluir o último master."));
    }
    {
        let mut con = db()?;
        let tx = con.transaction()?;
        // O ON DELETE CASCADE da tabela não roda (o SQLite só aplica chave estrangeira com
        // PRAGMA foreign_keys=ON): os vínculos são apagados aqui.
        tx.execute(
            "DELETE FROM usuario_prestadores WHERE usuario_id = ?1",
            [alvo.id],
        )?;
        tx.execute("DELETE FROM usuario_codigo WHERE usuario_id = ?1", [alvo.id])?;
        tx.execute("DELETE FROM usuarios WHERE id = ?1", [alvo.id])?;
        tx.commit()?;
    }
    if banco::destrancado() {
        chaves::remover(alvo.id)?;
    }
    Ok(())
}

fn gravar_senha(usuario_id: i64, nova_senha: &str) -> Res<()> {
    if !validar_senha(nova_senha).is_empty() {
        return Err(Erro::valor(validar_senha(nova_senha)));
    }
    let sal = chaves::aleatorio(16);
    let login: Option<String> = {
        let con = db()?;
        con.execute(
            "UPDATE usuarios SET senha_salt = ?1, senha_hash = ?2 WHERE id = ?3",
            params![sal, hash(nova_senha, &sal), usuario_id],
        )?;
        con.query_row(
            "SELECT login FROM usuarios WHERE id = ?1",
            [usuario_id],
            |r| r.get(0),
        )
        .optional()?
    };
    if let Some(login) = login {
        if banco::destrancado() {
            chaves::definir_senha(usuario_id, &login, nova_senha)?;
        }
    }
    Ok(())
}

pub fn redefinir_senha(usuario_id: i64, nova_senha: &str, por: &Usuario) -> Res<()> {
    let alvo = por_id(usuario_id)?;
    exigir_gerencia(&alvo, por)?;
    gravar_senha(usuario_id, nova_senha)
}

pub(crate) fn redefinir_codigo(usuario_id: i64, codigo: &str, por: &Usuario) -> Res<String> {
    let mut con = db()?;
    let tx = con.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let responsavel = por_id_em(&tx, por.id)?;
    if !responsavel.ativo || responsavel.nivel != por.nivel || responsavel.login != por.login {
        return Err(Erro::valor("A autorização mudou. Autorize a operação novamente."));
    }
    exigir_gerencia(&por_id_em(&tx, usuario_id)?, &responsavel)?;
    let gravado = gravar_codigo(&tx, usuario_id, codigo)?;
    tx.commit()?;
    Ok(gravado)
}

pub fn trocar_propria_senha(usuario: &Usuario, senha_atual: &str, nova_senha: &str) -> Res<()> {
    if autenticar(&usuario.login, senha_atual)?.is_none() {
        return Err(Erro::valor("Senha atual incorreta."));
    }
    gravar_senha(usuario.id, nova_senha)
}

/// Login do usuário master (nível 4) — exibido na tela de redefinição.
pub fn master_login() -> Res<String> {
    let con = db()?;
    let l: Option<String> = con
        .query_row(
            "SELECT login FROM usuarios WHERE nivel >= ?1 ORDER BY ativo DESC, id LIMIT 1",
            [NIVEL_MASTER],
            |r| r.get(0),
        )
        .optional()?;
    Ok(l.unwrap_or_default())
}

/// Redefine a senha (e, se informados, o LOGIN e o NOME) do usuário MASTER e o REATIVA. A
/// autorização vem da SENHA MESTRA, com que a tela de acesso abre o banco ANTES de chamar aqui —
/// não há usuário logado nesse momento.
pub fn redefinir_senha_master(nova_senha: &str, novo_login: &str, novo_nome: &str) -> Res<Usuario> {
    let atual: Option<(i64, String)> = {
        let con = db()?;
        con.query_row(
            "SELECT id, login FROM usuarios WHERE nivel >= ?1 ORDER BY ativo DESC, id LIMIT 1",
            [NIVEL_MASTER],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?
    };
    let Some((uid, login_atual)) = atual else {
        return Err(Erro::valor("Não existe usuário master cadastrado."));
    };
    let informou_login = !novo_login.trim().is_empty();
    let login = if informou_login {
        normalizar_login(novo_login)
    } else {
        String::new()
    };
    if informou_login && login.len() < 3 {
        return Err(Erro::valor(format!(
            "Login deve ter de 3 a {LOGIN_MAX} letras."
        )));
    }
    let nome = if novo_nome.trim().is_empty() {
        String::new()
    } else {
        normalizar_nome(novo_nome)
    };
    // Valida a duplicidade de login ANTES de gravar qualquer coisa.
    if !login.is_empty() && login != login_atual {
        let con = db()?;
        let ja: Option<i64> = con
            .query_row(
                "SELECT 1 FROM usuarios WHERE login = ?1 AND id <> ?2",
                params![login, uid],
                |r| r.get(0),
            )
            .optional()?;
        if ja.is_some() {
            return Err(Erro::valor(format!(
                "Já existe um usuário com o login '{login}'."
            )));
        }
    }
    if !validar_senha(nova_senha).is_empty() {
        return Err(Erro::valor(validar_senha(nova_senha)));
    }
    {
        let mut con = db()?;
        let tx = con.transaction()?;
        if !login.is_empty() {
            tx.execute(
                "UPDATE usuarios SET login = ?1 WHERE id = ?2",
                params![login, uid],
            )?;
        }
        if !nome.is_empty() {
            tx.execute(
                "UPDATE usuarios SET nome = ?1 WHERE id = ?2",
                params![nome, uid],
            )?;
        }
        tx.execute("UPDATE usuarios SET ativo = 1 WHERE id = ?1", [uid])?;
        tx.commit()?;
    }
    gravar_senha(uid, nova_senha)?; // depois do login novo: a chave no dados.key usa o login
    por_id(uid)
}

#[cfg(test)]
mod testes_codigo {
    use super::*;
    use std::collections::HashSet;

    fn ocupados(lista: &[&str]) -> HashSet<String> {
        lista.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn normaliza_sem_diferenciar_maiusculas() {
        assert_eq!(normalizar_codigo(" ad "), "AD");
        assert_eq!(normalizar_codigo("a-1x"), "A1");
        assert!(codigo_valido("Z9"));
        assert!(!codigo_valido("A"));
        assert!(!codigo_valido("Ç1"));
    }

    #[test]
    fn sugere_vizinhos_e_invertido() {
        assert_eq!(sugerir_codigos("ad", &ocupados(&["AD"])), ["AE", "AC", "DA"]);
        assert_eq!(sugerir_codigos("12", &ocupados(&["12"])), ["13", "11", "21"]);
        assert_eq!(sugerir_codigos("AD", &ocupados(&["AD", "AE", "DA"])), ["AC", "AF", "AB"]);
        // Fim do alfabeto: sem vizinho seguinte, segue pelos anteriores.
        assert_eq!(sugerir_codigos("ZZ", &ocupados(&["ZZ"])), ["ZY", "ZX", "YZ"]);
        assert!(sugerir_codigos("A", &ocupados(&[])).len() == 0);
    }

    #[test]
    fn nunca_sugere_mais_de_tres_nem_ocupados() {
        let todos: Vec<String> = ALFABETO_CODIGO
            .iter()
            .flat_map(|&a| ALFABETO_CODIGO.iter().map(move |&b| String::from_utf8(vec![a, b]).unwrap()))
            .collect();
        let mut quase: HashSet<String> = todos.iter().cloned().collect();
        quase.remove("Q7");
        assert_eq!(sugerir_codigos("AD", &quase), ["Q7"]);
        let cheio: HashSet<String> = todos.into_iter().collect();
        assert!(sugerir_codigos("AD", &cheio).is_empty());
    }
}
