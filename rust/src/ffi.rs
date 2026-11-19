//! Ponte com a tela (Flutter/Dart, por `dart:ffi`).
//!
//! A tela chama `nfse_chamar(id, metodo, args)`: o trabalho roda numa thread do núcleo e a
//! resposta volta por `retorno(id, json)` — uma função do Dart que pode ser chamada de
//! QUALQUER thread (`NativeCallable.listener`): a tela nunca fica parada esperando o disco, a
//! rede ou o scrypt. Quem recebe o texto o devolve com `nfse_liberar`.
//! `nfse_chamar_ja` é a versão que responde na hora, para o que é só memória.
use std::ffi::{CStr, CString, c_char};
use std::sync::RwLock;

use serde_json::{Value, json};

use crate::{caminhos, despacho};

type Retorno = extern "C" fn(id: i64, json: *mut c_char);

/// A função de retorno do Dart. Vira `None` em `nfse_encerrar`: depois que a tela fecha, chamar o
/// `NativeCallable.listener` é comportamento indefinido (derrubava o programa ao sair, c000041d).
/// Quem responde segura a leitura só enquanto entrega a resposta; o encerramento espera por ele.
static RETORNO: RwLock<Option<Retorno>> = RwLock::new(None);

/// Entrega `v` à tela, se ela ainda estiver ouvindo. Sem ouvinte, nada é alocado.
fn devolver(id: i64, v: &Value) {
    let guarda = RETORNO.read().unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(retorno) = *guarda {
        retorno(id, para_c(v));
    }
}

unsafe fn texto(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    // SAFETY: o Dart passa um texto UTF-8 terminado em zero, vivo durante a chamada.
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn para_c(v: &Value) -> *mut c_char {
    let s = v.to_string().replace('\0', "");
    CString::new(s)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn responder(metodo: &str, args: &str, avisar: despacho::Avisar) -> Value {
    let args: Value = if args.trim().is_empty() {
        json!({})
    } else {
        match serde_json::from_str(args) {
            Ok(v) => v,
            Err(e) => {
                return json!({ "erro": { "tipo": "ValueError", "msg": format!("argumentos inválidos: {e}") } });
            }
        }
    };
    // Um erro de programação numa chamada não pode derrubar o programa inteiro.
    let mut v = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(windows)]
        if crate::dados_windows::cliente_instalado() {
            if crate::dados_windows::metodo_local(metodo) {
                return despacho::chamar_local(metodo, &args, avisar);
            }
            if matches!(metodo, "atualizacao.baixar" | "atualizacao.instalar") {
                let permissao = crate::dados_windows::chamar(
                    "dados.autorizar_atualizacao", &json!({"metodo":metodo}), &|_| {},
                );
                if permissao.get("erro").is_some() {
                    return permissao;
                }
                return crate::despacho_diversos::executar(metodo, &args, avisar)
                    .map(despacho::envelope)
                    .unwrap_or_else(|| json!({"erro":{"tipo":"ValueError","msg":"Atualização inválida."}}));
            }
            return crate::dados_windows::chamar(metodo, &args, avisar);
        }
        despacho::chamar_avisando(metodo, &args, avisar)
    })) {
        Ok(v) => v,
        Err(p) => {
            let msg = p
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| p.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "erro interno".into());
            crate::registro::critico("nucleo", &format!("Falha interna em {metodo}: {msg}"));
            json!({ "erro": { "tipo": "RuntimeError", "msg": format!("Falha interna: {msg}") } })
        }
    };
    // "Acesso negado. (os error 5)" e afins chegam à tela em português claro.
    if let Some(msg) = v.pointer_mut("/erro/msg")
        && let Some(texto) = msg.as_str()
        && texto.contains("(os error ")
    {
        *msg = Value::String(baiacu_atualizador::clarear_os(texto));
    }
    v
}

/// Uma vez, ao abrir: a pasta raiz (database/, logs/, configs/) e a função de retorno do Dart.
///
/// # Safety
/// `raiz` deve ser nulo ou apontar para UTF-8 terminado em zero, vivo durante
/// a chamada. O callback deve continuar válido enquanto houver tarefas do núcleo.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nfse_iniciar(raiz: *const c_char, retorno: Retorno) {
    // SAFETY: os ponteiros obedecem ao contrato da entrada FFI.
    let raiz = unsafe { texto(raiz) };
    if !raiz.is_empty() {
        caminhos::definir_raiz(raiz);
    }
    crate::registro::registrar_panicos();
    *RETORNO.write().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(retorno);
}

/// A tela vai fechar: nenhuma resposta é mais entregue. Volta só depois que quem estava
/// entregando uma resposta terminou — então o Dart pode fechar o `NativeCallable` com segurança.
/// O trabalho que ainda corre continua (e termina com o processo); só a resposta é descartada.
#[unsafe(no_mangle)]
pub extern "C" fn nfse_encerrar() {
    *RETORNO.write().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    crate::registro::info("app", "Tela encerrada: respostas do núcleo desligadas.");
}

/// Chamada assíncrona: a resposta chega por `retorno(id, json)`.
///
/// # Safety
/// `metodo` e `args` devem ser nulos ou textos UTF-8 terminados em zero e
/// válidos durante esta chamada. Ambos são copiados antes de iniciar a thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nfse_chamar(id: i64, metodo: *const c_char, args: *const c_char) {
    // SAFETY: o chamador mantém os dois textos vivos até esta cópia terminar.
    let (metodo, args) = unsafe { (texto(metodo), texto(args)) };
    let trabalho = move || {
        // andamento: chega pelo mesmo retorno, como {"aviso": ...}, antes da resposta final
        let avisar = |v: &Value| devolver(id, &json!({ "aviso": v }));
        let resposta = responder(&metodo, &args, &avisar);
        devolver(id, &resposta);
    };
    if std::thread::Builder::new()
        .name("nucleo".into())
        .spawn(trabalho)
        .is_err()
    {
        devolver(
            id,
            &json!({ "erro": { "tipo": "OSError", "msg": "não foi possível iniciar a tarefa" } }),
        );
    }
}

/// Chamada que responde na hora (na thread de quem chamou). Só para o que não espera nada.
///
/// # Safety
/// `metodo` e `args` devem seguir o mesmo contrato UTF-8 de `nfse_chamar`.
/// O resultado pertence ao núcleo e deve ser devolvido uma vez a `nfse_liberar`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nfse_chamar_ja(metodo: *const c_char, args: *const c_char) -> *mut c_char {
    // SAFETY: os dois textos são válidos durante a chamada, como documentado.
    let (metodo, args) = unsafe { (texto(metodo), texto(args)) };
    para_c(&responder(&metodo, &args, &|_| {}))
}

/// Devolve ao núcleo um texto recebido dele.
///
/// # Safety
/// `p` deve ser nulo ou um resultado deste núcleo ainda não liberado; nenhum
/// outro ponteiro pode ser passado, e o chamador não pode usar `p` após a chamada.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nfse_liberar(p: *mut c_char) {
    if !p.is_null() {
        // SAFETY: o ponteiro saiu de `CString::into_raw` em `para_c` e é liberado uma vez só.
        drop(unsafe { CString::from_raw(p) });
    }
}
