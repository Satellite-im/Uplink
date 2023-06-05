use common::{
    state::storage::Storage,
    warp_runner::{ConstellationCmd, WarpCmd},
    WARP_CMD_CH,
};
use futures::channel::oneshot;
use tokio::sync::mpsc::UnboundedSender;

#[derive(Clone)]
pub struct StorageRemoteDataSource {
    warp_cmd_tx: UnboundedSender<WarpCmd>,
}

impl StorageRemoteDataSource {
    pub fn new() -> Self {
        Self {
            warp_cmd_tx: WARP_CMD_CH.tx.clone(),
        }
    }

    pub async fn create_new_directory(
        &self,
        directory_name: String,
    ) -> Result<(), warp::error::Error> {
        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
        let directory_name2 = directory_name.clone();

        self.warp_cmd_tx
            .send(WarpCmd::Constellation(
                ConstellationCmd::CreateNewDirectory {
                    directory_name,
                    rsp: tx,
                },
            ))
            .map_err(|e| {
                log::error!("failed to send command: {}", e);
                warp::error::Error::Other
            })?;

        let rsp = rx.await.expect("command canceled");

        match rsp {
            Ok(_) => {
                log::info!("New directory added: {}", directory_name2);
                Ok(())
            }
            Err(e) => {
                log::error!("failed to add new directory: {}", e);
                Err(e)
            }
        }
    }

    pub async fn get_items_from_current_directory(&self) -> Result<Storage, warp::error::Error> {
        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();

        if let Err(e) = self.warp_cmd_tx.send(WarpCmd::Constellation(
            ConstellationCmd::GetItemsFromCurrentDirectory { rsp: tx },
        )) {
            log::error!("failed to get items from current directory {}", e);
            return Err(warp::error::Error::InvalidFile);
        }

        let rsp = rx.await.expect("command canceled");
        match rsp {
            Ok(storage) => Ok(storage),
            Err(e) => {
                log::error!("failed to get items from current directory: {}", e);
                Err(e)
            }
        }
    }
}
