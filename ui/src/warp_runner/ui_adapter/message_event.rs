use uuid::Uuid;
use warp::{
    crypto::DID,
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

            // TODO: Get state available in this scope.
            // Dispatch notifications only when we're not already focused on the application.
            let notifications_enabled = state
                .read()
                .configuration
                .config
                .notifications
                .message_notifications;
            let should_play_sound =
                notifications_enabled && state.read().chats.active != conversation_id;
            let should_dispatch_notification =
                notifications_enabled && !state.read().ui.metadata.focused;

            state.write().mutate(state::Action::AddNotification(
                state::notifications::NotificaitonKind::Notification,
                1,
            ));

            if should_dispatch_notification {
                crate::utils::notifications::push_notification(
                    "New friend request!".into(),
                    format!("{} sent a request.", "NOT YET IMPL"),
                    Some(crate::utils::sounds::Sounds::Notification),
                    notify_rust::Timeout::Milliseconds(4),
                );
            } else if should_play_sound {
                crate::utils::sounds::Play(crate::utils::sounds::Sounds::Notification);
            }

            // Return the event.
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
        _ => {
            println!("evt received: {event:?}");
            todo!();
        }
    };

    Ok(evt)
}
