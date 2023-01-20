use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use warp::crypto::DID;

use super::identity::Identity;
// TODO: Properly wrap data which is expected to persist remotely in options, so we can know if we're still figuring out what exists "remotely", i.e. loading.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Friends {
    // becomes true when the friends fields have been retrieved from Warp
    #[serde(skip)]
    pub initialized: bool,
    // All active friends.
    #[serde(skip)]
    pub all: HashMap<DID, Identity>,
    // List of friends the user has blocked
    #[serde(skip)]
    pub blocked: HashSet<Identity>,
    // Friend requests, incoming and outgoing.
    #[serde(skip)]
    pub incoming_requests: HashSet<Identity>,
    #[serde(skip)]
    pub outgoing_requests: HashSet<Identity>,
}

impl Friends {
    pub fn join(&mut self, other: &mut Friends) {
        for (k, v) in other.all.drain() {
            self.all.insert(k, v);
        }

        for v in other.blocked.drain() {
            self.blocked.insert(v);
        }

        for v in other.incoming_requests.drain() {
            self.incoming_requests.insert(v);
        }

        for v in other.outgoing_requests.drain() {
            self.outgoing_requests.insert(v);
        }
    }
}
