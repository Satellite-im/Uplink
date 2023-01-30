use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use warp::{constellation::directory::Directory, constellation::file::File};

// TODO: Properly wrap data which is expected to persist remotely in options, so we can know if we're still figuring out what exists "remotely", i.e. loading.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Items {
    // becomes true when the items fields have been retrieved from Warp
    #[serde(skip)]
    pub initialized: bool,
    // All items in the current directory.
    #[serde(skip)]
    pub all: Vec<warp::constellation::item::Item>,
    // List of directories inside current directory
    #[serde(skip)]
    pub directories: HashSet<Directory>,
    // List of files inside current directory
    #[serde(skip)]
    pub files: HashSet<File>,
}

impl Items {
    pub fn join(&mut self, other: Items) {
        for k in other.all {
            self.all.push(k);
        }
    }
}
