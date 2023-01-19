use std::{cell::RefCell, rc::Rc, sync::Arc};

use dioxus_desktop::DesktopContext;
use dioxus_hooks::ProvidedStateInner;
use tokio::sync::{
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex,
};

use crate::{
    logger::logger::LOG_ACTIVE,
    state::{Action, State},
};

pub type WindowManagerCmdTx = UnboundedSender<WindowManagerCmd>;
pub type WindowManagerCmdRx = Arc<Mutex<UnboundedReceiver<WindowManagerCmd>>>;

pub struct WindowManagerCmdChannels {
    pub tx: WindowManagerCmdTx,
    pub rx: WindowManagerCmdRx,
}

pub enum WindowManagerCmd {
    ClosePopout,
    CloseDebugLogger,
}

pub async fn handle_cmd(
    state: Rc<RefCell<ProvidedStateInner<State>>>,
    cmd: WindowManagerCmd,
    desktop: DesktopContext,
) {
    match cmd {
        WindowManagerCmd::ClosePopout => {
            if let Ok(s) = state.try_borrow_mut() {
                s.write().mutate(Action::ClearPopout(desktop));
            } else {
                //todo: add logging
            }
        }
        WindowManagerCmd::CloseDebugLogger => {
            if let Ok(s) = state.try_borrow_mut() {
                s.write().mutate(Action::ClearDebugLogger(desktop));
                *LOG_ACTIVE.write() = false;
            } else {
                //todo: add logging
            }
        }
    }
}
