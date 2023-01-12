//! an event from Warp isn't necessarily what the UI needs to display. and the UI doesn't have access to RayGun, MultiPass, ect. As a result,
//! a translation must be performed by WarpRunner.
//!

use warp::{
    crypto::DID,
    multipass::MultiPassEventKind,
    raygun::{Conversation, MessageOptions},
};

use crate::state::{self, chats};

pub enum RayGunEvent {
    None,
}

pub enum MultiPassEvent {
    FriendRequestReceived(state::Identity),
    FriendRequestSent(state::Identity),
}

pub async fn did_to_identity(did: DID, account: &mut super::Account) -> state::Identity {
    let warp_identity = account
        .get_identity(did.into())
        .await
        .expect("could not get warp identity");
    state::Identity::from(
        warp_identity
            .first()
            .cloned()
            .expect("could not get warp identity"),
    )
}

pub async fn dids_to_identity(
    dids: Vec<DID>,
    account: &mut super::Account,
) -> Vec<state::Identity> {
    let mut ret = Vec::new();
    for id in dids {
        let ident = did_to_identity(id, account).await;
        ret.push(ident);
    }
    ret
}

pub async fn conversation_to_chat(
    conv: Conversation,
    account: &mut super::Account,
    messaging: &mut super::Messaging,
) -> chats::Chat {
    // todo: should Chat::participants include self?
    let mut participants = Vec::new();
    for id in conv.recipients() {
        let ident = did_to_identity(id, account).await;
        participants.push(ident);
    }

    let messages = messaging
        .get_messages(conv.id(), MessageOptions::default())
        .await
        .expect("failed to get messages");

    let unreads = messages.len() as u32;

    chats::Chat {
        id: conv.id(),
        participants,
        messages,
        unreads,
        replying_to: None,
    }
}

// todo: put account and messaging in a module
pub async fn convert_multipass_event(
    event: warp::multipass::MultiPassEventKind,
    account: &mut super::Account,
    _messaging: &mut super::Messaging,
) -> MultiPassEvent {
    match event {
        MultiPassEventKind::FriendRequestSent { to } => {
            let identity = did_to_identity(to, account).await;
            MultiPassEvent::FriendRequestSent(identity)
        }
        MultiPassEventKind::FriendRequestReceived { from } => {
            let identity = did_to_identity(from, account).await;
            MultiPassEvent::FriendRequestReceived(identity)
        }
        _ => todo!(),
    }
}

pub async fn convert_raygun_event(
    _event: warp::raygun::RayGunEventKind,
    _account: &mut super::Account,
    _messaging: &mut super::Messaging,
) -> RayGunEvent {
    todo!()
}
