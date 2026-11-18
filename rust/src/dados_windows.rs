//! Transporte local entre a interface instalada e o serviço que possui os bancos.
use std::cell::RefCell;
use std::ffi::{OsStr, OsString, c_void};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::windows::{
    ffi::OsStrExt,
    io::{AsRawHandle, FromRawHandle, OwnedHandle},
};
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::sync::{
    Arc, Mutex, OnceLock,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use windows_service::{
    define_windows_service,
    service::{
        ServiceAccess, ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState,
        ServiceStatus, ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
    service_dispatcher,
    service_manager::{ServiceManager, ServiceManagerAccess},
};
use windows_sys::Win32::{
    Foundation::{
        ERROR_NO_DATA, ERROR_PIPE_CONNECTED, ERROR_PIPE_LISTENING, HANDLE, INVALID_HANDLE_VALUE,
        LocalFree, WAIT_TIMEOUT,
    },
    Security::{
        Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW, RevertToSelf,
        SECURITY_ATTRIBUTES, TOKEN_IMPERSONATE, TOKEN_QUERY,
    },
    Storage::FileSystem::{
        CreateFileW, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_READ_DATA, FILE_WRITE_DATA, OPEN_EXISTING,
        PIPE_ACCESS_DUPLEX, SECURITY_IMPERSONATION, SECURITY_SQOS_PRESENT, SYNCHRONIZE,
    },
    System::{
        Pipes::{
            ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, GetNamedPipeClientProcessId,
            GetNamedPipeServerProcessId, ImpersonateNamedPipeClient, PIPE_NOWAIT,
            PIPE_REJECT_REMOTE_CLIENTS, PIPE_WAIT, PeekNamedPipe, SetNamedPipeHandleState,
        },
        Threading::{
            GetCurrentThread, OpenProcess, OpenThreadToken, PROCESS_QUERY_LIMITED_INFORMATION,
            QueryFullProcessImageNameW, SetThreadToken, WaitForSingleObject,
        },
    },
};

use crate::{banco, caminhos, despacho, permissoes, registro};

pub const SERVICO: &str = "BaiacuNFSeDados";
const PIPE: &str = r"\\.\pipe\BaiacuNFSe.Dados.v1";
const MAX_QUADRO: usize = 64 * 1024 * 1024;
const CONEXOES: usize = 32;

define_windows_service!(entrada, servico_main);

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Pedido {
    versao: String,
    metodo: String,
    args: Value,
    temp: PathBuf,
}

struct Identidade {
    token: OwnedHandle,
    temp: PathBuf,
}

thread_local! {
    static OPERADOR: RefCell<Option<Identidade>> = const { RefCell::new(None) };
}

struct Reverter;
impl Drop for Reverter {
    fn drop(&mut self) {
        // Continuar com o token errado poderia acessar arquivos com privilégios indevidos.
        if unsafe { RevertToSelf() } == 0 {
            std::process::abort();
        }
    }
}

pub(crate) fn arquivo_usuario<T, E: From<io::Error>>(
    acao: impl FnOnce() -> Result<T, E>,
) -> Result<T, E> {
    OPERADOR.with(|operador| {
        let operador = operador.borrow();
        let Some(operador) = operador.as_ref() else {
            return acao();
        };
        // Segurança: o handle vem do cliente local verificado para esta requisição.
        if unsafe { SetThreadToken(null(), operador.token.as_raw_handle()) } == 0 {
            return Err(io::Error::last_os_error().into());
        }
        let _reverter = Reverter;
        acao()
    })
}

pub(crate) fn temporarios_usuario() -> Option<PathBuf> {
    OPERADOR.with(|v| v.borrow().as_ref().map(|i| i.temp.clone()))
}

pub(crate) fn cliente_instalado() -> bool {
    // A instalação é propriedade do executável deste processo. Conferir o marcador
    // em cada célula formatada fazia milhares de acessos ao disco na thread da tela.
    static INSTALADO: OnceLock<bool> = OnceLock::new();
    *INSTALADO.get_or_init(|| {
        caminhos::instalado_compartilhado()
            && std::env::args_os().nth(1).as_deref()
                != Some(OsStr::new("--baiacu-validar-inicializacao"))
            && servico_registrado()
    })
}

/// O serviço de dados existe nesta máquina. Uma instalação 1.0.0.2 atualizada pelo atualizador
/// automático (que não registra serviços) fica sem ele até alguém rodar o instalador: nesse caso
/// o programa segue no modelo anterior, abrindo os bancos de ProgramData no próprio processo.
pub(crate) fn servico_registrado() -> bool {
    ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
        .and_then(|scm| scm.open_service(SERVICO, ServiceAccess::QUERY_STATUS))
        .is_ok()
}

pub(crate) fn metodo_local(metodo: &str) -> bool {
    metodo.starts_with("texto.")
        // Baixar tabelas grava em logs/tabelas: só o serviço de dados pode.
        || (metodo.starts_with("catalogo.") && metodo != "catalogo.atualizar_tabelas")
        || matches!(
            metodo,
            "nucleo.versao"
                | "nucleo.raiz"
                | "pdf.abrir_no_leitor"
                | "pdf.aquecer_danfse"
                | "cofre.limpar_temporarios"
                | "ajuda.info"
                | "registro.situacao"
                | "registro.exportar_suporte"
                | "emissao.aquecer"
                | "usuarios.validar_senha"
                | "usuarios.validar_credenciais_novas"
                | "usuarios.normalizar_nome"
                | "usuarios.normalizar_login"
                | "consulta.municipios"
                | "consulta.url_nfse"
                | "consulta.url_nfse_completa"
                | "aparencia.validar"
                | "aparencia.normalizar"
                | "aparencia.hsv"
                | "aparencia.de_hsv"
                | "aparencia.superficies"
                | "aparencia.temas"
                | "aparencia.limites"
        )
}

fn wide(texto: impl AsRef<OsStr>) -> Vec<u16> {
    texto.as_ref().encode_wide().chain(Some(0)).collect()
}

fn invalido(msg: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

fn quadro_de(valor: &impl Serialize) -> io::Result<Vec<u8>> {
    let corpo = serde_json::to_vec(valor)?;
    if corpo.len() > MAX_QUADRO {
        return Err(invalido(
            "O tamanho da mensagem excede o limite do serviço de dados.",
        ));
    }
    Ok(corpo)
}

fn enviar(canal: &mut File, valor: &impl Serialize) -> io::Result<()> {
    let corpo = quadro_de(valor)?;
    canal.write_all(&(corpo.len() as u32).to_le_bytes())?;
    canal.write_all(&corpo)
}

fn receber<T: serde::de::DeserializeOwned>(canal: &mut File) -> io::Result<T> {
    let mut tamanho = [0; 4];
    canal.read_exact(&mut tamanho)?;
    let tamanho = u32::from_le_bytes(tamanho) as usize;
    if tamanho == 0 || tamanho > MAX_QUADRO {
        return Err(invalido("Tamanho de mensagem inválido."));
    }
    let mut corpo = vec![0; tamanho];
    canal.read_exact(&mut corpo)?;
    Ok(serde_json::from_slice(&corpo)?)
}

fn abrir_canal(nome: &[u16]) -> HANDLE {
    // Segurança: só solicitamos leitura e escrita de dados, sem direito de criar instâncias.
    unsafe {
        CreateFileW(
            nome.as_ptr(),
            FILE_READ_DATA | FILE_WRITE_DATA | SYNCHRONIZE,
            0,
            null(),
            OPEN_EXISTING,
            SECURITY_SQOS_PRESENT | SECURITY_IMPERSONATION,
            null_mut(),
        )
    }
}

fn conectar() -> io::Result<File> {
    let scm = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
        .map_err(io::Error::other)?;
    let servico = scm
        .open_service(SERVICO, ServiceAccess::QUERY_STATUS | ServiceAccess::START)
        .map_err(io::Error::other)?;
    if servico
        .query_status()
        .map_err(io::Error::other)?
        .current_state
        == ServiceState::Stopped
    {
        // Outra chamada pode ter iniciado entre a consulta e o pedido de partida.
        let _ = servico.start::<&str>(&[]);
    }
    let nome = wide(PIPE);
    let limite = Instant::now() + Duration::from_secs(8);
    loop {
        let handle = abrir_canal(&nome);
        if handle != INVALID_HANDLE_VALUE {
            let canal = unsafe { File::from_raw_handle(handle) };
            let mut pid = 0;
            if unsafe { GetNamedPipeServerProcessId(handle, &mut pid) } == 0 {
                return Err(io::Error::last_os_error());
            }
            let estado = servico.query_status().map_err(io::Error::other)?;
            if estado.process_id == Some(pid) && estado.current_state == ServiceState::Running {
                return Ok(canal);
            }
            if estado.process_id.is_some_and(|real| real != pid) {
                return Err(invalido(
                    "O canal de dados não pertence ao serviço do Baiacu.",
                ));
            }
        }
        if Instant::now() >= limite {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "O serviço de dados não respondeu.",
            ));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

pub(crate) fn chamar(metodo: &str, args: &Value, avisar: despacho::Avisar) -> Value {
    let resultado = (|| -> io::Result<Value> {
        let mut canal = conectar()?;
        enviar(
            &mut canal,
            &Pedido {
                versao: crate::atualizacao::VERSAO.to_string(),
                metodo: metodo.to_string(),
                args: args.clone(),
                temp: std::env::temp_dir(),
            },
        )?;
        loop {
            let quadro: Value = receber(&mut canal)?;
            if let Some(aviso) = quadro.get("aviso") {
                avisar(aviso);
            } else {
                return Ok(quadro);
            }
        }
    })();
    resultado.unwrap_or_else(|erro| {
        json!({"erro":{
            "tipo":"ServicoDadosIndisponivel",
            "msg":format!("Serviço Baiacu NFSe - Dados indisponível: {erro}")
        }})
    })
}

struct Cliente {
    pid: u32,
    processo: OwnedHandle,
    tarefas: AtomicUsize,
}
impl Cliente {
    fn vivo(&self) -> bool {
        unsafe { WaitForSingleObject(self.processo.as_raw_handle(), 0) == WAIT_TIMEOUT }
    }
}

fn trancar() {
    let _ = permissoes::definir_sessao(None);
    banco::trancar();
    registro::definir_usuario(None, None);
}

fn abrir_processo(pid: u32, esperado: &Path) -> io::Result<OwnedHandle> {
    let processo = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, 0, pid) };
    if processo.is_null() {
        return Err(io::Error::last_os_error());
    }
    let processo = unsafe { OwnedHandle::from_raw_handle(processo) };
    let mut nome = vec![0; 32768];
    let mut tamanho = nome.len() as u32;
    if unsafe {
        QueryFullProcessImageNameW(processo.as_raw_handle(), 0, nome.as_mut_ptr(), &mut tamanho)
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    if !String::from_utf16_lossy(&nome[..tamanho as usize])
        .eq_ignore_ascii_case(&esperado.to_string_lossy())
    {
        return Err(invalido("Processo solicitante inválido."));
    }
    Ok(processo)
}

fn identificar(pipe: HANDLE, pid: u32, exe: &Path) -> io::Result<(OwnedHandle, OwnedHandle)> {
    if unsafe { ImpersonateNamedPipeClient(pipe) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let _reverter = Reverter;
    let processo = abrir_processo(pid, exe)?;
    let mut token = null_mut();
    if unsafe {
        OpenThreadToken(
            GetCurrentThread(),
            TOKEN_QUERY | TOKEN_IMPERSONATE,
            1,
            &mut token,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok((processo, unsafe { OwnedHandle::from_raw_handle(token) }))
}

fn resposta(pedido: Pedido, avisar: despacho::Avisar) -> Value {
    let metodo = pedido.metodo.as_str();
    if pedido.versao != crate::atualizacao::VERSAO {
        return json!({"erro":{"tipo":"ServicoDadosIncompativel",
            "msg":"O serviço de dados está em outra versão. Repare a instalação do Baiacu."}});
    }
    if metodo == "dados.autorizar_atualizacao" {
        let alvo = pedido.args["metodo"].as_str().unwrap_or_default();
        return match alvo {
            "atualizacao.baixar" | "atualizacao.instalar" => {
                match permissoes::checar_metodo(alvo, &pedido.args) {
                    Ok(()) => json!({"ok":null}),
                    Err(e) => json!({"erro":{"tipo":e.tipo,"msg":e.msg}}),
                }
            }
            _ => json!({"erro":{"tipo":"ValueError","msg":"Operação de atualização inválida."}}),
        };
    }
    if metodo_local(metodo)
        || matches!(
            metodo,
            "nucleo.definir_raiz" | "atualizacao.baixar" | "atualizacao.instalar"
        )
    {
        return json!({"erro":{"tipo":"ValueError","msg":"Operação indisponível no serviço de dados."}});
    }
    if !matches!(
        metodo,
        "banco.estado"
            | "banco.destrancado"
            | "banco.trancar"
            | "banco.get_meta"
            | "chaves.arquivo_integro"
            | "chaves.criar_banco"
            | "chaves.desfazer_criacao"
            | "chaves.destrancar_com_mestra"
            | "usuarios.entrar"
            | "usuarios.criar"
            | "usuarios.redefinir_senha_master"
            | "registro.registrar"
            | "registro.sincronizar"
    ) && !permissoes::sessao_autenticada()
    {
        return json!({"erro":{"tipo":"BancoTrancado","msg":"Entre no Baiacu para continuar."}});
    }
    despacho::chamar_avisando(metodo, &pedido.args, avisar)
}

fn atender(mut canal: File, estado: &Mutex<Option<Arc<Cliente>>>) -> io::Result<()> {
    let pipe = canal.as_raw_handle();
    let mut pid = 0;
    if unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) } == 0 {
        return Err(io::Error::last_os_error());
    }
    // Espera só pelo cabeçalho antes de autenticar o processo que escreveu no pipe.
    let limite = Instant::now() + Duration::from_secs(3);
    loop {
        let mut bytes = 0;
        if unsafe { PeekNamedPipe(pipe, null_mut(), 0, null_mut(), &mut bytes, null_mut()) } == 0 {
            return Err(io::Error::last_os_error());
        }
        if bytes >= 4 {
            break;
        }
        if Instant::now() >= limite {
            return Err(invalido("O cliente não iniciou a requisição."));
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    if unsafe { SetNamedPipeHandleState(pipe, &PIPE_WAIT, null(), null()) } == 0 {
        return Err(io::Error::last_os_error());
    }
    // A primeira leitura associa a identidade do cliente à instância do pipe.
    let mut tamanho = [0; 4];
    canal.read_exact(&mut tamanho)?;
    let exe = caminhos::programa().join(crate::atualizacao::NOME_EXE);
    let (processo, token) = identificar(pipe, pid, &exe)?;
    let tamanho = u32::from_le_bytes(tamanho) as usize;
    if tamanho == 0 || tamanho > MAX_QUADRO {
        return Err(invalido("Tamanho de pedido inválido."));
    }
    let mut corpo = vec![0; tamanho];
    canal.read_exact(&mut corpo)?;
    let pedido: Pedido = serde_json::from_slice(&corpo)?;
    let cliente = {
        let mut estado = estado
            .lock()
            .map_err(|_| invalido("Estado do serviço indisponível."))?;
        match estado.as_ref() {
            Some(c) if c.pid == pid && c.vivo() => Arc::clone(c),
            Some(c) if c.vivo() || c.tarefas.load(Ordering::Acquire) > 0 => {
                return enviar(
                    &mut canal,
                    &json!({"erro":{"tipo":"ServicoDadosOcupado",
                    "msg":"Outro aplicativo Baiacu tem uma sessão ou uma tarefa em andamento."}}),
                );
            }
            _ => {
                trancar();
                let cliente = Arc::new(Cliente {
                    pid,
                    processo,
                    tarefas: AtomicUsize::new(0),
                });
                *estado = Some(Arc::clone(&cliente));
                cliente
            }
        }
        .com_tarefa()
    };
    OPERADOR.with(|v| {
        *v.borrow_mut() = Some(Identidade {
            token,
            temp: pedido.temp.clone(),
        })
    });
    let canal = RefCell::new(canal);
    let avisar = |v: &Value| {
        let _ = enviar(&mut canal.borrow_mut(), &json!({"aviso":v}));
    };
    let resultado = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        resposta(pedido, &avisar)
    }))
    .unwrap_or_else(
        |_| json!({"erro":{"tipo":"RuntimeError","msg":"Falha interna no serviço de dados."}}),
    );
    drop(cliente);
    enviar(&mut canal.borrow_mut(), &resultado)
}

struct Tarefa(Arc<Cliente>);
impl Cliente {
    fn com_tarefa(self: Arc<Self>) -> Tarefa {
        self.tarefas.fetch_add(1, Ordering::AcqRel);
        Tarefa(self)
    }
}
impl Drop for Tarefa {
    fn drop(&mut self) {
        self.0.tarefas.fetch_sub(1, Ordering::AcqRel);
    }
}

fn criar_pipe(nome: &str, primeiro: bool) -> io::Result<File> {
    let mut descritor: *mut c_void = null_mut();
    // 0x100003 = SYNCHRONIZE | FILE_READ_DATA | FILE_WRITE_DATA, sem FILE_CREATE_PIPE_INSTANCE.
    let sddl = wide("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;SU)(A;;0x100003;;;AU)");
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descritor,
            null_mut(),
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    let seguranca = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descritor,
        bInheritHandle: 0,
    };
    let acesso = PIPE_ACCESS_DUPLEX
        | if primeiro {
            FILE_FLAG_FIRST_PIPE_INSTANCE
        } else {
            0
        };
    let handle = unsafe {
        CreateNamedPipeW(
            wide(nome).as_ptr(),
            acesso,
            PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
            (CONEXOES + 1) as u32,
            65536,
            65536,
            0,
            &seguranca,
        )
    };
    let erro = (handle == INVALID_HANDLE_VALUE).then(io::Error::last_os_error);
    unsafe { LocalFree(descritor) };
    match erro {
        Some(e) => Err(e),
        None => Ok(unsafe { File::from_raw_handle(handle) }),
    }
}

fn atender_clientes(
    parar: &AtomicBool,
    pronto: impl FnOnce() -> windows_service::Result<()>,
) -> io::Result<()> {
    let estado = Arc::new(Mutex::new(None::<Arc<Cliente>>));
    let ativas = Arc::new(AtomicUsize::new(0));
    let mut pipe = criar_pipe(PIPE, true)?;
    pronto().map_err(io::Error::other)?;
    while !parar.load(Ordering::Acquire) {
        let handle = pipe.as_raw_handle();
        if unsafe { ConnectNamedPipe(handle, null_mut()) } != 0 {
            // PIPE_NOWAIT também retorna sucesso ao começar a aceitar clientes.
            continue;
        }
        match io::Error::last_os_error().raw_os_error().map(|n| n as u32) {
            Some(ERROR_PIPE_CONNECTED) => {}
            Some(ERROR_NO_DATA) => {
                unsafe { DisconnectNamedPipe(handle) };
                continue;
            }
            Some(ERROR_PIPE_LISTENING) => {
                if let Ok(mut dono) = estado.lock()
                    && dono
                        .as_ref()
                        .is_some_and(|c| !c.vivo() && c.tarefas.load(Ordering::Acquire) == 0)
                {
                    trancar();
                    *dono = None;
                }
                std::thread::sleep(Duration::from_millis(8));
                continue;
            }
            _ => return Err(io::Error::last_os_error()),
        }
        if ativas.load(Ordering::Acquire) >= CONEXOES {
            unsafe { DisconnectNamedPipe(handle) };
            std::thread::sleep(Duration::from_millis(10));
            continue;
        }
        let canal = std::mem::replace(&mut pipe, criar_pipe(PIPE, false)?);
        let estado = Arc::clone(&estado);
        let contagem = Arc::clone(&ativas);
        ativas.fetch_add(1, Ordering::AcqRel);
        if std::thread::Builder::new()
            .name("baiacu-dados".into())
            .spawn(move || {
                let _ = atender(canal, &estado);
                contagem.fetch_sub(1, Ordering::AcqRel);
            })
            .is_err()
        {
            ativas.fetch_sub(1, Ordering::AcqRel);
        }
    }
    drop(pipe);
    while ativas.load(Ordering::Acquire) > 0 {
        std::thread::sleep(Duration::from_millis(100));
    }
    trancar();
    Ok(())
}

pub fn iniciar() -> windows_service::Result<()> {
    service_dispatcher::start(SERVICO, entrada)
}

fn servico_main(_: Vec<OsString>) {
    let parar = Arc::new(AtomicBool::new(false));
    let controle = Arc::clone(&parar);
    let Ok(handle) = service_control_handler::register(SERVICO, move |evento| match evento {
        ServiceControl::Stop | ServiceControl::Shutdown => {
            controle.store(true, Ordering::Release);
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        _ => ServiceControlHandlerResult::NotImplemented,
    }) else {
        return;
    };
    let status = |estado, saida| ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state: estado,
        controls_accepted: if estado == ServiceState::Running {
            ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN
        } else {
            ServiceControlAccept::empty()
        },
        exit_code: ServiceExitCode::Win32(saida),
        checkpoint: u32::from(estado == ServiceState::StartPending),
        wait_hint: if estado == ServiceState::StartPending {
            Duration::from_secs(5)
        } else {
            Duration::ZERO
        },
        process_id: None,
    };
    let resultado = (|| -> io::Result<()> {
        handle
            .set_service_status(status(ServiceState::StartPending, 0))
            .map_err(io::Error::other)?;
        let exe = std::env::current_exe()?;
        let programa = exe
            .parent()
            .and_then(Path::parent)
            .and_then(Path::parent)
            .ok_or_else(|| invalido("Pasta inválida para o serviço."))?;
        if !programa.join("installed.marker").is_file() {
            return Err(invalido(
                "O serviço precisa ser instalado pelo setup do Baiacu.",
            ));
        }
        let dados = std::env::var_os("ProgramData")
            .map(PathBuf::from)
            .ok_or_else(|| invalido("ProgramData indisponível."))?
            .join("Baiacu NFS-e");
        // O instalador já protege a árvore. Uma ACL ausente não deve ser confundida com base nova.
        if std::fs::read_dir(dados.join("database")).is_err() {
            return Err(invalido("Pasta dos bancos indisponível para o serviço."));
        }
        caminhos::definir_programa(programa.to_path_buf());
        caminhos::definir_raiz(dados);
        registro::registrar_panicos();
        registro::info("dados", "Serviço de dados iniciado.");
        atender_clientes(&parar, || {
            handle.set_service_status(status(ServiceState::Running, 0))
        })
    })();
    let _ = handle.set_service_status(status(
        ServiceState::Stopped,
        if resultado.is_ok() { 0 } else { 1064 },
    ));
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn pipe_impersona_o_cliente_e_transporta_resposta_maior_que_o_buffer() -> io::Result<()> {
        let nome = format!(r"\\.\pipe\BaiacuNFSe.Teste.{}", std::process::id());
        let mut servidor = criar_pipe(&nome, true)?;
        let nome = wide(nome);
        let cliente = std::thread::spawn(move || -> io::Result<Value> {
            let handle = abrir_canal(&nome);
            if handle == INVALID_HANDLE_VALUE {
                return Err(io::Error::last_os_error());
            }
            let mut cliente = unsafe { File::from_raw_handle(handle) };
            enviar(&mut cliente, &json!("login fictício"))?;
            receber(&mut cliente)
        });
        let handle = servidor.as_raw_handle();
        let limite = Instant::now() + Duration::from_secs(3);
        loop {
            if unsafe { ConnectNamedPipe(handle, null_mut()) } == 0
                && io::Error::last_os_error().raw_os_error() == Some(ERROR_PIPE_CONNECTED as i32)
            {
                break;
            }
            assert!(Instant::now() < limite, "o cliente não conectou");
            std::thread::sleep(Duration::from_millis(5));
        }
        if unsafe { SetNamedPipeHandleState(handle, &PIPE_WAIT, null(), null()) } == 0 {
            return Err(io::Error::last_os_error());
        }
        assert_eq!(receber::<Value>(&mut servidor)?, "login fictício");
        let (_, token) = identificar(handle, std::process::id(), &std::env::current_exe()?)?;
        OPERADOR.with(|v| {
            *v.borrow_mut() = Some(Identidade {
                token,
                temp: std::env::temp_dir(),
            })
        });
        arquivo_usuario(|| std::fs::metadata(std::env::current_exe()?))?;
        OPERADOR.with(|v| *v.borrow_mut() = None);

        let dados = json!("a".repeat(150_000));
        enviar(&mut servidor, &dados)?;
        drop(servidor);
        assert_eq!(cliente.join().expect("cliente de teste")?, dados);
        Ok(())
    }
}
