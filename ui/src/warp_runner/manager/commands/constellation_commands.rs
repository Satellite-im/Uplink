use futures::channel::oneshot;

use crate::warp_runner::Storage;

use warp::{error::Error, logging::tracing::log};

pub enum ConstellationCmd {
    CreateNewFolder {
        folder_name: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
}

pub async fn handle_constellation_cmd(cmd: ConstellationCmd, storage: &mut Storage) {
    match cmd {
        ConstellationCmd::CreateNewFolder { folder_name, rsp } => {
            let r = create_new_directory(&folder_name, storage).await;
            let _ = rsp.send(r);
        }
    }
}

async fn create_new_directory(folder_name: &str, storage: &mut Storage) -> Result<(), Error> {
    let _ = storage.create_directory(folder_name, true).await?;
    log::debug!("New directory created: {:?}", folder_name);
    Ok(())
}
