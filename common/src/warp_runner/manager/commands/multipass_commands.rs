use std::collections::HashSet;

use derive_more::Display;
use futures::channel::oneshot;
use warp::{
    crypto::DID,
    error::Error,
    logging::tracing::log,
    multipass::{
        self,
        identity::{self, Identifier, IdentityUpdate},
    },
};

use crate::{
    state::{self, friends},
    warp_runner::{ui_adapter::dids_to_identity, Account},
};

#[derive(Display)]
pub enum MultiPassCmd {
    #[display(fmt = "CreateIdentity {{ username: {username} }} ")]
    CreateIdentity {
        username: String,
        passphrase: String,
        rsp: oneshot::Sender<Result<multipass::identity::Identity, warp::error::Error>>,
    },
    #[display(fmt = "TryLogIn")]
    TryLogIn {
        passphrase: String,
        rsp: oneshot::Sender<Result<multipass::identity::Identity, warp::error::Error>>,
    },
    #[display(fmt = "RequestFriend {{ did: {did} }} ")]
    RequestFriend {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "InitializeFriends")]
    InitializeFriends {
        rsp: oneshot::Sender<
            Result<(friends::Friends, HashSet<state::Identity>), warp::error::Error>,
        >,
    },
    #[display(fmt = "RefreshFriends")]
    RefreshFriends {
        rsp: oneshot::Sender<
            Result<HashMap<DID, multipass::identity::Identity>, warp::error::Error>,
        >,
    },
    // may later want this to return the Identity rather than the DID.
    #[display(fmt = "GetOwnDid")]
    GetOwnDid {
        rsp: oneshot::Sender<Result<DID, warp::error::Error>>,
    },
    #[display(fmt = "RemoveFriend {{ did: {did} }} ")]
    RemoveFriend {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "Unblock {{ did: {did} }} ")]
    Unblock {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    // can block anyone, friend or not
    #[display(fmt = "Block {{ did: {did} }} ")]
    Block {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "AcceptRequest {{ did: {did} }} ")]
    AcceptRequest {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "DenyRequest {{ did: {did} }} ")]
    DenyRequest {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "CancelRequest {{ did: {did} }} ")]
    CancelRequest {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },

    // identity related commands
    #[display(fmt = "UpdateProfilePicture")]
    UpdateProfilePicture {
        pfp: String,
        rsp: oneshot::Sender<Result<identity::Identity, warp::error::Error>>,
    },
    #[display(fmt = "UpdateBanner ")]
    UpdateBanner {
        banner: String,
        rsp: oneshot::Sender<Result<identity::Identity, warp::error::Error>>,
    },
    #[display(fmt = "UpdateStatus")]
    UpdateStatus {
        status: Option<String>,
        rsp: oneshot::Sender<Result<identity::Identity, warp::error::Error>>,
    },
    #[display(fmt = "UpdateUsername")]
    UpdateUsername {
        username: String,
        rsp: oneshot::Sender<Result<identity::Identity, warp::error::Error>>,
    },
}

// hide sensitive information from debug logs
// make Debug do same thing as Display
impl std::fmt::Debug for MultiPassCmd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self}")
    }
}

