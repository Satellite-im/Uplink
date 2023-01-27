use uuid::Uuid;
use warp::{
    error::Error,
    logging::tracing::log,
    raygun::{self, MessageEventKind},
};

pub enum MessageEvent {
    Received {
        conversation_id: Uuid,
        message: raygun::Message,
    },
    Sent {
        conversation_id: Uuid,
        message: raygun::Message,
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
            MessageEvent::Received {
                conversation_id,
                message,
            }
        }
        MessageEventKind::MessageSent {
            conversation_id,
            message_id,
        } => {
            let message = messaging.get_message(conversation_id, message_id).await?;
            MessageEvent::Sent {
                conversation_id,
                message,
            }
        }
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
        _ => {
            println!("evt received: {:?}", event);
            todo!();
        }
    };

    Ok(evt)
}
