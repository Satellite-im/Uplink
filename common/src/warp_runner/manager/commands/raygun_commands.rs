use derive_more::Display;
use futures::channel::oneshot;
use std::{collections::HashMap, path::PathBuf};
use uuid::Uuid;
use warp::{
    crypto::DID,
    error::Error,
    logging::tracing::log,
    raygun::{self, ConversationType, ReactionState},
};

use crate::{
    state::{self, chats},
    warp_runner::{conv_stream, ui_adapter::conversation_to_chat, Account, Messaging},
};

#[allow(clippy::large_enum_variant)]
#[derive(Display)]
pub enum RayGunCmd {
    #[display(fmt = "InitializeConversations")]
    InitializeConversations {
        // response is (own identity, chats)
        // need to send over own identity because 'State' sets it to default
        #[allow(clippy::type_complexity)]
        rsp: oneshot::Sender<
            Result<(state::Identity, HashMap<Uuid, chats::Chat>), warp::error::Error>,
        >,
    },
    #[display(fmt = "CreateConversation {{ did: {recipient} }} ")]
    CreateConversation {
        recipient: DID,
        rsp: oneshot::Sender<Result<chats::Chat, warp::error::Error>>,
    },
    #[display(fmt = "SendMessage {{ conv_id: {conv_id} }} ")]
    SendMessage {
        conv_id: Uuid,
        msg: Vec<String>,
        attachments: Vec<PathBuf>,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "DeleteMessage {{ conv_id: {conv_id}, msg_id: {msg_id} }} ")]
    DeleteMessage {
        conv_id: Uuid,
        msg_id: Uuid,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "Reply {{ conv_id: {conv_id}, reply_to: {reply_to} }} ")]
    Reply {
        conv_id: Uuid,
        reply_to: Uuid,
        msg: Vec<String>,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    // removes all direct conversations involving the recipient
    #[display(fmt = "RemoveDirectConvs {{ recipient: {recipient} }} ")]
    RemoveDirectConvs {
        recipient: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "React {{ conversation_id: {conversation_id} }} ")]
    React {
        conversation_id: Uuid,
        message_id: Uuid,
        reaction_state: ReactionState,
        emoji: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "SendEvent {{ conv_id: {conv_id} }} ")]
    SendEvent {
        conv_id: Uuid,
        event: raygun::MessageEvent,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
}

impl std::fmt::Debug for RayGunCmd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self}")
    }
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
            Err(e) => {
                log::error!("failed to initialize conversations: {}", e);
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
        RayGunCmd::SendMessage {
            conv_id,
            msg,
            attachments,
            rsp,
        } => {
            let r = if attachments.is_empty() {
                messaging.send(conv_id, None, msg).await
            } else {
                messaging.attach(conv_id, attachments, msg).await
            };

            let _ = rsp.send(r);
        }
        RayGunCmd::DeleteMessage {
            conv_id,
            msg_id,
            rsp,
        } => {
            let r = messaging.delete(conv_id, Some(msg_id)).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::Reply {
            conv_id,
            reply_to,
            msg,
            rsp,
        } => {
            let r = messaging.reply(conv_id, reply_to, msg).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::RemoveDirectConvs { recipient, rsp } => {
            let r = raygun_remove_direct_convs(recipient, messaging).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::React {
            conversation_id,
            message_id,
            reaction_state,
            emoji,
            rsp,
        } => {
            let r = messaging
                .react(conversation_id, message_id, reaction_state, emoji)
                .await;
            let _ = rsp.send(r);
        }
        RayGunCmd::SendEvent {
            conv_id,
            event,
            rsp,
        } => {
            let r = messaging.send_event(conv_id, event).await;
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
                    log::error!(
                        "failed to open conversation stream for conv {}: {}",
                        chat.id,
                        e
                    );
                }
                let _ = all_chats.insert(chat.id, chat);
            }
            Err(e) => {
                log::error!("failed to convert conversation to chat: {}", e);
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
