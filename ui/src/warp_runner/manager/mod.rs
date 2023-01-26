use std::sync::Arc;

use futures::StreamExt;
use tokio::sync::Notify;
use warp::{raygun::RayGunEventStream, tesseract::Tesseract};
use warp_fs_ipfs::config::FsIpfsConfig;
use warp_mp_ipfs::config::MpIpfsConfig;
use warp_rg_ipfs::{config::RgIpfsConfig, Persistent};

use super::{conv_stream, Account, Messaging, Storage};
use crate::{
    logger,
    warp_runner::{
        commands::{handle_multipass_cmd, handle_raygun_cmd, handle_tesseract_cmd, MultiPassCmd},
        ui_adapter::{self, did_to_identity, MultiPassEvent},
        WarpCmd, WarpEvent,
    },
    STATIC_ARGS, WARP_CMD_CH, WARP_EVENT_CH,
};

/// Contains the structs for Warp
pub struct Warp {
    tesseract: Tesseract,
    multipass: Account,
    raygun: Messaging,
    _constellation: Storage,
}

impl Warp {
    pub async fn new() -> Result<Self, warp::error::Error> {
        let tesseract = init_tesseract();
        let (multipass, raygun, _constellation) =
            warp_initialization(tesseract.clone(), false).await?;

        Ok(Self {
            tesseract,
            multipass,
            raygun,
            _constellation,
        })
    }
}

pub async fn run(mut warp: Warp, notify: Arc<Notify>) {
    let (tx, rx) = (WARP_EVENT_CH.tx.clone(), WARP_CMD_CH.rx.clone());
    let (messaging, account, tesseract) =
        (&mut warp.raygun, &mut warp.multipass, &mut warp.tesseract);

    // this was the only way to get a mutable static variable. but this channel should only be read here.
    let mut rx = rx.lock().await;
    let mut raygun_stream = get_raygun_stream(messaging).await;
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

    let (msg_tx, mut msg_rx) = tokio::sync::mpsc::unbounded_channel();
    let mut stream_manager = conv_stream::Manager::new(msg_tx.clone());

    loop {
        // println!("warp runner waiting for event");
        tokio::select! {
            opt = multipass_stream.next() => {
                //println!("got multiPass event");
                if let Some(evt) = opt {
                    match ui_adapter::convert_multipass_event(evt, account,  messaging).await {
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
                    match ui_adapter::convert_raygun_event(evt, &mut stream_manager, account, messaging).await {
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
            opt = msg_rx.recv() => {
                if let Some(msg) =  opt {
                    match ui_adapter::convert_message_event(msg, account, messaging).await {
                        Ok(evt) => {
                            if tx.send(WarpEvent::Message(evt)).is_err() {
                              break;
                            }
                      }
                      Err(e) => {
                        logger::error(&format!("failed to convert message event: {}", e));
                      }
                    }
                }
            }
            // receive a command from the UI. call the corresponding function
            opt = rx.recv() => {
                //println!("got warp_runner cmd");
                match opt {
                Some(cmd) => match cmd {
                    WarpCmd::Tesseract(cmd) => handle_tesseract_cmd(cmd, tesseract).await,
                    WarpCmd::MultiPass(cmd) => {
                        // if a command to block a user comes in, need to update the UI because warp doesn't generate an event for a user being blocked.
                        // todo: ask for that event
                        if let MultiPassCmd::Block{did, .. } = &cmd {
                            if let Ok(ident) = did_to_identity(did, account).await {
                                if tx.send(WarpEvent::MultiPass(MultiPassEvent::Blocked(ident))).is_err() {
                                    break;
                                }
                            }
                        }
                        if let MultiPassCmd::Unblock{did, .. } = &cmd {
                            if let Ok(ident) = did_to_identity(did, account).await {
                                if tx.send(WarpEvent::MultiPass(MultiPassEvent::Unblocked(ident))).is_err() {
                                    break;
                                }
                            }
                        }
                        handle_multipass_cmd(cmd, tesseract, account).await;
                    },

                    WarpCmd::RayGun(cmd) => handle_raygun_cmd(cmd, &mut stream_manager, account, messaging).await,

                },
                None => break,
            }
            } ,

            // the WarpRunner has been dropped. stop the thread
            _ = notify.notified() => break,
        }
    }

    // println!("terminating warp_runner thread");
}

fn init_tesseract() -> Tesseract {
    let tess_path = STATIC_ARGS.warp_path.join(".keystore");
    match Tesseract::from_file(&tess_path) {
        Ok(tess) => tess,
        Err(_) => {
            //doesnt exist so its set
            let tess = Tesseract::default();
            tess.set_file(tess_path);
            tess.set_autosave();
            tess
        }
    }
}

async fn warp_initialization(
    tesseract: Tesseract,
    experimental: bool,
) -> Result<(Account, Messaging, Storage), warp::error::Error> {
    let path = &STATIC_ARGS.warp_path;
    let config = MpIpfsConfig::production(path, experimental);

    let account = warp_mp_ipfs::ipfs_identity_persistent(config, tesseract, None)
        .await
        .map(|mp| Box::new(mp) as Account)?;

    let storage = warp_fs_ipfs::IpfsFileSystem::<warp_fs_ipfs::Persistent>::new(
        account.clone(),
        Some(FsIpfsConfig::production(path)),
    )
    .await
    .map(|ct| Box::new(ct) as Storage)?;

    // FYI: setting `rg_config.store_setting.disable_sender_event_emit` to `true` will prevent broadcasting `ConversationCreated` on the sender side
    let rg_config = RgIpfsConfig::production(path);

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
