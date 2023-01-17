use std::collections::{HashMap, HashSet};

use futures::channel::oneshot;
use uuid::Uuid;
use warp::{crypto::DID, error::Error, tesseract::Tesseract};

use crate::state::{self, chats, friends};

use super::{
    ui_adapter::{conversation_to_chat, did_to_identity, dids_to_identity},
    Account, Messaging,
};

#[derive(Debug)]
pub enum TesseractCmd {
    KeyExists {
        key: String,
        rsp: oneshot::Sender<bool>,
    },
    Unlock {
        passphrase: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
}

#[derive(Debug)]
pub enum MultiPassCmd {
    CreateIdentity {
        username: String,
        passphrase: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    TryLogIn {
        passphrase: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    RequestFriend {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    InitializeFriends {
        rsp: oneshot::Sender<Result<friends::Friends, warp::error::Error>>,
    },
    // may later want this to return the Identity rather than the DID.
    GetOwnDid {
        rsp: oneshot::Sender<Result<DID, warp::error::Error>>,
    },
    RemoveFriend {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    Unblock {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    // can block anyone, friend or not
    Block {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    AcceptRequest {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    DenyRequest {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    CancelRequest {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
}

#[allow(clippy::large_enum_variant)]
#[derive(Debug)]
pub enum RayGunCmd {
    InitializeConversations {
        rsp: oneshot::Sender<Result<HashMap<Uuid, chats::Chat>, warp::error::Error>>,
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
}

// currently unused
pub async fn handle_tesseract_cmd(cmd: TesseractCmd, tesseract: &mut Tesseract) {
    match cmd {
        TesseractCmd::KeyExists { key, rsp } => {
            let res = tesseract.exist(&key);
            let _ = rsp.send(res);
        }
        TesseractCmd::Unlock { passphrase, rsp } => {
            let r = tesseract.unlock(passphrase.as_bytes());
            let _ = rsp.send(r);
        }
    }
}

pub async fn handle_raygun_cmd(cmd: RayGunCmd, account: &mut Account, messaging: &mut Messaging) {
    match cmd {
        RayGunCmd::InitializeConversations { rsp } => match messaging.list_conversations().await {
            Ok(convs) => {
                //println!("warp runner got conversations: {:#?}", convs);
                let mut all_chats = HashMap::new();
                for conv in convs {
                    match conversation_to_chat(conv, account, messaging).await {
                        Ok(chat) => {
                            let _ = all_chats.insert(chat.id, chat);
                        }
                        Err(_e) => todo!("log error"),
                    };
                }
                let _ = rsp.send(Ok(all_chats));
            }
            Err(_e) => {
                // do nothing. will cancel the channel
                // could happen if warp isn't available yet
            }
        },
        RayGunCmd::CreateConversation { recipient, rsp } => {
            let r = match messaging.create_conversation(&recipient).await {
                Ok(conv) | Err(Error::ConversationExist { conversation: conv }) => {
                    conversation_to_chat(conv, account, messaging).await
                }
                Err(e) => Err(e),
            };
            let _ = rsp.send(r);
        }
        RayGunCmd::SendMessage { conv_id, msg, rsp } => {
            let r = messaging.send(conv_id, None, msg).await;
            let _ = rsp.send(r);
        }
    }
}

pub async fn handle_multipass_cmd(
    cmd: MultiPassCmd,
    tesseract: &mut Tesseract,
    account: &mut Account,
) {
    match cmd {
        MultiPassCmd::CreateIdentity {
            username,
            passphrase,
            rsp,
        } => {
            //println!("create_identity: unlock tesseract");
            let r = multipass_create_identity(&username, &passphrase, tesseract, account).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::TryLogIn { passphrase, rsp } => {
            if let Err(e) = tesseract.unlock(passphrase.as_bytes()) {
                let _ = rsp.send(Err(e));
                return;
            }
            // without the delay, there is an error that the multipass extension is unavailable
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            let r = account.get_own_identity().await.map(|_| ());
            let _ = rsp.send(r);
        }
        MultiPassCmd::RequestFriend { did, rsp } => {
            let r = account.send_request(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::GetOwnDid { rsp } => {
            let r = account.get_own_identity().await.map(|id| id.did_key());
            let _ = rsp.send(r);
        }
        MultiPassCmd::InitializeFriends { rsp } => {
            let r = multipass_initialize_friends(account).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::RemoveFriend { did, rsp } => {
            let r = account.remove_friend(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::Unblock { did, rsp } => {
            let r = account.unblock(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::Block { did, rsp } => {
            let r = account.block(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::AcceptRequest { did, rsp } => {
            let r = account.accept_request(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::DenyRequest { did, rsp } => {
            let r = account.deny_request(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::CancelRequest { did, rsp } => {
            let r = account.close_request(&did).await;
            let _ = rsp.send(r);
        }
    }
}

async fn multipass_create_identity(
    username: &str,
    passphrase: &str,
    tesseract: &mut Tesseract,
    account: &mut Account,
) -> Result<(), Error> {
    tesseract.unlock(passphrase.as_bytes())?;
    //println!("create_identity: account.create_identity");
    let _ = account.create_identity(Some(username), None).await?;
    Ok(())
}

async fn multipass_initialize_friends(
    account: &mut Account,
) -> Result<state::friends::Friends, Error> {
    let reqs = account.list_incoming_request().await?;
    let idents = dids_to_identity(reqs, account).await?;
    let incoming_requests = HashSet::from_iter(idents.iter().cloned());

    let outgoing = account.list_outgoing_request().await?;
    let idents = dids_to_identity(outgoing, account).await?;
    let outgoing_requests = HashSet::from_iter(idents.iter().cloned());

    let ids = account.block_list().await?;
    let idents = dids_to_identity(ids, account).await?;
    let blocked = HashSet::from_iter(idents.iter().cloned());

    let ids = account.list_friends().await?;
    let mut friends = HashMap::new();
    for id in ids {
        let ident = did_to_identity(id.clone(), account).await?;
        friends.insert(id, ident);
    }

    let ret = friends::Friends {
        initialized: true,
        all: friends,
        blocked,
        incoming_requests,
        outgoing_requests,
    };
    Ok(ret)
}
