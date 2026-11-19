//! O processo da interface escolhe o contexto pelo PID autenticado no pipe.
use std::collections::BTreeMap;
use std::ops::{Deref, DerefMut};
use std::sync::{LockResult, Mutex, MutexGuard, PoisonError};

#[cfg(windows)]
thread_local! {
    static CLIENTE: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

pub(crate) fn atual() -> u32 {
    #[cfg(windows)]
    return CLIENTE.with(std::cell::Cell::get);
    #[cfg(not(windows))]
    0
}

#[cfg(windows)]
pub(crate) fn com_cliente<T>(pid: u32, executar: impl FnOnce() -> T) -> T {
    struct Restaurar(u32);
    impl Drop for Restaurar {
        fn drop(&mut self) {
            CLIENTE.with(|cliente| cliente.set(self.0));
        }
    }
    let _restaurar = Restaurar(CLIENTE.with(|cliente| cliente.replace(pid)));
    executar()
}

pub(crate) struct PorCliente<T>(Mutex<BTreeMap<u32, T>>);

impl<T: Default> PorCliente<T> {
    pub(crate) const fn novo() -> Self {
        Self(Mutex::new(BTreeMap::new()))
    }

    pub(crate) fn lock(&self) -> LockResult<Guarda<'_, T>> {
        let pid = atual();
        let (mut estados, envenenado) = match self.0.lock() {
            Ok(estados) => (estados, false),
            Err(e) => (e.into_inner(), true),
        };
        estados.entry(pid).or_default();
        let guarda = Guarda { estados, pid };
        if envenenado {
            Err(PoisonError::new(guarda))
        } else {
            Ok(guarda)
        }
    }

    #[cfg(windows)]
    pub(crate) fn esquecer(&self, pid: u32) {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).remove(&pid);
    }
}

pub(crate) struct Guarda<'a, T> {
    estados: MutexGuard<'a, BTreeMap<u32, T>>,
    pid: u32,
}

impl<T> Deref for Guarda<'_, T> {
    type Target = T;

    fn deref(&self) -> &T {
        &self.estados[&self.pid]
    }
}

impl<T> DerefMut for Guarda<'_, T> {
    fn deref_mut(&mut self) -> &mut T {
        self.estados.get_mut(&self.pid).expect("contexto selecionado")
    }
}
