use serde::{ser::SerializeStruct, Deserialize, Serialize, Serializer};
use std::collections::HashSet;
use warp::crypto::DID;

use crate::STATIC_ARGS;

// warning: Friends implements Serialize
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Friends {
    // becomes true when the friends fields have been retrieved from Warp
    #[serde(skip)]
    pub initialized: bool,
    // All active friends.
    #[serde(default)]
    pub all: HashSet<DID>,
    // List of friends the user has blocked
    #[serde(default)]
    pub blocked: HashSet<DID>,
    // Friend requests, incoming and outgoing.
    #[serde(default)]
    pub incoming_requests: HashSet<DID>,
    #[serde(default)]
    pub outgoing_requests: HashSet<DID>,
}

// don't skip friends data when using mock data
impl Serialize for Friends {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut state = serializer.serialize_struct("Friends", 5)?;
        if STATIC_ARGS.use_mock {
            state.serialize_field("initialized", &self.initialized)?;
            state.serialize_field("all", &self.all)?;
            state.serialize_field("blocked", &self.blocked)?;
            state.serialize_field("incoming_requests", &self.incoming_requests)?;
            state.serialize_field("outgoing_requests", &self.outgoing_requests)?;
        } else {
            state.skip_field("initialized")?;
            state.skip_field("all")?;
            state.skip_field("blocked")?;
            state.skip_field("incoming_requests")?;
            state.skip_field("outgoing_requests")?;
        };

        state.end()
    }
}
