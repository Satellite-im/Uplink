use std::{collections::HashMap, slice, str::FromStr};

use derive_more::Display;

use futures::channel::oneshot;
use warp::{
    constellation::file::FileType,
    crypto::DID,
    error::Error,
    multipass::{
        self,
        identity::{self, Identifier, IdentityImage, IdentityStatus, IdentityUpdate},
    },
};

use tracing::log;

use crate::{
    profile_update_channel::fetch_identity_data,
    state::{self, Identity},
    warp_runner::{ui_adapter::dids_to_identity, Account},
};

#[derive(Display)]
pub enum MultiPassCmd {
    #[display(fmt = "RecoverIdentity")]
    RecoverIdentity {
        passphrase: String,
        seed_words: String,
        rsp: oneshot::Sender<Result<multipass::identity::Identity, warp::error::Error>>,
    },
    #[display(fmt = "CreateIdentity")]
    CreateIdentity {
        username: String,
        // used to password protect tesseract
        tesseract_passphrase: String,
        // this is the "pass phrase" for multipass
        seed_words: String,
        rsp: oneshot::Sender<Result<multipass::identity::Identity, warp::error::Error>>,
    },
    #[display(fmt = "TryLogIn")]
    TryLogIn {
        passphrase: String,
        rsp: oneshot::Sender<Result<multipass::identity::Identity, warp::error::Error>>,
    },
    #[display(fmt = "RequestFriend")]
    RequestFriend {
        id: String,
        outgoing_requests: Vec<Identity>,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "RefreshFriends")]
    RefreshFriends {
        rsp: oneshot::Sender<Result<HashMap<DID, state::Identity>, warp::error::Error>>,
    },
    // may later want this to return the Identity rather than the DID.
    #[display(fmt = "GetOwnDid")]
    GetOwnDid {
        rsp: oneshot::Sender<Result<DID, warp::error::Error>>,
    },
    #[display(fmt = "RemoveFriend")]
    RemoveFriend {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "Unblock")]
    Unblock {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    // can block anyone, friend or not
    #[display(fmt = "Block")]
    Block {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "AcceptRequest")]
    AcceptRequest {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "DenyRequest")]
    DenyRequest {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "CancelRequest")]
    CancelRequest {
        did: DID,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },

    // identity related commands
    #[display(fmt = "UpdateProfilePicture")]
    GetProfilePicture {
        did: DID,
        rsp: oneshot::Sender<Result<String, warp::error::Error>>,
    },
    #[display(fmt = "UpdateProfilePicture")]
    GetProfileBanner {
        did: DID,
        rsp: oneshot::Sender<Result<String, warp::error::Error>>,
    },
    #[display(fmt = "UpdateProfilePicture")]
    UpdateProfilePicture {
        pfp: Vec<u8>,
        rsp: oneshot::Sender<Result<Identity, warp::error::Error>>,
    },
    #[display(fmt = "ClearProfilePicture")]
    ClearProfilePicture {
        rsp: oneshot::Sender<Result<Identity, warp::error::Error>>,
    },
    #[display(fmt = "ClearBanner")]
    ClearBanner {
        rsp: oneshot::Sender<Result<Identity, warp::error::Error>>,
    },
    #[display(fmt = "UpdateBanner")]
    UpdateBanner {
        banner: Vec<u8>,
        rsp: oneshot::Sender<Result<Identity, warp::error::Error>>,
    },
    #[display(fmt = "UpdateStatusMessage")]
    UpdateStatusMessage {
        status: Option<String>,
        rsp: oneshot::Sender<Result<Identity, warp::error::Error>>,
    },
    #[display(fmt = "UpdateUsername")]
    UpdateUsername {
        username: String,
        rsp: oneshot::Sender<Result<Identity, warp::error::Error>>,
    },
    #[display(fmt = "GetIdentity")]
    GetIdentity {
        did: DID,
        rsp: oneshot::Sender<Result<Identity, warp::error::Error>>,
    },
    #[display(fmt = "SetStatus")]
    SetStatus {
        status: IdentityStatus,
        rsp: oneshot::Sender<Result<Identity, warp::error::Error>>,
    },
    //#[display(fmt = "GetIdentities")]
    //GetIdentities {
    //    dids: Vec<DID>,
    //    rsp: oneshot::Sender<Result<HashMap<DID, state::Identity>, warp::error::Error>>,
    //},
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
        MultiPassCmd::CreateIdentity { .. }
        | MultiPassCmd::TryLogIn { .. }
        | MultiPassCmd::RecoverIdentity { .. } => {
            // do nothing and drop the rsp channel
        }
        MultiPassCmd::RequestFriend {
            id,
            outgoing_requests,
            rsp,
        } => {
            // First attempt using a did
            let did = match DID::from_str(id.as_str()) {
                Ok(did) => did,
                Err(_) => {
                    // Invalid attempt of using a did key
                    if id.starts_with("did:key") {
                        log::error!("could not get did from str: {}", id);
                        let _ = rsp.send(Result::Err(Error::IdentityInvalid));
                        return;
                    }
                    // Check that input matches username search syntax of Username#<short id>
                    let split_data = id.split('#').collect::<Vec<&str>>();
                    if split_data.len() != 2
                        || split_data[1].chars().count() < 4 // Username constraints
                        || split_data[1].chars().count() > 32
                        || split_data[1].len() != identity::SHORT_ID_SIZE
                    {
                        log::error!("invalid username input: {}", id);
                        let _ = rsp.send(Result::Err(Error::IdentityInvalid));
                        return;
                    }
                    match warp.multipass.get_identity(Identifier::Username(id)).await {
                        Ok(id) => {
                            // It should only find 1 matching identity
                            if id.len() != 1 {
                                let _ = rsp.send(Result::Err(Error::IdentityInvalid));
                                return;
                            }
                            id[0].did_key()
                        }
                        Err(err) => {
                            let _ = rsp.send(Result::Err(err));
                            return;
                        }
                    }
                }
            };
            // If request already exist return
            if outgoing_requests
                .into_iter()
                .any(|id| id.did_key().eq(&did))
            {
                let _ = rsp.send(Result::Err(Error::FriendRequestExist));
                return;
            }
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
        MultiPassCmd::GetProfilePicture { did, rsp } => {
            let pfp = warp
                .multipass
                .identity_picture(&did)
                .await
                .map(|img| identity_image_to_base64(&img));
            let _ = rsp.send(pfp);
        }
        MultiPassCmd::GetProfileBanner { did, rsp } => {
            let pfb = warp
                .multipass
                .identity_banner(&did)
                .await
                .map(|img| identity_image_to_base64(&img));
            let _ = rsp.send(pfb);
        }
        MultiPassCmd::ClearProfilePicture { rsp } => {
            let _ = match warp
                .multipass
                .update_identity(IdentityUpdate::ClearPicture)
                .await
            {
                Ok(_) => {
                    let mut id = match warp.multipass.get_own_identity().await.map(Identity::from) {
                        Ok(id) => id,
                        Err(e) => {
                            let _ = rsp.send(Err(e));
                            return;
                        }
                    };
                    update_identity(&mut id, warp).await;
                    rsp.send(Ok(id))
                }
                Err(e) => {
                    log::error!("failed to update profile picture: {e}");
                    rsp.send(Err(e))
                }
            };
        }
        MultiPassCmd::UpdateProfilePicture { pfp, rsp } => {
            // note: for some reason updating a profile picture would cause your status (locally) to be lost.
            // idk why this happened but this code will get the current identity, update it, and return it
            // without attempting to fetch the "updated" identity from warp.
            let _ = match warp.multipass.get_own_identity().await.map(Identity::from) {
                Ok(my_id) => match warp
                    .multipass
                    .update_identity(IdentityUpdate::Picture(pfp.clone()))
                    .await
                {
                    Ok(_) => {
                        let mut id = my_id.clone();
                        update_identity(&mut id, warp).await;
                        rsp.send(Ok(id))
                    }
                    Err(e) => {
                        log::error!("failed to get own identity: {e}");
                        rsp.send(Err(e))
                    }
                },
                Err(e) => {
                    log::error!("failed to update profile picture: {e}");
                    rsp.send(Err(e))
                }
            };
        }
        MultiPassCmd::UpdateBanner { banner, rsp } => {
            let r = warp
                .multipass
                .update_identity(IdentityUpdate::Banner(banner))
                .await;
            let _ = match r {
                Ok(_) => {
                    let mut id = match warp.multipass.get_own_identity().await.map(Identity::from) {
                        Ok(id) => id,
                        Err(e) => {
                            let _ = rsp.send(Err(e));
                            return;
                        }
                    };
                    update_identity(&mut id, warp).await;
                    rsp.send(Ok(id))
                }
                Err(e) => {
                    log::error!("failed to update banner: {e}");
                    rsp.send(Err(e))
                }
            };
        }
        MultiPassCmd::ClearBanner { rsp } => {
            let r = warp
                .multipass
                .update_identity(IdentityUpdate::ClearBanner)
                .await;
            let _ = match r {
                Ok(_) => {
                    let mut id = match warp.multipass.get_own_identity().await.map(Identity::from) {
                        Ok(id) => id,
                        Err(e) => {
                            let _ = rsp.send(Err(e));
                            return;
                        }
                    };
                    update_identity(&mut id, warp).await;
                    rsp.send(Ok(id))
                }
                Err(e) => {
                    log::error!("failed to update banner: {e}");
                    rsp.send(Err(e))
                }
            };
        }
        MultiPassCmd::UpdateStatusMessage { status, rsp } => {
            let r = warp
                .multipass
                .update_identity(IdentityUpdate::StatusMessage(status))
                .await;
            let mut id = match warp.multipass.get_own_identity().await.map(Identity::from) {
                Ok(id) => id,
                Err(e) => {
                    let _ = rsp.send(Err(e));
                    return;
                }
            };
            update_identity(&mut id, warp).await;
            let _ = match r {
                Ok(_) => rsp.send(Ok(id)),
                Err(e) => {
                    log::error!("failed to update status: {e}");
                    rsp.send(Err(e))
                }
            };
        }
        MultiPassCmd::UpdateUsername { username, rsp } => {
            let r = warp
                .multipass
                .update_identity(IdentityUpdate::Username(username))
                .await;
            let mut id = match warp.multipass.get_own_identity().await.map(Identity::from) {
                Ok(id) => id,
                Err(e) => {
                    let _ = rsp.send(Err(e));
                    return;
                }
            };
            update_identity(&mut id, warp).await;
            let _ = match r {
                Ok(_) => rsp.send(Ok(id)),
                Err(e) => {
                    log::error!("failed to update username: {e}");
                    rsp.send(Err(e))
                }
            };
        }
        MultiPassCmd::GetIdentity { did, rsp } => {
            let r = match warp
                .multipass
                .get_identity(Identifier::DID(did.clone()))
                .await
            {
                Ok(ids) => {
                    if ids.is_empty() {
                        Err(Error::IdentityDoesntExist)
                    } else {
                        let mut id = Identity::from(ids[0].clone());
                        update_identity(&mut id, warp).await;
                        Ok(id)
                    }
                }
                Err(err) => Err(err),
            };
            let _ = rsp.send(r);
        }
        MultiPassCmd::SetStatus { status, rsp } => {
            let r = warp.multipass.set_identity_status(status).await;
            let mut id = match warp.multipass.get_own_identity().await.map(Identity::from) {
                Ok(id) => id,
                Err(e) => {
                    let _ = rsp.send(Err(e));
                    return;
                }
            };
            update_identity(&mut id, warp).await;
            let _ = match r {
                Ok(_) => rsp.send(Ok(id)),
                Err(e) => {
                    log::error!("failed to update online status: {e}");
                    rsp.send(Err(e))
                }
            };
        } //MultiPassCmd::GetIdentities { dids, rsp } => {
          //    let r = _multipass_get_identities(dids, &mut warp.multipass).await;
          //    let _ = rsp.send(r);
          //}
    }
}

