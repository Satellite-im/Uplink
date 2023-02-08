//! an event from Warp isn't necessarily what the UI needs to display. and the UI doesn't have access to RayGun, MultiPass, etc. As a result,
//! a translation must be performed by WarpRunner.
//!

mod message_event;
mod multipass_event;
mod raygun_event;

pub use message_event::{convert_message_event, MessageEvent};
pub use multipass_event::{convert_multipass_event, MultiPassEvent};
pub use raygun_event::{convert_raygun_event, RayGunEvent};

use std::collections::{HashMap, VecDeque};

use warp::{
    crypto::DID,
    error::Error,
    logging::tracing::log,
    multipass::identity::Identity,
    raygun::{self, Conversation, MessageOptions},
};

use crate::state::{self, chats};

// this function is used in response to warp events. assuming that the DID from these events is valid.
// Warp sends the Identity over. if the Identity has not been received yet, get_identity will fail for
// a valid DID.
pub async fn did_to_identity(
    did: &DID,
    account: &super::Account,
) -> Result<state::Identity, Error> {
    let identity = match account.get_identity(did.clone().into()).await {
        Ok(list) => list.first().cloned(),
        Err(e) => {
            log::warn!("multipass couldn't find identity {}: {}", did, e);
            None
        }
    };
    let identity = match identity {
        Some(id) => id,
        None => {
            let mut default: Identity = Default::default();
            default.set_did_key(did.clone());
            default.set_username(&did.to_string()[0..7]);
            default
        }
    };
    Ok(state::Identity::from(identity))
}

pub async fn dids_to_identity(
    dids: &[DID],
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
    conv: &Conversation,
    account: &super::Account,
    messaging: &mut super::Messaging,
) -> Result<chats::Chat, Error> {
    // todo: should Chat::participants include self?
    let mut participants = Vec::new();
    for id in conv.recipients() {
        let identity = did_to_identity(&id, account).await?;
        participants.push(identity);
    }

    // todo: warp doesn't support paging yet. it also doesn't check the range bounds
    let unreads = messaging.get_message_count(conv.id()).await?;
    let messages: VecDeque<raygun::Message> = messaging
        .get_messages(conv.id(), MessageOptions::default().set_range(0..unreads))
        .await?
        .into();

    Ok(chats::Chat {
        id: conv.id(),
        participants,
        messages,
        unreads: unreads as u32,
        replying_to: None,
        typing_indicator: HashMap::new(),
    })
}
