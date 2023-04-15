use derive_more::Display;
use uuid::Uuid;
use warp::{error::Error, logging::tracing::log, raygun::RayGunEventKind};

use super::{super::conv_stream, conversation_to_chat, ChatAdapter};

#[allow(clippy::large_enum_variant)]
#[derive(Display)]
pub enum RayGunEvent {
    #[display(fmt = "ConversationCreated ")]
    ConversationCreated(ChatAdapter),
    #[display(fmt = "ConversationDeleted ")]
    ConversationDeleted(Uuid),
}

pub async fn convert_raygun_event(
    event: warp::raygun::RayGunEventKind,
    stream_manager: &mut conv_stream::Manager,
    account: &mut super::super::Account,
    messaging: &mut super::super::Messaging,
) -> Result<RayGunEvent, Error> {
    log::debug!("got {:?}", &event);
    let evt = match event {
        RayGunEventKind::ConversationCreated { conversation_id } => {
            let conv = messaging.get_conversation(conversation_id).await?;
            let chat = conversation_to_chat(&conv, account, messaging).await?;
            stream_manager.add_stream(chat.inner.id, messaging).await?;
            RayGunEvent::ConversationCreated(chat)
        }
        RayGunEventKind::ConversationDeleted { conversation_id } => {
            stream_manager.remove_stream(conversation_id);
            RayGunEvent::ConversationDeleted(conversation_id)
        }
    };

    Ok(evt)
}
