use derive_more::Display;
use uuid::Uuid;
use warp::{
    crypto::DID,
    error::Error,
    raygun::{self, MessageEventKind},
};

use super::Message;
use crate::warp_runner::ui_adapter::convert_raygun_message;
#[derive(Display)]
pub enum MessageEvent {
    #[display(fmt = "Received")]
    Received {
        conversation_id: Uuid,
        message: Message,
    },
    #[display(fmt = "Sent")]
    Sent {
        conversation_id: Uuid,
        message: Message,
    },
    #[display(fmt = "Edited")]
    Edited {
        conversation_id: Uuid,
        message: Message,
    },
    #[display(fmt = "Deleted")]
    Deleted {
        conversation_id: Uuid,
        message_id: Uuid,
    },
    #[display(fmt = "MessageReactionAdded")]
    MessageReactionAdded {
        conversation_id: Uuid,
        message_id: Uuid,
        reaction: String,
        did_key: DID,
    },
    #[display(fmt = "MessageReactionRemoved")]
    MessageReactionRemoved {
        conversation_id: Uuid,
        message_id: Uuid,
        reaction: String,
        did_key: DID,
    },
    #[display(fmt = "TypingIndicator")]
    TypingIndicator {
        conversation_id: Uuid,
        participant: DID,
    },
}

pub async fn convert_message_event(
    event: warp::raygun::MessageEventKind,
    _account: &mut super::super::Account,
    messaging: &mut super::super::Messaging,
) -> Result<MessageEvent, Error> {
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
            did_key,
        } => MessageEvent::MessageReactionAdded {
            conversation_id,
            message_id,
            reaction,
            did_key,
        },
        MessageEventKind::MessageReactionRemoved {
            conversation_id,
            message_id,
            reaction,
            did_key,
        } => MessageEvent::MessageReactionRemoved {
            conversation_id,
            message_id,
            reaction,
            did_key,
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
        _ => {
            todo!();
        }
    };

    Ok(evt)
}
