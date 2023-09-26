//! an event from Warp isn't necessarily what the UI needs to display. and the UI doesn't have access to RayGun, MultiPass, etc. As a result,
//! a translation must be performed by WarpRunner.
//!

mod message_event;
mod multipass_event;
mod raygun_event;

use chrono::{DateTime, Utc};
pub use message_event::{convert_message_event, MessageEvent};
pub use multipass_event::{convert_multipass_event, MultiPassEvent};
pub use raygun_event::{convert_raygun_event, RayGunEvent};
use uuid::Uuid;

use crate::state::{self, chats, MAX_PINNED_MESSAGES};
use futures::{stream::FuturesOrdered, FutureExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashSet, VecDeque},
    ops::Range,
};
use warp::{
    constellation::file::File,
    crypto::DID,
    error::Error,
    logging::tracing::log,
    multipass::identity::{Identifier, Identity, Platform},
    raygun::{self, Conversation, MessageOptions},
};

/// the UI needs additional information for message replies, namely the text of the message being replied to.
/// fetch that before sending the message to the UI.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    pub inner: warp::raygun::Message,
    pub in_reply_to: Option<(String, Vec<File>, DID)>,
    /// this field exists so that the UI can tell Dioxus when a message has been edited and thus
    /// needs to be re-rendered. Before the addition of this field, the compose view was
    /// using the message Uuid, but this doesn't change when a message is edited.
    pub key: String,
}

pub struct ChatAdapter {
    pub inner: chats::SendableChat,
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
        in_reply_to: reply.map(|msg: raygun::Message| {
            (
                msg.value().first().cloned().unwrap_or_default(),
                msg.attachments(),
                msg.sender(),
            )
        }),
        key: Uuid::new_v4().to_string(),
    }
}

pub fn get_uninitialized_identity(did: &DID) -> Result<state::Identity, Error> {
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
    Ok(state::Identity::from(default))
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
            let mut id = state::Identity::new(id, status, platform);

            if let Ok(picture) = account.identity_picture(&id.did_key()).await {
                id.set_profile_picture(&picture);
            }

            if let Ok(banner) = account.identity_banner(&id.did_key()).await {
                id.set_profile_banner(&banner);
            }

            id
        }
        None => get_uninitialized_identity(did)?,
    };
    Ok(identity)
}

pub async fn dids_to_identity(
    identifier: Identifier,
    account: &super::Account,
) -> Result<Vec<state::Identity>, Error> {
    let mut identities = account.get_identity(identifier).await?;
    let ids = identities.drain(..).map(|id| async {
        let status = account
            .identity_status(&id.did_key())
            .await
            .unwrap_or(warp::multipass::identity::IdentityStatus::Offline);
        let platform = account
            .identity_platform(&id.did_key())
            .await
            .unwrap_or(Platform::Unknown);
        let mut id = state::Identity::new(id, status, platform);

        if let Ok(picture) = account.identity_picture(&id.did_key()).await {
            id.set_profile_picture(&picture);
        }

        if let Ok(banner) = account.identity_banner(&id.did_key()).await {
            id.set_profile_banner(&banner);
        }

        id
    });
    let converted_ids = FuturesOrdered::from_iter(ids).collect().await;
    Ok(converted_ids)
}

pub async fn fetch_messages_from_chat(
    conv_id: Uuid,
    messaging: &mut super::Messaging,
    to_take: usize,
) -> Result<(Vec<Message>, bool), Error> {
    let total_messages = messaging.get_message_count(conv_id).await?;
    let to_take = std::cmp::min(total_messages, to_take);
    let to_skip = total_messages.saturating_sub(to_take + 1);

    let messages = messaging
        .get_messages(
            conv_id,
            MessageOptions::default().set_range(to_skip..total_messages),
        )
        .await
        .and_then(Vec::<_>::try_from)?;

    let messages: Vec<_> = FuturesOrdered::from_iter(
        messages
            .iter()
            .map(|message| convert_raygun_message(messaging, message).boxed()),
    )
    .collect()
    .await;

    let has_more = to_skip > 0;
    // log::debug!(
    //     "fetched messages. total: {}, num taken: {}, has_more: {}",
    //     total_messages,
    //     to_take,
    //     has_more
    // );
    Ok((messages, has_more))
}

pub async fn fetch_messages_between(
    conv_id: Uuid,
    messaging: &mut super::Messaging,
    date_range: Range<DateTime<Utc>>,
) -> Result<(Vec<Message>, bool), Error> {
    let total_messages = messaging.get_message_count(conv_id).await?;

    let messages = messaging
        .get_messages(
            conv_id,
            MessageOptions::default().set_date_range(date_range),
        )
        .await
        .and_then(Vec::<_>::try_from)?;

    let messages: Vec<_> = FuturesOrdered::from_iter(
        messages
            .iter()
            .map(|message| convert_raygun_message(messaging, message).boxed()),
    )
    .collect()
    .await;
    let has_more = messages.len() < total_messages;
    Ok((messages, has_more))
}

pub async fn fetch_pinned_messages_from_chat(
    conv_id: Uuid,
    messaging: &mut super::Messaging,
) -> Result<Vec<Message>, Error> {
    let messages = messaging
        .get_messages(
            conv_id,
            MessageOptions::default()
                .set_reverse()
                .set_limit(MAX_PINNED_MESSAGES as i64)
                .set_pinned(),
        )
        .await
        .and_then(Vec::<_>::try_from)?;

    let messages: Vec<_> = FuturesOrdered::from_iter(
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
    messaging: &super::Messaging,
) -> Result<chats::SendableChat, Error> {
    // todo: warp doesn't support paging yet. it also doesn't check the range bounds
    let total_messages = messaging.get_message_count(conv.id()).await?;
    let to_take = std::cmp::min(total_messages, 20);
    let to_skip = total_messages.saturating_sub(to_take + 1);

    let messages = messaging
        .get_messages(
            conv.id(),
            MessageOptions::default().set_range(to_skip..total_messages),
        )
        .await
        .and_then(Vec::<_>::try_from)?;

    let messages: VecDeque<_> = FuturesOrdered::from_iter(
        messages
            .iter()
            .map(|message| convert_raygun_message(messaging, message).boxed()),
    )
    .collect()
    .await;

    // todo: perhaps add pagination, but do this separately from the pagination for the chats page
    let pinned_messages = messaging
        .get_messages(
            conv.id(),
            MessageOptions::default()
                .set_reverse()
                .set_limit(MAX_PINNED_MESSAGES as i64)
                .set_pinned(),
        )
        .await
        .and_then(Vec::<_>::try_from)?;

    let has_more_messages = total_messages > to_take;
    let mut chat = chats::SendableChat::new(
        conv.id(),
        HashSet::from_iter(conv.recipients()),
        conv.conversation_type(),
        conv.name(),
        conv.creator(),
        messages,
        pinned_messages,
    );
    chat.has_more_messages = has_more_messages;
    Ok(chat)
}

pub async fn init_conversation(
    conv: &Conversation,
    account: &super::Account,
    messaging: &mut super::Messaging,
) -> Result<ChatAdapter, Error> {
    // todo: should Chat::participants include self?
    let identities = dids_to_identity(conv.recipients().into(), account).await?;
    let identities = HashSet::from_iter(identities.iter().cloned());

    let inner = conversation_to_chat(conv, messaging).await?;
    Ok(ChatAdapter { inner, identities })
}
