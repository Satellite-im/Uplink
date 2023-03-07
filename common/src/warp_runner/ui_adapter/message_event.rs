use uuid::Uuid;
use warp::{
    crypto::DID,
    error::Error,
    logging::tracing::log,
    raygun::{self, MessageEventKind},
};

use super::Message;
use crate::warp_runner::ui_adapter::convert_raygun_message;

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
}

pub async fn convert_message_event(
    event: warp::raygun::MessageEventKind,
    _account: &mut super::super::Account,
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
        _ => {
            todo!();
        }
    };

    Ok(evt)
}
