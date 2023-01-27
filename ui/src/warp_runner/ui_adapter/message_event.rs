use uuid::Uuid;
use warp::{
    error::Error,
    raygun::{self, MessageEventKind},
};

use crate::logger;

pub enum MessageEvent {
    Received {
        conversation_id: Uuid,
        message: raygun::Message,
    },
    Sent {
        conversation_id: Uuid,
        message: raygun::Message,
    },
}

pub async fn convert_message_event(
    event: warp::raygun::MessageEventKind,
    _account: &mut super::super::Account,
    messaging: &mut super::super::Messaging,
) -> Result<MessageEvent, Error> {
    logger::debug(&format!("got {:?}", &event));
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
        _ => {
            println!("evt received: {:?}", event);
            todo!();
        }
    };

    Ok(evt)
}
