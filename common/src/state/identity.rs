use serde::{Deserialize, Serialize};
use std::hash::Hash;
use warp::multipass::{
    self,
    identity::{Identity as WarpIdentity, IdentityStatus, Platform},
};
#[derive(Serialize, Deserialize, Debug, Clone, Eq)]
pub struct Identity {
    identity: WarpIdentity,
    status: IdentityStatus,
    platform: Platform,
}

impl Hash for Identity {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.identity.hash(state)
    }
}

impl PartialEq for Identity {
    fn eq(&self, other: &Self) -> bool {
        self.identity.eq(&other.identity)
            && self.status.eq(&other.status)
            && self.platform.eq(&other.platform)
    }
}

impl Default for Identity {
    fn default() -> Self {
        Self::from(WarpIdentity::default())
    }
}

impl From<WarpIdentity> for Identity {
    fn from(identity: WarpIdentity) -> Self {
        Identity {
            identity,
            status: IdentityStatus::Offline,
            platform: Default::default(),
        }
    }
}

impl core::ops::Deref for Identity {
    type Target = WarpIdentity;
    fn deref(&self) -> &Self::Target {
        &self.identity
    }
}

impl core::ops::DerefMut for Identity {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.identity
    }
}

impl Identity {
    pub fn new(identity: WarpIdentity, status: IdentityStatus, platform: Platform) -> Self {
        Self {
            identity,
            status,
            platform,
        }
    }
    pub fn identity_status(&self) -> IdentityStatus {
        self.status
    }

    pub fn platform(&self) -> Platform {
        self.platform
    }
}

impl Identity {
    pub fn set_identity_status(&mut self, status: IdentityStatus) {
        self.status = status;
    }

    pub fn set_platform(&mut self, platform: Platform) {
        self.platform = platform;
    }

    pub fn set_warp_identity(&mut self, ident: multipass::identity::Identity) {
        self.identity = ident;
    }
}
