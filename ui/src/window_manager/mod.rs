use std::sync::Arc;

use dioxus_desktop::DesktopContext;
use dioxus_hooks::UseSharedState;
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

pub async fn handle_cmd(
    state: UseSharedState<State>,
    cmd: WindowManagerCmd,
    desktop: DesktopContext,
) {
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
