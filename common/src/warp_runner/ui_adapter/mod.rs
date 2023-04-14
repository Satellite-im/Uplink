//! an event from Warp isn't necessarily what the UI needs to display. and the UI doesn't have access to RayGun, MultiPass, etc. As a result,
//! a translation must be performed by WarpRunner.
//!

mod message_event;
mod multipass_event;
mod raygun_event;

pub use message_event::{convert_message_event, MessageEvent};
pub use multipass_event::{convert_multipass_event, MultiPassEvent};
pub use raygun_event::{convert_raygun_event, RayGunEvent};
use uuid::Uuid;

use crate::state::{self, chats};
use futures::{stream::FuturesOrdered, FutureExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet, VecDeque};
use warp::{
    crypto::DID,
    error::Error,
    logging::tracing::log,
    multipass::identity::{Identity, Platform},
    raygun::{self, Conversation, MessageOptions},
};

/// the UI needs additional information for message replies, namely the text of the message being replied to.
/// fetch that before sending the message to the UI.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub inner: warp::raygun::Message,
    pub in_reply_to: Option<String>,
    /// this field exists so that the UI can tell Dioxus when a message has been edited and thus
    /// needs to be re-rendered. Before the addition of this field, the compose view was
    /// using the message Uuid, but this doesn't change when a message is edited.
    pub key: String,
}

pub struct ChatAdapter {
    pub inner: chats::Chat,
    pub identities: HashSet<state::identity::Identity>,
}

/// if a raygun::Message is in reply to another message, attempt to fetch part of the message text
pub async fn convert_raygun_message(
    messaging: &super::Messaging,
    msg: &raygun::Message,
) -> Message {
    let reply: Option<raygun::Message> = match msg.replied() {
        Some(id) => messaging.get_message(msg.conversation_id(), id).await.ok(),
        None => None,
    };

    Message {
        inner: msg.clone(),
        in_reply_to: reply.and_then(|msg| msg.value().first().cloned()),
        key: Uuid::new_v4().to_string(),
    }
}

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
        Some(id) => {
            let status = account
                .identity_status(&id.did_key())
                .await
                .unwrap_or(warp::multipass::identity::IdentityStatus::Offline);
            let platform = account
                .identity_platform(&id.did_key())
                .await
                .unwrap_or(Platform::Unknown);
            state::Identity::new(id, status, platform)
        }
        None => {
            let mut default: Identity = Default::default();
            default.set_did_key(did.clone());
            let did_str = &did.to_string();
            // warning: assumes DIDs are very long. this can cause a panic if that ever changes
            let start = did_str
                .get(8..=10)
                .ok_or(Error::OtherWithContext("DID too short".into()))?;
            let len = did_str.len();
            let end = did_str
                .get(len - 3..)
                .ok_or(Error::OtherWithContext("DID too short".into()))?;
            default.set_username(&format!("{start}...{end}"));
            state::Identity::from(default)
        }
    };
    Ok(identity)
}

pub async fn dids_to_identity(
    dids: &[DID],
    account: &super::Account,
) -> Result<Vec<state::Identity>, Error> {
    let mut ret = Vec::new();
    ret.reserve(dids.len());
    for id in dids {
        let ident = did_to_identity(id, account).await?;
        ret.push(ident);
    }
    Ok(ret)
}

pub async fn fetch_messages_from_chat(
    conv_id: Uuid,
    messaging: &mut super::Messaging,
    to_skip: usize,
    to_take: usize,
) -> Result<Vec<Message>, Error> {
    let total = to_take + to_skip;
    let max_messages = messaging.get_message_count(conv_id).await?;
    let to_skip = std::cmp::min(to_skip, max_messages);
    let total = std::cmp::min(total, max_messages);
    let messages = messaging
        .get_messages(conv_id, MessageOptions::default().set_range(to_skip..total))
        .await
        .and_then(Vec::<_>::try_from)?;

    let messages = FuturesOrdered::from_iter(
        messages
            .iter()
            .map(|message| convert_raygun_message(messaging, message).boxed()),
    )
    .collect()
    .await;

    Ok(messages)
}

pub async fn conversation_to_chat(
    conv: &Conversation,
    account: &super::Account,
    messaging: &mut super::Messaging,
) -> Result<ChatAdapter, Error> {
    // todo: should Chat::participants include self?
    let identities = dids_to_identity(&conv.recipients(), account).await?;
    let identities = HashSet::from_iter(identities.iter().cloned());

    // todo: warp doesn't support paging yet. it also doesn't check the range bounds
    let unreads = messaging.get_message_count(conv.id()).await?;
    let to_take = std::cmp::min(unreads, 20);
    let messages = messaging
        .get_messages(conv.id(), MessageOptions::default().set_range(0..to_take))
        .await
        .and_then(Vec::<_>::try_from)?;

    let messages: VecDeque<_> = FuturesOrdered::from_iter(
        messages
            .iter()
            .map(|message| convert_raygun_message(messaging, message).boxed()),
    )
    .collect()
    .await;

    let has_more_messages = unreads > to_take;
    let adapter = ChatAdapter {
        inner: chats::Chat {
            id: conv.id(),
            conversation_type: conv.conversation_type(),
            conversation_name: conv.name(),
            participants: HashSet::from_iter(conv.recipients()),
            creator: conv.creator(),
            messages,
            unreads: unreads as u32,
            replying_to: None,
            typing_indicator: HashMap::new(),
            draft: None,
            has_more_messages,
        },
        identities,
    };

    Ok(adapter)
}
