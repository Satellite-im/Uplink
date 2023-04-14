use derive_more::Display;
use futures::channel::oneshot;
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
};
use uuid::Uuid;
use warp::{
    constellation::ConstellationProgressStream,
    crypto::DID,
    error::Error,
    logging::tracing::log,
    raygun::{self, ConversationType, ReactionState},
};

use crate::{
    state::{self, chats},
    warp_runner::{
        conv_stream,
        ui_adapter::{self, conversation_to_chat, fetch_messages_from_chat},
        Account, Messaging,
    },
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
            Result<(HashMap<Uuid, chats::Chat>, HashSet<state::Identity>), warp::error::Error>,
        >,
    },
    #[display(fmt = "CreateConversation")]
    CreateConversation {
        recipient: DID,
        rsp: oneshot::Sender<Result<Uuid, warp::error::Error>>,
    },
    #[display(fmt = "CreateGroupConversation")]
    CreateGroupConversation {
        recipients: Vec<DID>,
        rsp: oneshot::Sender<Result<Uuid, warp::error::Error>>,
    },
    #[display(fmt = "DeleteConversation")]
    DeleteConversation {
        conv_id: Uuid,
        rsp: oneshot::Sender<Result<Uuid, warp::error::Error>>,
    },
    #[display(fmt = "FetchMessages {{ req_len: {new_len}, current_len: {current_len} }} ")]
    FetchMessages {
        conv_id: Uuid,
        // the total number of messages that should be in the conversation
        new_len: usize,
        // the current size of the conversation
        current_len: usize,
        rsp: oneshot::Sender<Result<Vec<ui_adapter::Message>, warp::error::Error>>,
    },
    #[display(fmt = "SendMessage")]
    SendMessage {
        conv_id: Uuid,
        msg: Vec<String>,
        attachments: Vec<PathBuf>,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "EditMessage")]
    EditMessage {
        conv_id: Uuid,
        msg_id: Uuid,
        msg: Vec<String>,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "DownloadAttachment")]
    DownloadAttachment {
        conv_id: Uuid,
        msg_id: Uuid,
        file_name: String,
        file_path_to_download: PathBuf,
        rsp: oneshot::Sender<Result<ConstellationProgressStream, warp::error::Error>>,
    },
    #[display(fmt = "DeleteMessage")]
    DeleteMessage {
        conv_id: Uuid,
        msg_id: Uuid,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "Reply")]
    Reply {
        conv_id: Uuid,
        reply_to: Uuid,
        msg: Vec<String>,
        attachments: Vec<PathBuf>,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    // removes all direct conversations involving the recipient
    #[display(fmt = "RemoveDirectConvs")]
    RemoveDirectConvs {
        recipient: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "React")]
    React {
        conversation_id: Uuid,
        message_id: Uuid,
        reaction_state: ReactionState,
        emoji: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "SendEvent")]
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
                Ok(conv) | Err(Error::ConversationExist { conversation: conv }) => Ok(conv.id()),
                Err(e) => Err(e),
            };
            let _ = rsp.send(r);
        }
        RayGunCmd::DeleteConversation { conv_id, rsp } => {
            let r = match messaging.delete(conv_id, None).await {
                Ok(_) => Ok(conv_id),
                Err(e) => Err(e),
            };
            let _ = rsp.send(r);
        }
        RayGunCmd::CreateGroupConversation { recipients, rsp } => {
            let r = raygun_create_group_conversation(account, messaging, recipients).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::FetchMessages {
            conv_id,
            new_len,
            current_len,
            rsp,
        } => {
            let to_skip = current_len;
            let to_add = new_len - current_len;
            let r = fetch_messages_from_chat(conv_id, messaging, to_skip, to_add).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::SendMessage {
            conv_id,
            msg,
            attachments,
            rsp,
        } => {
            let r = if attachments.is_empty() {
                messaging.send(conv_id, msg).await
            } else {
                messaging.attach(conv_id, None, attachments, msg).await
            };

            let _ = rsp.send(r);
        }
        RayGunCmd::EditMessage {
            conv_id,
            msg_id,
            msg,
            rsp,
        } => {
            let r = messaging.edit(conv_id, msg_id, msg).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::DownloadAttachment {
            conv_id,
            msg_id,
            file_name,
            file_path_to_download,
            rsp,
        } => {
            let r = messaging
                .download(conv_id, msg_id, file_name, file_path_to_download)
                .await;
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
            attachments,
            rsp,
        } => {
            let r = if attachments.is_empty() {
                messaging.reply(conv_id, reply_to, msg).await
            } else {
                messaging
                    .attach(conv_id, Some(reply_to), attachments, msg)
                    .await
            };

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
) -> Result<(HashMap<Uuid, chats::Chat>, HashSet<state::Identity>), Error> {
    log::trace!("init convs with {} total", convs.len());
    let mut all_chats = HashMap::new();
    let mut identities = HashSet::new();
    for conv in convs {
        match conversation_to_chat(conv, account, messaging).await {
            Ok(chat) => {
                if let Err(e) = stream_manager.add_stream(chat.inner.id, messaging).await {
                    log::error!(
                        "failed to open conversation stream for conv {}: {}",
                        chat.inner.id,
                        e
                    );
                }
                let _ = all_chats.insert(chat.inner.id, chat.inner);
                identities.extend(chat.identities);
            }
            Err(e) => {
                log::error!("failed to convert conversation to chat: {}", e);
            }
        };
    }
    Ok((all_chats, identities))
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

// here's some crazy code to stop creating duplicate group conversations
async fn raygun_create_group_conversation(
    account: &Account,
    messaging: &mut Messaging,
    recipients: Vec<DID>,
) -> Result<Uuid, Error> {
    let mut recipients_set: HashSet<DID> = HashSet::from_iter(recipients.iter().cloned());
    let own_identity = account.get_own_identity().await?;

    recipients_set.insert(own_identity.did_key());
    let existing_conversations = messaging.list_conversations().await?;
    if let Some(conv) = existing_conversations.iter().find(|conv| {
        let conv_recipients: HashSet<DID> = HashSet::from_iter(conv.recipients().iter().cloned());
        conv_recipients == recipients_set
    }) {
        return Ok(conv.id());
    }

    match messaging.create_group_conversation(None, recipients).await {
        Ok(conv) | Err(Error::ConversationExist { conversation: conv }) => Ok(conv.id()),
        Err(e) => Err(e),
    }
}
