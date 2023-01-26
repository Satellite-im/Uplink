use warp::{error::Error, multipass::MultiPassEventKind};

use crate::state::{self};

use super::did_to_identity;

pub enum MultiPassEvent {
    None,
    FriendRequestReceived(state::Identity),
    FriendRequestSent(state::Identity),
    FriendAdded(state::Identity),
    FriendRemoved(state::Identity),
    FriendRequestCancelled(state::Identity),
    FriendOnline(state::Identity),
    FriendOffline(state::Identity),
    Blocked(state::Identity),
    Unblocked(state::Identity),
}

pub async fn convert_multipass_event(
    event: warp::multipass::MultiPassEventKind,
    account: &mut super::super::Account,
    _messaging: &mut super::super::Messaging,
) -> Result<MultiPassEvent, Error> {
    //println!("got {:?}", &event);
    let evt = match event {
        MultiPassEventKind::FriendRequestSent { to } => {
            let identity = did_to_identity(&to, account).await?;
            MultiPassEvent::FriendRequestSent(identity)
        }
        MultiPassEventKind::FriendRequestReceived { from } => {
            let identity = did_to_identity(&from, account).await?;
            //println!("friend request received: {:#?}", identity);
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
    };

    Ok(evt)
}
