use std::sync::Arc;

use dioxus::hooks::to_owned;
use futures::channel::oneshot;
use once_cell::sync::Lazy;
use tokio::sync::Mutex;
use warp::crypto::DID;

use crate::{
    state::Identity,
    warp_runner::{MultiPassCmd, WarpCmd},
    WARP_CMD_CH,
};

pub struct ProfileUpdateChannel {
    pub tx: tokio::sync::mpsc::UnboundedSender<ProfileUpdateAction>,
    pub rx: Arc<Mutex<tokio::sync::mpsc::UnboundedReceiver<ProfileUpdateAction>>>,
}

pub static PROFILE_CHANNEL_LISTENER: Lazy<ProfileUpdateChannel> = Lazy::new(|| {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    ProfileUpdateChannel {
        tx,
        rx: Arc::new(Mutex::new(rx)),
    }
});

pub enum ProfileUpdateAction {
    ProfilePictureUpdate(DID, String),
    ProfileBannerUpdate(DID, String),
}

pub fn fetch_identity_data(identities: &[Identity], banner: bool) {
    to_owned![identities];
    tokio::spawn(async move {
        let warp_cmd_tx = WARP_CMD_CH.tx.clone();

        for identity in identities {
            let (tx, rx) = oneshot::channel();
            let cmd = if banner {
                WarpCmd::MultiPass(MultiPassCmd::GetProfileBanner {
                    did: identity.did_key(),
                    rsp: tx,
                })
            } else {
                WarpCmd::MultiPass(MultiPassCmd::GetProfilePicture {
                    did: identity.did_key(),
                    rsp: tx,
                })
            };
            let _ = warp_cmd_tx.send(cmd);
            let pic = rx.await.unwrap();
            if let Ok(pic) = pic {
                let cmd = if banner {
                    ProfileUpdateAction::ProfileBannerUpdate(identity.did_key(), pic)
                } else {
                    ProfileUpdateAction::ProfilePictureUpdate(identity.did_key(), pic)
                };
                let _ = PROFILE_CHANNEL_LISTENER.tx.send(cmd);
            }
        }
    });
}
