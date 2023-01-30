use uuid::Uuid;
use warp::{error::Error, raygun::RayGunEventKind};

use crate::{
    logger,
    state::{self},
};

use super::{super::conv_stream, conversation_to_chat};

#[allow(clippy::large_enum_variant)]
pub enum RayGunEvent {
    ConversationCreated(state::Chat),
    ConversationDeleted(Uuid),
}

pub async fn convert_raygun_event(
    event: warp::raygun::RayGunEventKind,
    stream_manager: &mut conv_stream::Manager,
    account: &mut super::super::Account,
    messaging: &mut super::super::Messaging,
) -> Result<RayGunEvent, Error> {
    logger::debug(&format!("got {:?}", &event));
    let evt = match event {
        RayGunEventKind::ConversationCreated { conversation_id } => {
            let conv = messaging.get_conversation(conversation_id).await?;
            let chat = conversation_to_chat(&conv, account, messaging).await?;
            stream_manager.add_stream(chat.id, messaging).await?;
            RayGunEvent::ConversationCreated(chat)
        }
        RayGunEventKind::ConversationDeleted { conversation_id } => {
            stream_manager.remove_stream(conversation_id);
            RayGunEvent::ConversationDeleted(conversation_id)
        }
    };

    Ok(evt)
}
