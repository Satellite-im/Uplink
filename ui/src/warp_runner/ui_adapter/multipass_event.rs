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

            // TODO: Get state available in this scope.
            // Dispatch notifications only when we're not already focused on the application.
            let notifications_enabled = state
                .read()
                .configuration
                .config
                .notifications
                .friends_notifications;
            let should_play_sound =
                notifications_enabled && state.read().chats.active != conversation_id;
            let should_dispatch_notification =
                notifications_enabled && !state.read().ui.metadata.focused;
            if !state.read().ui.metadata.focused {
                crate::utils::notifications::push_notification(
                    "New friend request!".into(),
                    format!("{} sent a request.", identity.username()),
                    Some(crate::utils::sounds::Sounds::Notification),
                    notify_rust::Timeout::Milliseconds(4),
                );
            } else if state.read().chats.active != conversation_id {
                crate::utils::sounds::Play(crate::utils::sounds::Sounds::Notification);
            }
            state.write().mutate(state::Action::AddNotification(
                state::notifications::NotificaitonKind::FriendRequest,
                1,
            ));

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
        MultiPassEventKind::Blocked { did } => {
            let identity = did_to_identity(&did, account).await?;
            MultiPassEvent::Blocked(identity)
        }
        MultiPassEventKind::Unblocked { did } => {
            let identity = did_to_identity(&did, account).await?;
            MultiPassEvent::Unblocked(identity)
        }
        _ => MultiPassEvent::None,
    };

    Ok(evt)
}
