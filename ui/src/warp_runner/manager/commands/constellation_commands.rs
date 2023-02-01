use futures::channel::oneshot;

use crate::state::storage::Storage as uplink_storage;
use crate::warp_runner::Storage as warp_storage;

use warp::{error::Error, logging::tracing::log};

#[derive(Debug)]
pub enum ConstellationCmd {
    GetItemsFromCurrentDirectory {
        rsp: oneshot::Sender<Result<uplink_storage, warp::error::Error>>,
    },
    CreateNewFolder {
        folder_name: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
}

pub async fn handle_constellation_cmd(cmd: ConstellationCmd, warp_storage: &mut warp_storage) {
    match cmd {
        ConstellationCmd::GetItemsFromCurrentDirectory { rsp } => {
            let r = initialize_items(warp_storage);
            let _ = rsp.send(r);
        }
        ConstellationCmd::CreateNewFolder { folder_name, rsp } => {
            let r = create_new_directory(&folder_name, warp_storage).await;
            let _ = rsp.send(r);
        }
    }
}

async fn create_new_directory(
    folder_name: &str,
    warp_storage: &mut warp_storage,
) -> Result<(), Error> {
    let _ = warp_storage.create_directory(folder_name, true).await?;
    log::debug!("New directory created: {:?}", folder_name);
    Ok(())
}

fn initialize_items(warp_storage: &mut warp_storage) -> Result<uplink_storage, Error> {
    let current_dir = warp_storage.current_directory()?;
    let items = current_dir.get_items();

    let directories = items
        .iter()
        .filter_map(|item| item.get_directory().ok())
        .collect::<Vec<_>>();
    let files = items
        .iter()
        .filter_map(|item| item.get_file().ok())
        .collect::<Vec<_>>();

    let uplink_storage = uplink_storage {
        initialized: true,
        directories,
        files,
    };
    Ok(uplink_storage)
}