pub async fn handle_multipass_cmd(cmd: MultiPassCmd, warp: &mut super::super::Warp) {
    match cmd {
        MultiPassCmd::CreateIdentity { .. } | MultiPassCmd::TryLogIn { .. } => {
            // do nothing and drop the rsp channel
        }
        MultiPassCmd::RequestFriend { did, rsp } => {
            let r = warp.multipass.send_request(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::GetOwnDid { rsp } => {
            let r = warp
                .multipass
                .get_own_identity()
                .await
                .map(|id| id.did_key());
            let _ = rsp.send(r);
        }
        MultiPassCmd::InitializeFriends { rsp } => {
            let r = multipass_initialize_friends(&mut warp.multipass).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::RefreshFriends { rsp } => {
            let r = multipass_refresh_friends(&mut warp.multipass).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::RemoveFriend { did, rsp } => {
            let r = warp.multipass.remove_friend(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::Unblock { did, rsp } => {
            let r = warp.multipass.unblock(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::Block { did, rsp } => {
            let r = warp.multipass.block(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::AcceptRequest { did, rsp } => {
            let r = warp.multipass.accept_request(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::DenyRequest { did, rsp } => {
            let r = warp.multipass.deny_request(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::CancelRequest { did, rsp } => {
            let r = warp.multipass.close_request(&did).await;
            let _ = rsp.send(r);
        }
        MultiPassCmd::UpdateProfilePicture { pfp, rsp } => {
            let r = warp
                .multipass
                .update_identity(IdentityUpdate::set_graphics_picture(pfp))
                .await;

            let _ = match r {
                Ok(_) => {
                    let id = warp.multipass.get_own_identity().await;
                    rsp.send(id)
                }
                Err(e) => {
                    log::error!("failed to get own identity: {e}");
                    rsp.send(Err(e))
                }
            };
        }
        MultiPassCmd::UpdateBanner { banner, rsp } => {
            let r = warp
                .multipass
                .update_identity(IdentityUpdate::set_graphics_banner(banner))
                .await;
            let _ = match r {
                Ok(_) => {
                    let id = warp.multipass.get_own_identity().await;
                    rsp.send(id)
                }
                Err(e) => {
                    log::error!("failed to get own identity: {e}");
                    rsp.send(Err(e))
                }
            };
        }
        MultiPassCmd::UpdateStatus { status, rsp } => {
            let r = warp
                .multipass
                .update_identity(IdentityUpdate::set_status_message(status))
                .await;
            let id = warp.multipass.get_own_identity().await;
            let _ = match r {
                Ok(_) => rsp.send(id),
                Err(e) => {
                    log::error!("failed to get own identity: {e}");
                    rsp.send(Err(e))
                }
            };
        }
        MultiPassCmd::UpdateUsername { username, rsp } => {
            let r = warp
                .multipass
                .update_identity(IdentityUpdate::set_username(username))
                .await;
            let id = warp.multipass.get_own_identity().await;
            let _ = match r {
                Ok(_) => rsp.send(id),
                Err(e) => {
                    log::error!("failed to get own identity: {e}");
                    rsp.send(Err(e))
                }
            };
        }
    }
}

async fn multipass_refresh_friends(
    account: &mut Account,
) -> Result<HashMap<DID, multipass::identity::Identity>, Error> {
    let ids = account.list_friends().await?;

    let list = account
        .get_identity(Identifier::did_keys(ids.clone()))
        .await?;
    let friends: HashMap<DID, identity::Identity> = list
        .iter()
        .map(|ident| (ident.did_key(), ident.clone()))
        .collect();
    if list.is_empty() {
        log::warn!("No identities found");
    }
    Ok(friends)
}

async fn multipass_initialize_friends(
    account: &mut Account,
) -> Result<(state::friends::Friends, HashSet<state::Identity>), Error> {
    let reqs = account.list_incoming_request().await?;
    log::trace!("init friends with {} total", reqs.len());
    let incoming_requests = HashSet::from_iter(reqs.iter().cloned());

    let outgoing = account.list_outgoing_request().await?;
    let outgoing_requests = HashSet::from_iter(outgoing.iter().cloned());

    let ids = account.block_list().await?;
    let blocked = HashSet::from_iter(ids.iter().cloned());

    let ids = account.list_friends().await?;
    let friends = HashSet::from_iter(ids.iter().cloned());

    let mut all_ids = Vec::new();
    all_ids.extend(friends.clone());
    all_ids.extend(blocked.clone());
    all_ids.extend(incoming_requests.clone());
    all_ids.extend(outgoing_requests.clone());

    let identities = dids_to_identity(&all_ids, account).await?;
    let ids = HashSet::from_iter(identities.iter().cloned());

    let ret = friends::Friends {
        initialized: true,
        all: friends,
        blocked,
        incoming_requests,
        outgoing_requests,
    };
    Ok((ret, ids))
}
