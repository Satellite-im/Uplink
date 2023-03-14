use std::{cell::RefCell, rc::Rc, sync::Arc};

use dioxus_desktop::DesktopContext;
use dioxus_hooks::ProvidedStateInner;
use tokio::sync::{
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex,
};

use common::state::{Action, State};
use uuid::Uuid;

pub type WindowManagerCmdTx = UnboundedSender<WindowManagerCmd>;
pub type WindowManagerCmdRx = Arc<Mutex<UnboundedReceiver<WindowManagerCmd>>>;

pub struct WindowManagerCmdChannels {
    pub tx: WindowManagerCmdTx,
    pub rx: WindowManagerCmdRx,
}

#[derive(Clone, Copy)]
#[allow(clippy::enum_variant_names)]
pub enum WindowManagerCmd {
    ClosePopout,
    CloseDebugLogger,
    CloseFilePreview,
    ForgetFilePreview(Uuid),
}

pub async fn handle_cmd(
    state: Rc<RefCell<ProvidedStateInner<State>>>,
    cmd: WindowManagerCmd,
    desktop: DesktopContext,
) {
    match cmd {
        WindowManagerCmd::ClosePopout => {
            if let Ok(s) = state.try_borrow_mut() {
                s.write().mutate(Action::ClearCallPopout(desktop));
            } else {
                //todo: add logging
            }
        }
        WindowManagerCmd::CloseDebugLogger => {
            if let Ok(s) = state.try_borrow_mut() {
                s.write().mutate(Action::ClearDebugLogger(desktop));
            } else {
                //todo: add logging
            }
        }
        WindowManagerCmd::CloseFilePreview => {
            if let Ok(s) = state.try_borrow_mut() {
                s.write().mutate(Action::ClearFilePreviews(desktop));
            } else {
                //todo: add logging
            }
        }
        WindowManagerCmd::ForgetFilePreview(id) => {
            if let Ok(s) = state.try_borrow_mut() {
                s.write().mutate(Action::ForgetFilePreview(id));
            } else {
                //todo: add logging
            }
        }
    }
}
