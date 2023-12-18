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
    //TODO: Use `Option<String>` in the future unless this is split away
    profile_image: String,
    profile_banner: String,
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
            profile_image: String::new(),
            profile_banner: String::new(),
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
            profile_image: String::new(),
            profile_banner: String::new(),
        }
    }
    pub fn identity_status(&self) -> IdentityStatus {
        self.status
    }

    pub fn platform(&self) -> Platform {
        self.platform
    }

    pub fn set_profile_picture(&mut self, image: &str) {
        self.profile_image = image.to_string();
    }

    pub fn set_profile_banner(&mut self, image: &str) {
        self.profile_banner = image.to_string();
    }

    pub fn profile_picture(&self) -> String {
        let picture = &self.profile_image;
        match self.contains_default_picture() {
            true => picture[..picture.len() - 3].to_string(),
            false => picture.clone(),
        }
    }

    pub fn profile_banner(&self) -> String {
        self.profile_banner.clone()
    }

    pub fn contains_default_picture(&self) -> bool {
        let picture = &self.profile_image;

        if picture.is_empty() || picture.len() < 6 {
            return false;
        }

        let bytes = picture.as_bytes();
        let length = bytes.len();

        bytes
            .get(length - 3..)
            .map(|bytes| bytes == [11, 00, 23])
            .unwrap_or_default()
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
