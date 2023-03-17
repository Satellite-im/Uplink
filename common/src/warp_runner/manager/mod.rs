//! this is the main warp_runner task. It initializes Warp and sits between Warp and Uplink, allowing communication via channels.

pub mod commands;
mod events;
use futures::StreamExt;
use std::sync::Arc;
use tokio::sync::Notify;
use warp::{
    logging::tracing::log, multipass::MultiPassEventStream, raygun::RayGunEventStream,
    tesseract::Tesseract,
};

use super::{conv_stream, Account, Messaging, Storage};
use crate::WARP_CMD_CH;

pub use commands::{ConstellationCmd, MultiPassCmd, OtherCmd, RayGunCmd, TesseractCmd};

/// Contains the structs needed for run() to handle various events
pub struct Warp {
    pub tesseract: Tesseract,
    pub multipass: Account,
    pub raygun: Messaging,
    pub constellation: Storage,
}

pub async fn run(mut warp: Warp, notify: Arc<Notify>) {
    // receive command from Uplink
    let warp_cmd_rx = WARP_CMD_CH.rx.clone();

    // using a mutex was the only way to get a mutable static variable. this channel should only be read here and only needs to be acquired once
    let mut warp_cmd_rx = warp_cmd_rx.lock().await;

    // gather incoming messages from all conversations and read them from conversation_msg_rx
    let (conversation_msg_tx, mut conversation_msg_rx) = tokio::sync::mpsc::unbounded_channel();
    let mut conversation_manager = conv_stream::Manager::new(conversation_msg_tx.clone());

    // receive events from RayGun and MultiPass
    let mut raygun_stream = get_raygun_stream(&mut warp.raygun).await;
    let mut multipass_stream = get_multipass_stream(&mut warp.multipass).await;

    log::debug!("warp_runner::manager::run");
    loop {
        tokio::select! {
            opt = multipass_stream.next() => {
                if events::handle_multipass_event(opt, &mut warp).await.is_err() {
                    break;
                }
            },
            opt = raygun_stream.next() => {
                if events::handle_raygun_event(opt, &mut warp, &mut conversation_manager).await.is_err() {
                    break;
                }
            },
            opt = conversation_msg_rx.recv() => {
                if events::handle_message_event(opt, &mut warp).await.is_err() {
                    break;
                }
            }
            opt = warp_cmd_rx.recv() => {
                if events::handle_warp_command(opt, &mut warp, &mut conversation_manager).await.is_err() {
                    break;
                }
            } ,
            // the WarpRunner has been dropped. stop the task
            _ = notify.notified() => break,
        }
    }

    log::debug!("terminating warp_runner thread");
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
                    log::error!("failed to get multipass stream: {}", _e);
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            },
        };
    }
}
