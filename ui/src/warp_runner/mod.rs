use std::{cell::RefCell, path::PathBuf, rc::Rc, sync::Arc};

use dioxus::prelude::ProvidedStateInner;
use tokio::sync::{
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex, Notify,
};
use warp::{
    constellation::Constellation, multipass::MultiPass, raygun::RayGun, tesseract::Tesseract,
};
use warp_fs_ipfs::config::FsIpfsConfig;
use warp_mp_ipfs::config::MpIpfsConfig;
use warp_rg_ipfs::{config::RgIpfsConfig, Persistent};

use crate::{state::State, DEFAULT_PATH};

pub type WarpCmdTx = UnboundedSender<WarpCmd>;
pub type WarpCmdRx = Arc<Mutex<UnboundedReceiver<WarpCmd>>>;
pub type WarpEventTx = UnboundedSender<WarpEvent>;
pub type WarpEventRx = Arc<Mutex<UnboundedReceiver<WarpEvent>>>;

pub enum WarpEvent {
    None,
}

pub enum WarpCmd {
    None,
}

pub struct WarpRunner {
    notify: Arc<Notify>,
    ran_once: bool,
}

impl std::ops::Drop for WarpRunner {
    fn drop(&mut self) {
        self.notify.notify_waiters();
    }
}

impl WarpRunner {
    pub fn init() -> Self {
        Self {
            notify: Arc::new(Notify::new()),
            ran_once: false,
        }
    }

    // spawns a thread which will terminate when WarpRunner is dropped
    pub fn run(&mut self, tx: WarpEventTx, rx: WarpCmdRx) {
        assert!(self.ran_once, "WarpRunner called run() multiple times");
        self.ran_once = true;

        let tesseract = match Tesseract::from_file(DEFAULT_PATH.join(".keystore")) {
            Ok(tess) => tess,
            Err(_) => {
                //doesnt exist so its set
                let tess = Tesseract::default();
                tess.set_file(DEFAULT_PATH.join(".keystore"));
                tess.set_autosave();
                tess
            }
        };

        let notify = self.notify.clone();
        tokio::spawn(async move {
            // todo: register for events from warp

            let (account, messaging, storage) =
                match warp_initialization(DEFAULT_PATH.clone(), tesseract.clone(), false).await {
                    Ok((i, c, s)) => (i, c, s),
                    Err(_e) => todo!(),
                };

            // this was the only way to get a mutable static variable. but this channel should only be read here.
            let mut rx = rx.lock().await;

            loop {
                tokio::select! {
                    // RayGun events
                    // MultiPass events
                    // etc

                    // receive a command from the UI. call the corresponding function
                    opt = rx.recv() => match opt {
                        Some(cmd) => todo!("handle cmd"),
                        None => break,
                    },

                    // the WarpRunner has been dropped. stop the thread
                    _ = notify.notified() => break,
                }
            }
        });
    }
}

// this is called by `main.rs` from within a `use_future` and used to modify state. returns `true` if stae has been modified
// this keeps the size of main.rs small.
pub async fn handle_event(state: Rc<RefCell<ProvidedStateInner<State>>>, event: WarpEvent) -> bool {
    match event {
        WarpEvent::None => todo!(),
    }
    false
}

async fn warp_initialization(
    path: PathBuf,
    tesseract: Tesseract,
    experimental: bool,
) -> Result<(Account, Messaging, Storage), warp::error::Error> {
    let config = MpIpfsConfig::production(&path, experimental);

    let account = warp_mp_ipfs::ipfs_identity_persistent(config, tesseract, None)
        .await
        .map(|mp| Box::new(mp) as Box<dyn MultiPass>)?;

    let storage = warp_fs_ipfs::IpfsFileSystem::<warp_fs_ipfs::Persistent>::new(
        account.clone(),
        Some(FsIpfsConfig::production(&path)),
    )
    .await
    .map(|ct| Box::new(ct) as Box<dyn Constellation>)?;

    let messaging = warp_rg_ipfs::IpfsMessaging::<Persistent>::new(
        Some(RgIpfsConfig::production(&path)),
        account.clone(),
        Some(storage.clone()),
        None,
    )
    .await
    .map(|rg| Box::new(rg) as Box<dyn RayGun>)?;

    Ok((account, messaging, storage))
}

type Account = Box<dyn MultiPass>;
type Storage = Box<dyn Constellation>;
type Messaging = Box<dyn RayGun>;
