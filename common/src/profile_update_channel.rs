use std::sync::Arc;

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
    let identities: Vec<_> = identities.iter().map(|id| id.did_key()).collect();
    tokio::spawn(async move {
        let warp_cmd_tx = WARP_CMD_CH.tx.clone();

        for identity in identities {
            let (tx, rx) = oneshot::channel();
            let cmd = if banner {
                WarpCmd::MultiPass(MultiPassCmd::GetProfileBanner {
                    did: identity.clone(),
                    rsp: tx,
                })
            } else {
                WarpCmd::MultiPass(MultiPassCmd::GetProfilePicture {
                    did: identity.clone(),
                    rsp: tx,
                })
            };
            let _ = warp_cmd_tx.send(cmd);
            let pic = rx.await.unwrap();
            if let Ok(pic) = pic {
                let cmd = if banner {
                    ProfileUpdateAction::ProfileBannerUpdate(identity, pic)
                } else {
                    ProfileUpdateAction::ProfilePictureUpdate(identity, pic)
                };
                let _ = PROFILE_CHANNEL_LISTENER.tx.send(cmd);
            }
        }
    });
}
