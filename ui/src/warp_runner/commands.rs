use std::collections::{HashMap, HashSet};

use futures::channel::oneshot;
use uuid::Uuid;
use warp::{crypto::DID, tesseract::Tesseract};

use crate::state::{chats, friends};

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
    GetOwnIdentity {
        rsp: oneshot::Sender<Result<DID, warp::error::Error>>,
    },
}

#[derive(Debug)]
pub enum RayGunCmd {
    InitializeConversations {
        rsp: oneshot::Sender<Result<HashMap<Uuid, chats::Chat>, warp::error::Error>>,
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
            let r = match tesseract.unlock(passphrase.as_bytes()) {
                Ok(_) => Ok(()),
                Err(e) => Err(e),
            };
            let _ = rsp.send(r);
        }
    }
}

pub async fn handle_raygun_cmd(cmd: RayGunCmd, account: &mut Account, messaging: &mut Messaging) {
    match cmd {
        RayGunCmd::InitializeConversations { rsp } => match messaging.list_conversations().await {
            Ok(convs) => {
                let mut all_chats = HashMap::new();
                for conv in convs {
                    let chat = conversation_to_chat(conv, account, messaging).await;
                    all_chats.insert(chat.id, chat);
                }
                let _ = rsp.send(Ok(all_chats));
            }
            Err(_e) => {
                // do nothing. will cancel the channel
            }
        },
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
            if let Err(e) = tesseract.unlock(passphrase.as_bytes()) {
                let _ = rsp.send(Err(e));
                return;
            }
            //println!("create_identity: account.create_identity");
            let r = match account.create_identity(Some(&username), None).await {
                Ok(_) => Ok(()),
                Err(e) => Err(e),
            };
            let _ = rsp.send(r);
        }
        MultiPassCmd::TryLogIn { passphrase, rsp } => {
            if let Err(e) = tesseract.unlock(passphrase.as_bytes()) {
                let _ = rsp.send(Err(e));
                return;
            }
            let r = match account.get_own_identity().await {
                Ok(_) => Ok(()),
                Err(e) => Err(e),
            };
            let _ = rsp.send(r);
        }
        MultiPassCmd::RequestFriend { did, rsp } => {
            let r = match account.send_request(&did).await {
                Ok(_) => Ok(()),
                Err(e) => Err(e),
            };
            let _ = rsp.send(r);
        }
        MultiPassCmd::GetOwnIdentity { rsp } => {
            let r = match account.get_own_identity().await {
                Ok(id) => Ok(id.did_key()),
                Err(e) => Err(e),
            };
            let _ = rsp.send(r);
        }
        MultiPassCmd::InitializeFriends { rsp } => {
            let incoming_requests = match account.list_incoming_request().await {
                Ok(reqs) => {
                    let reqs = reqs.iter().map(|r| r.from()).collect();
                    let idents = dids_to_identity(reqs, account).await;
                    HashSet::from_iter(idents.iter().cloned())
                }
                Err(e) => {
                    let _ = rsp.send(Err(e));
                    return;
                }
            };
            let outgoing_requests = match account.list_outgoing_request().await {
                Ok(r) => {
                    let incoming = r.iter().map(|r| r.to()).collect();
                    let idents = dids_to_identity(incoming, account).await;
                    HashSet::from_iter(idents.iter().cloned())
                }
                Err(e) => {
                    let _ = rsp.send(Err(e));
                    return;
                }
            };
            let blocked = match account.block_list().await {
                Ok(ids) => {
                    let idents = dids_to_identity(ids, account).await;
                    HashSet::from_iter(idents.iter().cloned())
                }
                Err(e) => {
                    let _ = rsp.send(Err(e));
                    return;
                }
            };
            let friends = match account.list_friends().await {
                Ok(ids) => {
                    let mut res = HashMap::new();
                    for id in ids {
                        let ident = did_to_identity(id.clone(), account).await;
                        res.insert(id, ident);
                    }
                    res
                }
                Err(e) => {
                    let _ = rsp.send(Err(e));
                    return;
                }
            };

            let ret = friends::Friends {
                initialized: true,
                all: friends,
                blocked,
                incoming_requests,
                outgoing_requests,
            };
            let _ = rsp.send(Ok(ret));
        }
    }
}
