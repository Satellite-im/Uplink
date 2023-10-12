use chrono::{DateTime, Utc};
use derive_more::Display;
use futures::{channel::oneshot, StreamExt};
use std::{
    collections::{HashMap, HashSet},
    ops::Range,
    path::PathBuf,
};
use uuid::Uuid;
use warp::{
    constellation::ConstellationProgressStream,
    crypto::DID,
    error::Error,
    logging::tracing::log,
    raygun::{self, AttachmentKind, ConversationType, Location, PinState, ReactionState},
};

use crate::{
    state::{chats, identity, pending_message::PendingMessage, Friends},
    warp_runner::{
        conv_stream,
        ui_adapter::{
            self, conversation_to_chat, dids_to_identity, fetch_messages2, fetch_messages_between,
            fetch_messages_from_chat, fetch_pinned_messages_from_chat, get_uninitialized_identity,
            MessageEvent,
        },
        Account, FetchMessagesConfig, FetchMessagesResponse, Messaging, WarpEvent,
    },
    WARP_EVENT_CH,
};

#[allow(clippy::large_enum_variant)]
#[derive(Display)]
pub enum RayGunCmd {
    #[display(fmt = "InitializeWarp")]
    InitializeWarp {
        // need to send over own identity because 'State' sets it to default
        rsp: oneshot::Sender<Result<WarpInit, warp::error::Error>>,
    },
    #[display(fmt = "CreateConversation")]
    CreateConversation {
        recipient: DID,
        rsp: oneshot::Sender<Result<Uuid, warp::error::Error>>,
    },
    #[display(fmt = "CreateGroupConversation")]
    CreateGroupConversation {
        recipients: Vec<DID>,
        group_name: Option<String>,
        rsp: oneshot::Sender<Result<Uuid, warp::error::Error>>,
    },
    #[display(fmt = "AddGroupParticipants")]
    AddGroupParticipants {
        conv_id: Uuid,
        recipients: Vec<DID>,
        rsp: oneshot::Sender<Result<Uuid, warp::error::Error>>,
    },
    #[display(fmt = "RemoveGroupParticipants")]
    RemoveGroupParticipants {
        conv_id: Uuid,
        recipients: Vec<DID>,
        rsp: oneshot::Sender<Result<Uuid, warp::error::Error>>,
    },
    #[display(fmt = "UpdateConversationName")]
    UpdateConversationName {
        conv_id: Uuid,
        new_conversation_name: String,
        rsp: oneshot::Sender<Result<Uuid, warp::error::Error>>,
    },
    #[display(fmt = "DeleteConversation")]
    DeleteConversation {
        conv_id: Uuid,
        rsp: oneshot::Sender<Result<Uuid, warp::error::Error>>,
    },
    #[display(fmt = "FetchMessages")]
    FetchMessages {
        conv_id: Uuid,
        // if None, will start from the beginning of the conversation.
        config: FetchMessagesConfig,
        rsp: oneshot::Sender<Result<FetchMessagesResponse, warp::error::Error>>,
    },
    #[display(fmt = "FetchMessages {{ req: {to_fetch}, current_len: {current_len} }} ")]
    FetchMessagesDeprecated {
        conv_id: Uuid,
        // the total number of messages that should be in the conversation
        to_fetch: usize,
        // the current size of the conversation
        current_len: usize,
        rsp: oneshot::Sender<Result<(Vec<ui_adapter::Message>, bool), warp::error::Error>>,
    },
    #[display(fmt = "FetchMessagesBetween {{ range: {date_range:?} }} ")]
    FetchMessagesBetween {
        conv_id: Uuid,
        // time range to fetch messages from
        date_range: Range<DateTime<Utc>>,
        rsp: oneshot::Sender<Result<(Vec<ui_adapter::Message>, bool), warp::error::Error>>,
    },
    #[display(fmt = "FetchPinnedMessages")]
    FetchPinnedMessages {
        conv_id: Uuid,
        rsp: oneshot::Sender<Result<Vec<ui_adapter::Message>, warp::error::Error>>,
    },
    #[display(fmt = "SendMessage")]
    SendMessage {
        conv_id: Uuid,
        msg: Vec<String>,
        attachments: Vec<Location>,
        ui_msg_id: Option<Uuid>,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "SendMessageForSeveralChats")]
    SendMessageForSeveralChats {
        convs_id: Vec<Uuid>,
        msg: Vec<String>,
        attachments: Vec<Location>,
        ui_msg_id: Option<Uuid>,
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
        attachments: Vec<Location>,
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
    #[display(fmt = "Pin {{ pin: {pinstate:?} }} ")]
    Pin {
        conversation_id: Uuid,
        message_id: Uuid,
        pinstate: PinState,
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
        RayGunCmd::InitializeWarp { rsp } => {
            let r = init_warp(stream_manager, account, messaging).await;
            let _ = rsp.send(r);
        }
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
        RayGunCmd::CreateGroupConversation {
            recipients,
            group_name,
            rsp,
        } => {
            let r = raygun_create_group_conversation(messaging, recipients, group_name).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::AddGroupParticipants {
            conv_id,
            recipients,
            rsp,
        } => {
            let r = raygun_add_recipients_to_a_group(conv_id, recipients, messaging).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::RemoveGroupParticipants {
            conv_id,
            recipients,
            rsp,
        } => {
            let r = raygun_remove_recipients_from_a_group(conv_id, recipients, messaging).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::UpdateConversationName {
            conv_id,
            new_conversation_name,
            rsp,
        } => {
            let r = messaging
                .update_conversation_name(conv_id, &new_conversation_name)
                .await
                .map(|_| conv_id);
            let _ = rsp.send(r);
        }
        RayGunCmd::FetchMessages {
            conv_id,
            config,
            rsp,
        } => {
            let r = fetch_messages2(conv_id, messaging, config).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::FetchMessagesDeprecated {
            conv_id,
            to_fetch,
            current_len,
            rsp,
        } => {
            let r = fetch_messages_from_chat(conv_id, messaging, to_fetch + current_len).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::FetchMessagesBetween {
            conv_id,
            date_range,
            rsp,
        } => {
            let r = fetch_messages_between(conv_id, messaging, date_range).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::FetchPinnedMessages { conv_id, rsp } => {
            let r = fetch_pinned_messages_from_chat(conv_id, messaging).await;
            let _ = rsp.send(r);
        }
        RayGunCmd::SendMessage {
            conv_id,
            msg,
            attachments,
            ui_msg_id: ui_id,
            rsp,
        } => {
            let r = if attachments.is_empty() {
                messaging.send(conv_id, msg).await
            } else {
                //TODO: Pass stream off to attachment events
                match messaging
                    .attach(conv_id, None, attachments.clone(), msg.clone())
                    .await
                {
                    Ok(mut stream) => loop {
                        let msg_clone = msg.clone();
                        //let attachment_clone = attachments.clone();
                        if let Some(kind) = stream.next().await {
                            match kind {
                                AttachmentKind::Pending(result) => {
                                    break result;
                                }
                                AttachmentKind::AttachedProgress(progress) => {
                                    if WARP_EVENT_CH
                                        .tx
                                        .send(WarpEvent::Message(
                                            MessageEvent::AttachmentProgress {
                                                progress,
                                                conversation_id: conv_id,
                                                msg: PendingMessage::for_compare(
                                                    msg_clone,
                                                    &attachments,
                                                    ui_id,
                                                ),
                                            },
                                        ))
                                        .is_err()
                                    {
                                        log::error!("failed to send warp_event");
                                    }
                                }
                            }
                        }
                    },
                    Err(e) => Err(e),
                }
            };

            let _ = rsp.send(r);
        }
        RayGunCmd::SendMessageForSeveralChats {
            convs_id,
            msg,
            attachments,
            ui_msg_id: ui_id,
            rsp,
        } => {
            for chat_id in convs_id {
                let _ = if attachments.is_empty() {
                    messaging.send(chat_id, msg.clone()).await
                } else {
                    //TODO: Pass stream off to attachment events
                    match messaging
                        .attach(chat_id, None, attachments.clone(), msg.clone())
                        .await
                    {
                        Ok(mut stream) => loop {
                            let msg_clone = msg.clone();
                            //let attachment_clone = attachments.clone();
                            if let Some(kind) = stream.next().await {
                                match kind {
                                    AttachmentKind::Pending(result) => {
                                        break result;
                                    }
                                    AttachmentKind::AttachedProgress(progress) => {
                                        if WARP_EVENT_CH
                                            .tx
                                            .send(WarpEvent::Message(
                                                MessageEvent::AttachmentProgress {
                                                    progress,
                                                    conversation_id: chat_id,
                                                    msg: PendingMessage::for_compare(
                                                        msg_clone,
                                                        &attachments,
                                                        ui_id,
                                                    ),
                                                },
                                            ))
                                            .is_err()
                                        {
                                            log::error!("failed to send warp_event");
                                        }
                                    }
                                }
                            }
                        },
                        Err(e) => {
                            log::error!("Raygun: Send files to several chats: {}", e);
                            Err(e)
                        }
                    }
                };
            }

            let _ = rsp.send(Ok(()));
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
                //TODO: Pass stream off to attachment events
                match messaging
                    .attach(conv_id, Some(reply_to), attachments, msg)
                    .await
                {
                    Ok(mut stream) => loop {
                        if let Some(AttachmentKind::Pending(result)) = stream.next().await {
                            break result;
                        }
                    },
                    Err(e) => Err(e),
                }
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
        RayGunCmd::Pin {
            conversation_id,
            message_id,
            pinstate,
            rsp,
        } => {
            let r = messaging.pin(conversation_id, message_id, pinstate).await;
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

pub struct WarpInit {
    pub friends: Friends,
    // at some point we may want to initialize identities on demand, such as only initialize the ones needed for the chats sidebar
    //all_identities: HashSet<DID>,
    pub converted_identities: HashMap<DID, identity::Identity>,
    // todo: don't init all conversations at once. instead, store list of all conv ids
    // and initialized conversations separately
    //all_conv_ids: HashSet<Uuid>,
    pub chats: HashMap<Uuid, chats::SendableChat>,
}

// init friends, chats, and identities all at once
async fn init_warp(
    stream_manager: &mut conv_stream::Manager,
    account: &mut Account,
    messaging: &mut Messaging,
) -> Result<WarpInit, Error> {
    log::trace!("init_warp starting");
    let conversations = messaging.list_conversations().await?;
    //let mut all_conv_ids = HashSet::new();
    let mut all_identities = HashSet::new();
    let friends = Friends {
        all: HashSet::from_iter(account.list_friends().await?),
        blocked: HashSet::from_iter(account.block_list().await?),
        incoming_requests: HashSet::from_iter(account.list_incoming_request().await?),
        outgoing_requests: HashSet::from_iter(account.list_outgoing_request().await?),
    };
    all_identities.extend(friends.all.iter().cloned());
    all_identities.extend(friends.blocked.iter().cloned());
    all_identities.extend(friends.incoming_requests.iter().cloned());
    all_identities.extend(friends.outgoing_requests.iter().cloned());

    let mut chats = HashMap::new();
    for conv in conversations {
        all_identities.extend(conv.recipients());
        //all_conv_ids.insert(conv.id());

        if let Err(e) = stream_manager.add_stream(conv.id(), messaging).await {
            log::error!(
                "failed to open conversation stream for conv {}: {}",
                conv.id(),
                e
            );
        }
        match conversation_to_chat(&conv, messaging).await {
            Ok(chat) => {
                chats.insert(conv.id(), chat);
            }
            Err(e) => {
                log::error!("failed to convert conversation to chat: {e}");
            }
        };
    }

    // ensure that own identity gets fetched
    let own_id = account.get_own_identity().await?;
    all_identities.insert(own_id.did_key());

    let identifier_vec = Vec::from_iter(all_identities.iter().cloned());
    let mut converted_identities = HashMap::new();
    for identity in dids_to_identity(identifier_vec.into(), account)
        .await?
        .drain(..)
    {
        converted_identities.insert(identity.did_key(), identity);
    }

    // dids_to_identity won't return an Identity if it couldn't be retrieved from MultiPass.
    for identity in all_identities {
        // using Entry::Vacant makes clippy happy
        if let std::collections::hash_map::Entry::Vacant(e) =
            converted_identities.entry(identity.clone())
        {
            let uninit_id = get_uninitialized_identity(&identity)?;
            e.insert(uninit_id);
        }
    }

    log::trace!(
        "init warp with {} friends and {} conversations",
        friends.all.len(),
        chats.len()
    );
    Ok(WarpInit {
        friends,
        converted_identities,
        chats,
    })
}

async fn raygun_add_recipients_to_a_group(
    conv_id: Uuid,
    recipients: Vec<DID>,
    messaging: &mut Messaging,
) -> Result<Uuid, Error> {
    for recipient in recipients {
        if let Err(e) = messaging.add_recipient(conv_id, &recipient).await {
            log::error!(
                "failed to add {} to group conv: {}. Error: {}",
                recipient,
                conv_id,
                e
            );
        }
    }
    Ok(conv_id)
}

async fn raygun_remove_recipients_from_a_group(
    conv_id: Uuid,
    recipients: Vec<DID>,
    messaging: &mut Messaging,
) -> Result<Uuid, Error> {
    for recipient in recipients {
        if let Err(e) = messaging.remove_recipient(conv_id, &recipient).await {
            log::error!(
                "failed to remove {} from group conv: {}. Error: {}",
                recipient,
                conv_id,
                e
            );
        }
    }
    Ok(conv_id)
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

async fn raygun_create_group_conversation(
    messaging: &mut Messaging,
    recipients: Vec<DID>,
    group_name: Option<String>,
) -> Result<Uuid, Error> {
    match messaging
        .create_group_conversation(group_name, recipients)
        .await
    {
        Ok(conv) | Err(Error::ConversationExist { conversation: conv }) => Ok(conv.id()),
        Err(e) => Err(e),
    }
}
