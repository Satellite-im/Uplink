use serde::{Deserialize, Serialize};
use warp::{constellation::directory::Directory, constellation::file::File};

// TODO: Properly wrap data which is expected to persist remotely in options, so we can know if we're still figuring out what exists "remotely", i.e. loading.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Storage {
    // becomes true when the items fields have been retrieved from Warp
    #[serde(skip)]
    pub initialized: bool,
    // Info about current directory opened
    #[serde(skip)]
    pub current_dir: Directory,
    // All directories opened until current directory, inclusive current directory
    #[serde(skip)]
    pub directories_opened: Vec<Directory>,
    // List of directories inside current directory
    #[serde(skip)]
    pub directories: Vec<Directory>,
    // List of files inside current directory
    #[serde(skip)]
    pub files: Vec<File>,
}
