//! an event from Warp isn't necessarily what the UI needs to display. and the UI doesn't have access to RayGun, MultiPass, etc. As a result,
//! a translation must be performed by WarpRunner.
//!

use uuid::Uuid;
use warp::{
    crypto::DID,
    error::Error,
    multipass::MultiPassEventKind,
    raygun::{Conversation, MessageOptions, RayGunEventKind},
};

use crate::state::{self, chats};

#[allow(clippy::large_enum_variant)]
pub enum RayGunEvent {
    ConversationCreated(state::Chat),
    ConversationDeleted(Uuid),
}

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

pub async fn did_to_identity(
    did: DID,
    account: &mut super::Account,
) -> Result<state::Identity, Error> {
    account
        .get_identity(did.into())
        .await
        // if Ok, get the first item in the vector. 
        // if the vector is empty, become Error::IdentityDoesntExist
        .and_then(|v| v.first().cloned().ok_or(Error::IdentityDoesntExist))
        // if Ok, convert from warp::Identity to state::Identity
        .map(state::Identity::from)
}

pub async fn dids_to_identity(
    dids: Vec<DID>,
    account: &mut super::Account,
) -> Result<Vec<state::Identity>, Error> {
    let mut ret = Vec::new();
    ret.reserve(dids.len());
    for id in dids {
        let ident = did_to_identity(id, account).await?;
        ret.push(ident);
    }
    Ok(ret)
}

pub async fn conversation_to_chat(
    conv: Conversation,
    account: &mut super::Account,
    messaging: &mut super::Messaging,
) -> Result<chats::Chat, Error> {
    // todo: should Chat::participants include self?
    let mut participants = Vec::new();
    for id in conv.recipients() {
        let identity = did_to_identity(id, account).await?;
        participants.push(identity);
    }

    let messages = match messaging
        .get_messages(conv.id(), MessageOptions::default())
        .await
    {
        Ok(m) => m,
        Err(e) => match e {
            warp::error::Error::EmptyMessage => vec![],
            _ => return Err(e),
        },
    };

    let unreads = messages.len() as u32;

    Ok(chats::Chat {
        id: conv.id(),
        participants,
        messages,
        unreads,
        replying_to: None,
    })
}

// todo: put account and messaging in a module
pub async fn convert_multipass_event(
    event: warp::multipass::MultiPassEventKind,
    account: &mut super::Account,
    _messaging: &mut super::Messaging,
) -> Result<MultiPassEvent, Error> {
    let evt = match event {
        MultiPassEventKind::FriendRequestSent { to } => {
            let identity = did_to_identity(to, account).await?;
            MultiPassEvent::FriendRequestSent(identity)
        }
        MultiPassEventKind::FriendRequestReceived { from } => {
            let identity = did_to_identity(from, account).await?;
            //println!("friend request received: {:#?}", identity);
            MultiPassEvent::FriendRequestReceived(identity)
        }
        MultiPassEventKind::IncomingFriendRequestClosed { did }
        | MultiPassEventKind::IncomingFriendRequestRejected { did }
        | MultiPassEventKind::OutgoingFriendRequestClosed { did }
        | MultiPassEventKind::OutgoingFriendRequestRejected { did } => {
            let identity = did_to_identity(did, account).await?;
            MultiPassEvent::FriendRequestCancelled(identity)
        }
        MultiPassEventKind::FriendAdded { did } => {
            let identity = did_to_identity(did, account).await?;
            MultiPassEvent::FriendAdded(identity)
        }
        MultiPassEventKind::FriendRemoved { did } => {
            let identity = did_to_identity(did, account).await?;
            MultiPassEvent::FriendRemoved(identity)
        }
        MultiPassEventKind::IdentityOnline { did } => {
            let identity = did_to_identity(did, account).await?;
            MultiPassEvent::FriendOnline(identity)
        }
        MultiPassEventKind::IdentityOffline { did } => {
            let identity = did_to_identity(did, account).await?;
            MultiPassEvent::FriendOffline(identity)
        }
    };

    Ok(evt)
}

pub async fn convert_raygun_event(
    event: warp::raygun::RayGunEventKind,
    account: &mut super::Account,
    messaging: &mut super::Messaging,
) -> Result<RayGunEvent, Error> {
    let evt = match event {
        RayGunEventKind::ConversationCreated { conversation_id } => {
            let conv = messaging.get_conversation(conversation_id).await?;
            let chat = conversation_to_chat(conv, account, messaging).await?;
            RayGunEvent::ConversationCreated(chat)
        }
        RayGunEventKind::ConversationDeleted { conversation_id } => {
            RayGunEvent::ConversationDeleted(conversation_id)
        }
    };

    Ok(evt)
}
