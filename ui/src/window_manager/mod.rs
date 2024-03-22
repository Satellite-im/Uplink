use std::sync::Arc;

use dioxus::signals::Signal;
use dioxus_desktop::DesktopContext;
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

#[derive(Clone, Copy, Debug)]
#[allow(clippy::enum_variant_names)]
pub enum WindowManagerCmd {
    ClosePopout,
    CloseDebugLogger,
    ForgetFilePreview(Uuid),
}

pub async fn handle_cmd(state: Signal<State>, cmd: WindowManagerCmd, desktop: DesktopContext) {
    log::trace!("window manager command: {cmd:?}");
    match cmd {
        WindowManagerCmd::ClosePopout => {
            state.write().mutate(Action::ClearCallPopout(desktop));
        }
        WindowManagerCmd::CloseDebugLogger => {
            state.write().mutate(Action::ClearDebugLogger(desktop));
        }
        WindowManagerCmd::ForgetFilePreview(id) => {
            state.write().mutate(Action::ForgetFilePreview(id));
        }
    }
}
