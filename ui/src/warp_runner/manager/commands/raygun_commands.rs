use std::collections::HashMap;

use futures::channel::oneshot;
use uuid::Uuid;
use warp::{
    crypto::DID,
    error::Error,
    logging::tracing::log,
    raygun::{self, ConversationType},
};

use crate::{
    logger,
    state::{self, chats},
    warp_runner::{conv_stream, ui_adapter::conversation_to_chat, Account, Messaging},
};

#[allow(clippy::large_enum_variant)]
#[derive(Debug)]
pub enum RayGunCmd {
    InitializeConversations {
        // response is (own identity, chats)
        // need to send over own identity because 'State' sets it to default
        #[allow(clippy::type_complexity)]
        rsp: oneshot::Sender<
            Result<(state::Identity, HashMap<Uuid, chats::Chat>), warp::error::Error>,
        >,
    },
    CreateConversation {
        recipient: DID,
        rsp: oneshot::Sender<Result<chats::Chat, warp::error::Error>>,
    },
    SendMessage {
        conv_id: Uuid,
        msg: Vec<String>,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    // removes all direct conversations involving the recipient
    RemoveDirectConvs {
        recipient: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
}

pub async fn handle_raygun_cmd(
    cmd: RayGunCmd,
    stream_manager: &mut conv_stream::Manager,
    account: &mut Account,
    messaging: &mut Messaging,
) {
    match cmd {
        RayGunCmd::InitializeConversations { rsp } => match messaging.list_conversations().await {
            Ok(convs) => {
                let r = raygun_initialize_conversations(&convs, stream_manager, account, messaging)
                    .await;
                let _ = rsp.send(r);
            }
            Err(_e) => {
                // do nothing. will cancel the channel
                // could happen if warp isn't available yet
            }
        },
        RayGunCmd::CreateConversation { recipient, rsp } => {
            let r = match messaging.create_conversation(&recipient).await {
                Ok(conv) | Err(Error::ConversationExist { conversation: conv }) => {
                    conversation_to_chat(&conv, account, messaging).await
                }
                Err(e) => Err(e),
            };
            let _ = rsp.send(r);
        }
        RayGunCmd::SendMessage { conv_id, msg, rsp } => {
            let r = messaging.send(conv_id, None, msg).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::RemoveDirectConvs { recipient, rsp } => {
            let r = raygun_remove_direct_convs(recipient, messaging).await;
            let _ = rsp.send(r);
        }
    }
}

async fn raygun_initialize_conversations(
    convs: &[raygun::Conversation],
    stream_manager: &mut conv_stream::Manager,
    account: &Account,
    messaging: &mut Messaging,
) -> Result<(state::Identity, HashMap<Uuid, chats::Chat>), Error> {
    log::trace!("init convs with {} total", convs.len());
    let own_identity = account.get_own_identity().await?;
    let mut all_chats = HashMap::new();
    for conv in convs {
        match conversation_to_chat(conv, account, messaging).await {
            Ok(chat) => {
                if let Err(e) = stream_manager.add_stream(chat.id, messaging).await {
                    logger::error(&format!(
                        "failed to open conversation stream for conv {}: {}",
                        chat.id, e
                    ));
                }
                let _ = all_chats.insert(chat.id, chat);
            }
            Err(e) => {
                logger::error(&format!("failed to convert conversation to chat: {}", e));
            }
        };
    }
    Ok((state::Identity::from(own_identity), all_chats))
}

async fn raygun_remove_direct_convs(
    recipient: DID,
    messaging: &mut Messaging,
) -> Result<(), Error> {
    match messaging.list_conversations().await {
        Ok(convs) => {
            for conv in convs {
                // check if conversation should be deleted
                // only consider conversations with 2 participants
                if conv.conversation_type() == ConversationType::Direct
                    && conv.recipients().contains(&recipient)
                {
                    messaging.delete(conv.id(), None).await?;
                }
            }
            Ok(())
        }
        Err(e) => Err(e),
    }
}
