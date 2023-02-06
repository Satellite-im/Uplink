use derive_more::Display;
use futures::channel::oneshot;
use once_cell::sync::Lazy;

use crate::state::storage::Storage as uplink_storage;
use crate::warp_runner::Storage as warp_storage;

use warp::{
    constellation::directory::Directory, error::Error, logging::tracing::log, sync::RwLock,
};

static DIRECTORIES_AVAILABLE_TO_BROWSE: Lazy<RwLock<Vec<Directory>>> =
    Lazy::new(|| RwLock::new(Vec::new()));

#[derive(Display)]
pub enum ConstellationCmd {
    #[display(fmt = "GetItemsFromCurrentDirectory")]
    GetItemsFromCurrentDirectory {
        rsp: oneshot::Sender<Result<uplink_storage, warp::error::Error>>,
    },
    #[display(fmt = "CreateNewDirectory {{ directory_name: {directory_name} }} ")]
    CreateNewDirectory {
        directory_name: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "OpenDirectory {{ directory_name: {directory_name} }} ")]
    OpenDirectory {
        directory_name: String,
        rsp: oneshot::Sender<Result<(uplink_storage, Vec<Directory>), warp::error::Error>>,
    },
    #[display(fmt = "BackToPreviousDirectory {{ directory: {:?} }} ", directory)]
    BackToPreviousDirectory {
        directory: Directory,
        rsp: oneshot::Sender<Result<(uplink_storage, Vec<Directory>), warp::error::Error>>,
    },
}

pub async fn handle_constellation_cmd(cmd: ConstellationCmd, warp_storage: &mut warp_storage) {
    match cmd {
        ConstellationCmd::GetItemsFromCurrentDirectory { rsp } => {
            let r = get_items_from_current_directory(warp_storage);
            let _ = rsp.send(r);
        }
        ConstellationCmd::CreateNewDirectory {
            directory_name,
            rsp,
        } => {
            let r = create_new_directory(&directory_name, warp_storage).await;
            let _ = rsp.send(r);
        }
        ConstellationCmd::OpenDirectory {
            directory_name,
            rsp,
        } => {
            let r = open_new_directory(warp_storage, &directory_name);
            let _ = rsp.send(r);
        }
        ConstellationCmd::BackToPreviousDirectory { directory, rsp } => {
            let r = go_back_to_previous_directory(warp_storage, directory);
            let _ = rsp.send(r);
        }
    }
}

async fn create_new_directory(
    folder_name: &str,
    warp_storage: &mut warp_storage,
) -> Result<(), Error> {
    warp_storage.create_directory(folder_name, true).await?;
    log::debug!("New directory created: {:?}", folder_name);
    Ok(())
}

fn get_items_from_current_directory(
    warp_storage: &mut warp_storage,
) -> Result<uplink_storage, Error> {
    let current_dir = warp_storage.current_directory()?;
    let current_dirs = get_directories_opened();
    set_new_directory_opened(current_dirs.clone().as_mut(), current_dir.clone());

    let items = current_dir.get_items();

    let mut directories = items
        .iter()
        .filter_map(|item| item.get_directory().ok())
        .collect::<Vec<_>>();
    let mut files = items
        .iter()
        .filter_map(|item| item.get_file().ok())
        .collect::<Vec<_>>();

    directories.sort_by_key(|b| std::cmp::Reverse(b.modified()));
    files.sort_by_key(|b| std::cmp::Reverse(b.modified()));

    let uplink_storage = uplink_storage {
        initialized: true,
        current_dir,
        directories,
        files,
    };
    log::info!("Get items from current directory worked!");
    Ok(uplink_storage)
}

fn get_directories_opened() -> Vec<Directory> {
    DIRECTORIES_AVAILABLE_TO_BROWSE.read().clone()
}

fn set_new_directory_opened(current_dir: &mut Vec<Directory>, new_dir: Directory) {
    if !current_dir.contains(&new_dir) {
        log::debug!("Updating directories opened to browse");
        current_dir.push(new_dir);
        *DIRECTORIES_AVAILABLE_TO_BROWSE.write() = current_dir.clone()
    }
}

fn open_new_directory(
    warp_storage: &mut warp_storage,
    folder_name: &str,
) -> Result<(uplink_storage, Vec<Directory>), Error> {
    warp_storage.select(&folder_name)?;

    let new_storage = get_items_from_current_directory(warp_storage)?;
    let dirs_opened = get_directories_opened();
    log::info!("Navigation to directory {} worked!", folder_name);
    Ok((new_storage, dirs_opened))
}

fn go_back_to_previous_directory(
    warp_storage: &mut warp_storage,
    directory: Directory,
) -> Result<(uplink_storage, Vec<Directory>), Error> {
    let mut current_dirs = get_directories_opened();
    loop {
        let current_dir = match warp_storage.current_directory() {
            Ok(dir) => dir,
            Err(error) => {
                log::error!("Error on get current directory: {error}");
                return Err(error);
            }
        };
        current_dirs.remove(current_dirs.len() - 1);
        set_new_directory_opened(current_dirs.clone().as_mut(), current_dir.clone());
        if current_dir.id() == directory.id() {
            break;
        }

        if let Err(error) = warp_storage.go_back() {
            log::error!("Error on go back a directory: {error}");
            return Err(error);
        };
    }
    let new_storage = get_items_from_current_directory(warp_storage)?;
    let dirs_opened = get_directories_opened();
    log::info!("Navigation to directory {} worked!", directory.name());
    Ok((new_storage, dirs_opened))
}
