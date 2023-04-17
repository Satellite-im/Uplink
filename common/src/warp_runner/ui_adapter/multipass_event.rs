use derive_more::Display;
use warp::{error::Error, multipass::MultiPassEventKind};

use crate::state::{self};

use super::did_to_identity;
#[derive(Display)]
pub enum MultiPassEvent {
    #[display(fmt = "None")]
    None,
    #[display(fmt = "FriendRequestReceived")]
    FriendRequestReceived(state::Identity),
    #[display(fmt = "FriendRequestSent")]
    FriendRequestSent(state::Identity),
    #[display(fmt = "FriendAdded")]
    FriendAdded(state::Identity),
    #[display(fmt = "FriendRemoved")]
    FriendRemoved(state::Identity),
    #[display(fmt = "FriendRequestCancelled")]
    FriendRequestCancelled(state::Identity),
    #[display(fmt = "FriendOnline")]
    FriendOnline(state::Identity),
    #[display(fmt = "FriendOffline")]
    FriendOffline(state::Identity),
    #[display(fmt = "Blocked")]
    Blocked(state::Identity),
    #[display(fmt = "Unblocked")]
    Unblocked(state::Identity),
    #[display(fmt = "IdentityUpdate")]
    IdentityUpdate(state::Identity),
}

pub async fn convert_multipass_event(
    event: warp::multipass::MultiPassEventKind,
    account: &mut super::super::Account,
    _messaging: &mut super::super::Messaging,
) -> Result<MultiPassEvent, Error> {
    let evt = match event {
        MultiPassEventKind::FriendRequestSent { to } => {
            let identity = did_to_identity(&to, account).await?;
            MultiPassEvent::FriendRequestSent(identity)
        }
        MultiPassEventKind::FriendRequestReceived { from } => {
            let identity = did_to_identity(&from, account).await?;
            MultiPassEvent::FriendRequestReceived(identity)
        }
        MultiPassEventKind::IncomingFriendRequestClosed { did }
        | MultiPassEventKind::IncomingFriendRequestRejected { did }
        | MultiPassEventKind::OutgoingFriendRequestClosed { did }
        | MultiPassEventKind::OutgoingFriendRequestRejected { did } => {
            let identity = did_to_identity(&did, account).await?;
            MultiPassEvent::FriendRequestCancelled(identity)
        }
        MultiPassEventKind::FriendAdded { did } => {
            let identity = did_to_identity(&did, account).await?;
            MultiPassEvent::FriendAdded(identity)
        }
        MultiPassEventKind::FriendRemoved { did } => {
            let identity = did_to_identity(&did, account).await?;
            MultiPassEvent::FriendRemoved(identity)
        }
        MultiPassEventKind::IdentityOnline { did } => {
            let identity = did_to_identity(&did, account).await?;
            MultiPassEvent::FriendOnline(identity)
        }
        MultiPassEventKind::IdentityOffline { did } => {
            let identity = did_to_identity(&did, account).await?;
            MultiPassEvent::FriendOffline(identity)
        }
        MultiPassEventKind::Blocked { did } => {
            let identity = did_to_identity(&did, account).await?;
            MultiPassEvent::Blocked(identity)
        }
        MultiPassEventKind::Unblocked { did } => {
            let identity = did_to_identity(&did, account).await?;
            MultiPassEvent::Unblocked(identity)
        }
        MultiPassEventKind::IdentityUpdate { did, .. } => {
            let identity = did_to_identity(&did, account).await?;
            MultiPassEvent::IdentityUpdate(identity)
        }
        _ => MultiPassEvent::None,
    };

    Ok(evt)
}
