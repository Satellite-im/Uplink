use uuid::Uuid;
use warp::{
    crypto::DID,
    error::Error,
    logging::tracing::log,
    raygun::{self, MessageEventKind},
};

use super::Message;
use crate::{
    state,
    warp_runner::ui_adapter::{convert_raygun_message, did_to_identity},
};

pub enum MessageEvent {
    Received {
        conversation_id: Uuid,
        message: Message,
    },
    Sent {
        conversation_id: Uuid,
        message: Message,
    },
    Edited {
        conversation_id: Uuid,
        message: Message,
    },
    Deleted {
        conversation_id: Uuid,
        message_id: Uuid,
    },
    MessageReactionAdded {
        conversation_id: Uuid,
        message_id: Uuid,
        reaction: String,
    },
    MessageReactionRemoved {
        conversation_id: Uuid,
        message_id: Uuid,
        reaction: String,
    },
    TypingIndicator {
        conversation_id: Uuid,
        participant: DID,
    },
    RecipientAdded {
        conversation: raygun::Conversation,
        identity: state::Identity,
    },
    RecipientRemoved {
        conversation: raygun::Conversation,
    },
}

pub async fn convert_message_event(
    event: warp::raygun::MessageEventKind,
    account: &mut super::super::Account,
    messaging: &mut super::super::Messaging,
) -> Result<MessageEvent, Error> {
    log::debug!("got event: {:?}", &event);
    let evt = match event {
        MessageEventKind::MessageReceived {
            conversation_id,
            message_id,
        } => {
            let message = messaging.get_message(conversation_id, message_id).await?;

            // Return the event.
            MessageEvent::Received {
                conversation_id,
                message: convert_raygun_message(messaging, &message).await,
            }
        }
        MessageEventKind::MessageSent {
            conversation_id,
            message_id,
        } => {
            let message = messaging.get_message(conversation_id, message_id).await?;
            MessageEvent::Sent {
                conversation_id,
                message: convert_raygun_message(messaging, &message).await,
            }
        }
        MessageEventKind::MessageDeleted {
            conversation_id,
            message_id,
        } => MessageEvent::Deleted {
            conversation_id,
            message_id,
        },
        MessageEventKind::MessageReactionAdded {
            conversation_id,
            message_id,
            reaction,
            ..
        } => MessageEvent::MessageReactionAdded {
            conversation_id,
            message_id,
            reaction,
        },
        MessageEventKind::MessageReactionRemoved {
            conversation_id,
            message_id,
            reaction,
            ..
        } => MessageEvent::MessageReactionRemoved {
            conversation_id,
            message_id,
            reaction,
        },
        MessageEventKind::EventReceived {
            conversation_id,
            did_key,
            event,
        } => match event {
            raygun::MessageEvent::Typing => MessageEvent::TypingIndicator {
                conversation_id,
                participant: did_key,
            },
        },
        MessageEventKind::MessageEdited {
            conversation_id,
            message_id,
        } => {
            let message = messaging.get_message(conversation_id, message_id).await?;
            MessageEvent::Edited {
                conversation_id,
                message: convert_raygun_message(messaging, &message).await,
            }
        }
        MessageEventKind::RecipientAdded {
            conversation_id,
            recipient,
        } => MessageEvent::RecipientAdded {
            identity: did_to_identity(&recipient, account).await?,
            conversation: messaging.get_conversation(conversation_id).await?,
        },
        MessageEventKind::RecipientRemoved {
            conversation_id, ..
        } => MessageEvent::RecipientRemoved {
            conversation: messaging.get_conversation(conversation_id).await?,
        },
        _ => {
            todo!();
        }
    };

    Ok(evt)
}
