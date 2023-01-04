use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use warp::crypto::DID;

use super::identity::Identity;
// TODO: Properly wrap data which is expected to persist remotely in options, so we can know if we're still figuring out what exists "remotely", i.e. loading.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Friends {
    // All active friends.
    #[serde(default)]
    pub all: HashMap<DID, Identity>,
    // List of friends the user has blocked
    #[serde(default)]
    pub blocked: Vec<Identity>,
    // Friend requests, incoming and outgoing.
    #[serde(default)]
    pub incoming_requests: Vec<Identity>,
    #[serde(default)]
    pub outgoing_requests: Vec<Identity>,
}
