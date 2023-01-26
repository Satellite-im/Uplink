pub mod commands;
mod events;
use futures::StreamExt;
use std::sync::Arc;
use tokio::sync::Notify;
use warp::{multipass::MultiPassEventStream, raygun::RayGunEventStream, tesseract::Tesseract};
use warp_fs_ipfs::config::FsIpfsConfig;
use warp_mp_ipfs::config::MpIpfsConfig;
use warp_rg_ipfs::{config::RgIpfsConfig, Persistent};

use super::{conv_stream, Account, Messaging, Storage};
use crate::{logger, STATIC_ARGS, WARP_CMD_CH};

pub use commands::{MultiPassCmd, RayGunCmd, TesseractCmd};

/// Contains the structs needed for run() to handle various events
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
    let warp_cmd_rx = WARP_CMD_CH.rx.clone();

    // using a mutex was the only way to get a mutable static variable. this channel should only be read here and only needs to be acquired once
    let mut warp_cmd_rx = warp_cmd_rx.lock().await;
    let mut raygun_stream = get_raygun_stream(&mut warp.raygun).await;
    let mut multipass_stream = get_multipass_stream(&mut warp.multipass).await;

    let (msg_tx, mut msg_rx) = tokio::sync::mpsc::unbounded_channel();
    let mut stream_manager = conv_stream::Manager::new(msg_tx.clone());

    loop {
        // println!("warp runner waiting for event");
        tokio::select! {
            opt = multipass_stream.next() => {
                if events::handle_multipass_event(opt, &mut warp).await.is_err() {
                    break;
                }
            },
            opt = raygun_stream.next() => {
                if events::handle_raygun_event(opt, &mut warp, &mut stream_manager).await.is_err() {
                    break;
                }
            },
            opt = msg_rx.recv() => {
                if events::handle_message_event(opt, &mut warp).await.is_err() {
                    break;
                }
            }
            // receive a command from the UI. call the corresponding function
            opt = warp_cmd_rx.recv() => {
                //println!("got warp_runner cmd");
                if events::handle_warp_command(opt, &mut warp, &mut stream_manager).await.is_err() {
                    break;
                }
            } ,
            // the WarpRunner has been dropped. stop the task
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

async fn get_multipass_stream(account: &mut Account) -> MultiPassEventStream {
    loop {
        match account.subscribe().await {
            Ok(stream) => break stream,
            Err(e) => match e {
                //Note: Used as a precaution for future checks
                warp::error::Error::MultiPassExtensionUnavailable => {
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                }
                //TODO: log error
                //Note: Shouldnt give any other error but if it does to probably file as a bug
                _e => {
                    logger::error(&format!("failed to get multipass stream: {}", _e));
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            },
        };
    }
}
