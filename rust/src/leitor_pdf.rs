//! Comunicação direta com o Sumatra já iniciado por esta sessão.
//! O PID da conversa é conferido antes de enviar o arquivo; se não responder,
//! a tela usa a abertura normal. Não fica nenhum processo de aquecimento aberto.

#[cfg(not(windows))]
pub fn abrir(_: &str, _: u32) -> bool {
    false
}

#[cfg(windows)]
pub fn abrir(arquivo: &str, pid: u32) -> bool {
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::{
        System::DataExchange::*, UI::WindowsAndMessaging::GetWindowThreadProcessId,
    };
    if pid == 0 || !std::path::Path::new(arquivo).is_file() {
        return false;
    }
    unsafe extern "system" fn retorno(
        _: u32,
        _: u32,
        _: HCONV,
        _: HSZ,
        _: HSZ,
        _: HDDEDATA,
        _: usize,
        _: usize,
    ) -> HDDEDATA {
        std::ptr::null_mut()
    }
    struct Sessao {
        id: u32,
        servico: HSZ,
        topico: HSZ,
        lista: HCONVLIST,
    }
    impl Drop for Sessao {
        fn drop(&mut self) {
            // SAFETY: estes handles pertencem à sessão DDE desta thread.
            unsafe {
                if !self.lista.is_null() {
                    DdeDisconnectList(self.lista);
                }
                if !self.servico.is_null() {
                    DdeFreeStringHandle(self.id, self.servico);
                }
                if !self.topico.is_null() {
                    DdeFreeStringHandle(self.id, self.topico);
                }
                DdeUninitialize(self.id);
            }
        }
    }
    let wide = |s: &str| {
        s.encode_utf16()
            .chain(std::iter::once(0))
            .collect::<Vec<u16>>()
    };
    // SAFETY: todos os buffers terminam em zero e vivem até a transação síncrona
    // acabar. CONVINFO usa o layout oficial do Windows e seu tamanho é informado.
    unsafe {
        let mut id = 0;
        if DdeInitializeW(&mut id, Some(retorno), APPCMD_CLIENTONLY, 0) != 0 {
            return false;
        }
        let mut sessao = Sessao {
            id,
            servico: null_mut(),
            topico: null_mut(),
            lista: null_mut(),
        };
        sessao.servico = DdeCreateStringHandleW(id, wide("SUMATRA").as_ptr(), CP_WINUNICODE);
        sessao.topico = DdeCreateStringHandleW(id, wide("control").as_ptr(), CP_WINUNICODE);
        if sessao.servico.is_null() || sessao.topico.is_null() {
            return false;
        }
        sessao.lista = DdeConnectList(id, sessao.servico, sessao.topico, null_mut(), null());
        if sessao.lista.is_null() {
            return false;
        }
        let mut conversa = null_mut();
        loop {
            conversa = DdeQueryNextServer(sessao.lista, conversa);
            if conversa.is_null() {
                return false;
            }
            let mut info = CONVINFO {
                cb: std::mem::size_of::<CONVINFO>() as u32,
                ..Default::default()
            };
            if DdeQueryConvInfo(conversa, QID_SYNC, &mut info) == 0 {
                continue;
            }
            let mut servidor = 0;
            GetWindowThreadProcessId(info.hwndPartner, &mut servidor);
            if servidor != pid {
                continue;
            }
            let caminho = arquivo.replace('\\', "\\\\").replace('"', "\\\"");
            let comando = wide(&format!(
                "[Open(\"{caminho}\",1,1,1)][FullScreen(\"{caminho}\")]"
            ));
            return !DdeClientTransaction(
                comando.as_ptr().cast(),
                (comando.len() * 2) as u32,
                conversa,
                null_mut(),
                0,
                XTYP_EXECUTE,
                2000,
                null_mut(),
            )
            .is_null();
        }
    }
}
