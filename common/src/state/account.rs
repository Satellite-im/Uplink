use serde::{Deserialize, Serialize};

use super::identity::Identity;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Account {
    #[serde(default)]
    pub identity: Identity,
    // pub settings: Option<CustomSettings>,
    // pub profile: Option<Profile>,
}