async fn update_identity(id: &mut Identity, warp: &mut crate::warp_runner::manager::Warp) {
    fetch_identity_data(slice::from_ref(id));
    if let Ok(status) = warp.multipass.identity_status(&id.did_key()).await {
        id.set_identity_status(status);
    }
    if let Ok(platform) = warp.multipass.identity_platform(&id.did_key()).await {
        id.set_platform(platform);
    }
}

async fn multipass_refresh_friends(
    account: &mut Account,
) -> Result<HashMap<DID, state::Identity>, Error> {
    let ids = account.list_friends().await?;
    let identities = dids_to_identity(ids.into(), account).await?;
    let friends = HashMap::from_iter(identities.iter().map(|x| (x.did_key(), x.clone())));

    if friends.is_empty() {
        log::warn!("No identities found");
    }
    Ok(friends)
}

async fn _multipass_get_identities(
    ids: Vec<DID>,
    account: &mut Account,
) -> Result<HashMap<DID, state::Identity>, Error> {
    let identities = dids_to_identity(ids.into(), account).await?;
    let identities_hashmap =
        HashMap::from_iter(identities.iter().map(|x| (x.did_key(), x.clone())));

    if identities_hashmap.is_empty() {
        log::warn!("No identities found");
    }
    Ok(identities_hashmap)
}

pub fn identity_image_to_base64(image: &IdentityImage) -> String {
    let image_data = image.data();

    if image_data.is_empty() {
        return String::new();
    }

    let ty = image.image_type();
    let mime = match ty {
        FileType::Mime(mime) => mime.to_string(),
        FileType::Generic => "application/octet-stream".into(),
    };

    let prefix = format!("data:image/{mime};base64,");
    let base64_image = base64::encode(image_data);

    prefix + &base64_image
}
