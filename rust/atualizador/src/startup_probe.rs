use baiacu_atualizador::{EXE, Result};
use std::{
    ffi::OsStr,
    io,
    mem::size_of,
    os::windows::{
        ffi::OsStrExt,
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
    },
    path::Path,
    ptr::{null, null_mut},
};
use windows_sys::Win32::{
    Foundation::WAIT_OBJECT_0,
    System::{
        Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock},
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            SetInformationJobObject,
        },
        Threading::{
            CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateProcessAsUserW, CreateProcessW,
            GetExitCodeProcess, PROCESS_INFORMATION, ResumeThread, STARTUPINFOW, TerminateProcess,
            WaitForSingleObject,
        },
    },
};

pub fn check(root: &Path, token: Option<&OwnedHandle>) -> Result<()> {
    let wide = |s: &OsStr| s.encode_wide().chain(Some(0)).collect::<Vec<_>>();
    let exe = root.join(EXE);
    let application = wide(exe.as_os_str());
    let mut command = wide(OsStr::new(&format!(
        "\"{}\" --baiacu-validar-inicializacao",
        exe.display()
    )));
    let directory = wide(root.as_os_str());
    let mut desktop = wide(OsStr::new("winsta0\\default"));
    let mut startup = STARTUPINFOW {
        cb: size_of::<STARTUPINFOW>() as u32,
        ..Default::default()
    };
    let mut child = PROCESS_INFORMATION::default();
    let flags = CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT;

    unsafe {
        // O processo de teste também termina se o atualizador for interrompido.
        let job = CreateJobObjectW(null(), null());
        if job.is_null() {
            return Err(io::Error::last_os_error().into());
        }
        let job = OwnedHandle::from_raw_handle(job);
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if SetInformationJobObject(
            job.as_raw_handle(),
            JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        ) == 0
        {
            return Err(io::Error::last_os_error().into());
        }

        let created = if let Some(token) = token {
            let mut environment = null_mut();
            if CreateEnvironmentBlock(&mut environment, token.as_raw_handle(), 0) == 0 {
                return Err(io::Error::last_os_error().into());
            }
            startup.lpDesktop = desktop.as_mut_ptr();
            let result = CreateProcessAsUserW(
                token.as_raw_handle(),
                application.as_ptr(),
                command.as_mut_ptr(),
                null(),
                null(),
                0,
                flags,
                environment,
                directory.as_ptr(),
                &startup,
                &mut child,
            );
            let error = io::Error::last_os_error();
            DestroyEnvironmentBlock(environment);
            if result == 0 {
                return Err(error.into());
            }
            result
        } else {
            CreateProcessW(
                application.as_ptr(),
                command.as_mut_ptr(),
                null(),
                null(),
                0,
                flags,
                null(),
                directory.as_ptr(),
                &startup,
                &mut child,
            )
        };
        if created == 0 {
            return Err(io::Error::last_os_error().into());
        }
        let process = OwnedHandle::from_raw_handle(child.hProcess);
        let thread = OwnedHandle::from_raw_handle(child.hThread);
        if AssignProcessToJobObject(job.as_raw_handle(), process.as_raw_handle()) == 0
            || ResumeThread(thread.as_raw_handle()) == u32::MAX
        {
            let error = io::Error::last_os_error();
            TerminateProcess(process.as_raw_handle(), 1);
            WaitForSingleObject(process.as_raw_handle(), 5000);
            return Err(error.into());
        }
        if WaitForSingleObject(process.as_raw_handle(), 45_000) != WAIT_OBJECT_0 {
            // Aguarda liberar o executável antes de o rollback começar.
            drop(job);
            WaitForSingleObject(process.as_raw_handle(), 5000);
            return Err("A versão nova demorou demais para abrir.".into());
        }
        let mut exit_code = 0;
        if GetExitCodeProcess(process.as_raw_handle(), &mut exit_code) == 0 {
            return Err(io::Error::last_os_error().into());
        }
        if exit_code != 42 {
            return Err(
                format!("A versão nova não confirmou a abertura (código {exit_code}).").into(),
            );
        }
    }
    Ok(())
}
