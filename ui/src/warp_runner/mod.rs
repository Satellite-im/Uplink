//! Defines important types and structs, and spawns the main task for warp_runner - manager::run.
use std::sync::Arc;

use tokio::sync::{
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex, Notify,
};
use warp::{constellation::Constellation, multipass::MultiPass, raygun::RayGun};

use self::ui_adapter::{MultiPassEvent, RayGunEvent};

mod conv_stream;
mod manager;
pub mod ui_adapter;

pub use manager::{ConstellationCmd, MultiPassCmd, RayGunCmd, TesseractCmd};

pub type WarpCmdTx = UnboundedSender<WarpCmd>;
pub type WarpCmdRx = Arc<Mutex<UnboundedReceiver<WarpCmd>>>;
pub type WarpEventTx = UnboundedSender<WarpEvent>;
pub type WarpEventRx = Arc<Mutex<UnboundedReceiver<WarpEvent>>>;

pub struct WarpCmdChannels {
    pub tx: WarpCmdTx,
    pub rx: WarpCmdRx,
}

pub struct WarpEventChannels {
    pub tx: WarpEventTx,
    pub rx: WarpEventRx,
}

type Account = Box<dyn MultiPass>;
type Storage = Box<dyn Constellation>;
type Messaging = Box<dyn RayGun>;

#[allow(clippy::large_enum_variant)]
pub enum WarpEvent {
    RayGun(RayGunEvent),
    Message(ui_adapter::MessageEvent),
    MultiPass(MultiPassEvent),
}

#[derive(Debug)]
pub enum WarpCmd {
    Tesseract(TesseractCmd),
    MultiPass(MultiPassCmd),
    RayGun(RayGunCmd),
    Constellation(ConstellationCmd),
}

/// Spawns a task which manages multiple streams, channels, and tasks related to warp
pub struct WarpRunner {
    // perhaps collecting a JoinHandle and calling abort() would be better than using Notify.
    notify: Arc<Notify>,
    ran_once: bool,
}

impl std::ops::Drop for WarpRunner {
    fn drop(&mut self) {
        self.notify.notify_waiters();
    }
}

impl WarpRunner {
    pub fn new() -> Self {
        Self {
            notify: Arc::new(Notify::new()),
            ran_once: false,
        }
    }

    // spawns a task which will terminate when WarpRunner is dropped
    pub fn run(&mut self) {
        assert!(!self.ran_once, "WarpRunner called run() multiple times");
        self.ran_once = true;

        let notify = self.notify.clone();
        tokio::spawn(async move {
            // todo: retry this in a loop if warp fails to initialize
            let warp = manager::Warp::new()
                .await
                .expect("failed to initialize warp");
            manager::run(warp, notify).await;
        });
    }
}
