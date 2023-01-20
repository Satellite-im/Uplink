use std::{path::PathBuf, sync::Arc};

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
use warp_fs_ipfs::config::FsIpfsConfig;
use warp_mp_ipfs::config::MpIpfsConfig;
use warp_rg_ipfs::{config::RgIpfsConfig, Persistent};

use crate::{
    logger,
    warp_runner::{
        commands::{handle_multipass_cmd, handle_raygun_cmd, handle_tesseract_cmd},
        ui_adapter::did_to_identity,
    },
    STATIC_ARGS,
};

use self::{
    commands::{MultiPassCmd, RayGunCmd, TesseractCmd},
    ui_adapter::{MultiPassEvent, RayGunEvent},
};

pub mod commands;
pub mod ui_adapter;

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
    MultiPass(MultiPassEvent),
}

#[derive(Debug)]
pub enum WarpCmd {
    Tesseract(TesseractCmd),
    MultiPass(MultiPassCmd),
    RayGun(RayGunCmd),
}

pub struct WarpRunner {
    notify: Arc<Notify>,
    ran_once: bool,
    // State needs to know if there's a "keystore" field in Tesseract for the unlock page
    tesseract: Tesseract,
}

impl std::ops::Drop for WarpRunner {
    fn drop(&mut self) {
        self.notify.notify_waiters();
    }
}

impl WarpRunner {
    pub fn init() -> Self {
        let tess_path = STATIC_ARGS.warp_path.join(".keystore");
        let tesseract = match Tesseract::from_file(&tess_path) {
            Ok(tess) => tess,
            Err(_) => {
                //doesnt exist so its set
                let tess = Tesseract::default();
                tess.set_file(tess_path);
                tess.set_autosave();
                tess
            }
        };
        Self {
            notify: Arc::new(Notify::new()),
            ran_once: false,
            tesseract,
        }
    }

    // spawns a thread which will terminate when WarpRunner is dropped
    pub fn run(&mut self, tx: WarpEventTx, rx: WarpCmdRx) {
        assert!(!self.ran_once, "WarpRunner called run() multiple times");
        self.ran_once = true;

        let mut tesseract = self.tesseract.clone();

        let notify = self.notify.clone();
        tokio::spawn(async move {
            // todo: register for events from warp

            let (mut account, mut messaging, _storage) =
                match warp_initialization(STATIC_ARGS.warp_path.clone(), tesseract.clone(), false)
                    .await
                {
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
                // println!("warp runner waiting for event");
                tokio::select! {
                    opt = multipass_stream.next() => {
                        //println!("got multiPass event");
                        if let Some(evt) = opt {
                            match ui_adapter::convert_multipass_event(evt, &mut account, &mut messaging).await {
                                Ok(evt) => {
                                    if tx.send(WarpEvent::MultiPass(evt)).is_err() {
                                        break;
                                    }
                                }
                                Err(e) => {
                                    logger::error(&format!("failed to convert multipass event: {}", e));
                                }
                            }
                        }
                    },
                    opt = raygun_stream.next() => {
                        if let Some(evt) = opt {
                            match ui_adapter::convert_raygun_event(evt, &mut account, &mut messaging).await {
                                Ok(evt) => {
                                      if tx.send(WarpEvent::RayGun(evt)).is_err() {
                                        break;
                                      }
                                }
                                Err(e) => {
                                    logger::error(&format!("failed to convert raygun event: {}", e));
                                }
                            }
                        }
                    },
                    // receive a command from the UI. call the corresponding function
                    opt = rx.recv() => {
                        //println!("got warp_runner cmd");
                        match opt {
                        Some(cmd) => match cmd {
                            WarpCmd::Tesseract(cmd) => handle_tesseract_cmd(cmd, &mut tesseract).await,
                            WarpCmd::MultiPass(cmd) => {
                                // if a command to block a user comes in, need to update the UI because warp doesn't generate an event for a user being blocked.
                                // todo: ask for that event
                                if let MultiPassCmd::Block{did, .. } = &cmd {
                                    if let Ok(ident) = did_to_identity(did.clone(), &mut account).await {
                                        if tx.send(WarpEvent::MultiPass(MultiPassEvent::Blocked(ident))).is_err() {
                                            break;
                                        }
                                    }
                                }
                                if let MultiPassCmd::Unblock{did, .. } = &cmd {
                                    if let Ok(ident) = did_to_identity(did.clone(), &mut account).await {
                                        if tx.send(WarpEvent::MultiPass(MultiPassEvent::Unblocked(ident))).is_err() {
                                            break;
                                        }
                                    }
                                }
                                handle_multipass_cmd(cmd, &mut tesseract, &mut account).await;
                            },
                            WarpCmd::RayGun(cmd) => handle_raygun_cmd(cmd, &mut account, &mut messaging).await,
                        },
                        None => break,
                    }
                    } ,

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

    let mut rg_config = RgIpfsConfig::production(&path);
    // Used to prevent broadcasting `ConversationCreated` on the sender side
    rg_config.store_setting.disable_sender_event_emit = true;

    let messaging = warp_rg_ipfs::IpfsMessaging::<Persistent>::new(
        Some(rg_config),
        account.clone(),
        Some(storage.clone()),
        None,
    )
    .await
    .map(|rg| Box::new(rg) as Messaging)?;

    Ok((account, messaging, storage))
}
