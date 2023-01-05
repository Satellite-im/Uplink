use std::{cell::RefCell, path::PathBuf, rc::Rc, sync::Arc};

use dioxus::prelude::ProvidedStateInner;
use futures::StreamExt;
use tokio::sync::{
    mpsc::{UnboundedReceiver, UnboundedSender},
    Mutex, Notify,
};
use warp::{
    constellation::Constellation,
    multipass::MultiPass,
    raygun::{RayGun, RayGunEventStream},
    tesseract::Tesseract,
};
use warp::{multipass::MultiPassEventKind, raygun::RayGunEventKind};
use warp_fs_ipfs::config::FsIpfsConfig;
use warp_mp_ipfs::config::MpIpfsConfig;
use warp_rg_ipfs::{config::RgIpfsConfig, Persistent};

use crate::{state::State, warp_runner::commands::handle_tesseract_cmd, WARP_PATH};

use self::commands::TesseractCmd;

pub mod commands;

pub type WarpCmdTx = UnboundedSender<WarpCmd>;
pub type WarpCmdRx = Arc<Mutex<UnboundedReceiver<WarpCmd>>>;
pub type WarpEventTx = UnboundedSender<WarpEvent>;
pub type WarpEventRx = Arc<Mutex<UnboundedReceiver<WarpEvent>>>;

type Account = Box<dyn MultiPass>;
type Storage = Box<dyn Constellation>;
type Messaging = Box<dyn RayGun>;

#[allow(clippy::large_enum_variant)]
pub enum WarpEvent {
    RayGun(RayGunEventKind),
    MultiPass(MultiPassEventKind),
}

#[derive(Debug)]
pub enum WarpCmd {
    Tesseract(TesseractCmd),
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
        assert!(!self.ran_once, "WarpRunner called run() multiple times");
        self.ran_once = true;

        let mut tesseract = match Tesseract::from_file(WARP_PATH.join(".keystore")) {
            Ok(tess) => tess,
            Err(_) => {
                //doesnt exist so its set
                let tess = Tesseract::default();
                tess.set_file(WARP_PATH.join(".keystore"));
                tess.set_autosave();
                tess
            }
        };

        let notify = self.notify.clone();
        tokio::spawn(async move {
            // todo: register for events from warp

            let (mut account, mut messaging, _storage) =
                match warp_initialization(WARP_PATH.clone(), tesseract.clone(), false).await {
                    Ok((i, c, s)) => (i, c, s),
                    Err(_e) => todo!(),
                };

            // this was the only way to get a mutable static variable. but this channel should only be read here.
            let mut rx = rx.lock().await;
            let mut raygun_stream = get_raygun_stream(&mut messaging).await;
            let mut multipass_stream = loop {
                match account.subscribe().await {
                    Ok(stream) => break stream,
                    Err(e) => match e {
                        //Note: Used as a precaution for future checks
                        warp::error::Error::MultiPassExtensionUnavailable => {
                            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                        }
                        //TODO: log error
                        //Note: Shouldnt give any other error but if it does to probably file as a bug
                        _ => return,
                    },
                };
            };

            loop {
                tokio::select! {
                    opt = multipass_stream.next() => {
                        if let Some(evt) = opt {
                            if tx.send(WarpEvent::MultiPass(evt)).is_err() {
                                break;
                            }
                        }
                    },
                    opt = raygun_stream.next() => {
                        if let Some(evt) = opt {
                            if tx.send(WarpEvent::RayGun(evt)).is_err() {
                                break;
                            }
                        }
                    },

                    // receive a command from the UI. call the corresponding function
                    opt = rx.recv() => match opt {
                        Some(cmd) => match cmd {
                            WarpCmd::Tesseract(cmd) => handle_tesseract_cmd(&mut tesseract, cmd)
                        },
                        None => break,
                    },

                    // the WarpRunner has been dropped. stop the thread
                    _ = notify.notified() => break,
                }
            }

            // println!("terminating warp_runner thread");
        });
    }
}

async fn get_raygun_stream(rg: &mut Messaging) -> RayGunEventStream {
    loop {
        match rg.subscribe().await {
            Ok(stream) => break stream,
            Err(warp::error::Error::MultiPassExtensionUnavailable)
            | Err(warp::error::Error::RayGunExtensionUnavailable) => {
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            }
            Err(_e) => {
                //Should not reach this point but should handle an error if it does
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            }
        }
    }
}

// this is called by `main.rs` from within a `use_future` and used to modify state. returns `true` if stae has been modified
// this keeps the size of main.rs small.
// might just want to add functions to State to handle each type of event and not need this at all.
pub async fn handle_event(
    _state: Rc<RefCell<ProvidedStateInner<State>>>,
    _event: WarpEvent,
) -> bool {
    todo!()
}

async fn warp_initialization(
    path: PathBuf,
    tesseract: Tesseract,
    experimental: bool,
) -> Result<(Account, Messaging, Storage), warp::error::Error> {
    let config = MpIpfsConfig::production(&path, experimental);

    let account = warp_mp_ipfs::ipfs_identity_persistent(config, tesseract, None)
        .await
        .map(|mp| Box::new(mp) as Account)?;

    let storage = warp_fs_ipfs::IpfsFileSystem::<warp_fs_ipfs::Persistent>::new(
        account.clone(),
        Some(FsIpfsConfig::production(&path)),
    )
    .await
    .map(|ct| Box::new(ct) as Storage)?;

    let messaging = warp_rg_ipfs::IpfsMessaging::<Persistent>::new(
        Some(RgIpfsConfig::production(&path)),
        account.clone(),
        Some(storage.clone()),
        None,
    )
    .await
    .map(|rg| Box::new(rg) as Messaging)?;

    Ok((account, messaging, storage))
}
