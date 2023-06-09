use std::path::PathBuf;

use common::{
    state::storage::Storage,
    warp_runner::{ConstellationCmd, FileTransferProgress, WarpCmd},
    WARP_CMD_CH,
};
use futures::channel::oneshot;
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use warp::constellation::{directory::Directory, item::Item};

#[derive(Clone)]
pub struct StorageRemoteDataSource {
    warp_cmd_cmd: UnboundedSender<WarpCmd>,
}

impl StorageRemoteDataSource {
    pub fn new() -> Self {
        Self {
            warp_cmd_cmd: WARP_CMD_CH.tx.clone(),
        }
    }

    pub async fn create_new_directory(
        &self,
        directory_name: String,
    ) -> Result<(), warp::error::Error> {
        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
        let directory_name2 = directory_name.clone();

        self.warp_cmd_cmd
            .send(WarpCmd::Constellation(
                ConstellationCmd::CreateNewDirectory {
                    directory_name,
                    rsp: tx,
                },
            ))
            .map_err(|e| {
                log::error!("Failed to use send channel on send command: {}", e);
                warp::error::Error::SenderChannelUnavailable
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

        self.warp_cmd_cmd
            .send(WarpCmd::Constellation(
                ConstellationCmd::GetItemsFromCurrentDirectory { rsp: tx },
            ))
            .map_err(|e| {
                log::error!(
                    "Failed to use send channel on get items from current directory: {}",
                    e
                );
                warp::error::Error::SenderChannelUnavailable
            })?;

        let rsp = rx.await.expect("command canceled");

        rsp.map_err(|e| {
            log::error!("Failed to get items from current directory: {}", e);
            e
        })
    }

    pub async fn open_directory(
        &self,
        directory_name: String,
    ) -> Result<Storage, warp::error::Error> {
        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();

        self.warp_cmd_cmd
            .send(WarpCmd::Constellation(ConstellationCmd::OpenDirectory {
                directory_name: directory_name.clone(),
                rsp: tx,
            }))
            .map_err(|e| {
                log::error!(
                    "Failed to use send channel on open {} directory: {}",
                    directory_name,
                    e
                );
                warp::error::Error::SenderChannelUnavailable
            })?;

        let rsp = rx.await.expect("command canceled");

        rsp.map_err(|e| {
            log::error!("failed to open folder {}: {}", directory_name, e);
            e
        })
    }

    pub async fn back_to_previous_directory(
        &self,
        directory: Directory,
    ) -> Result<Storage, warp::error::Error> {
        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();
        let directory_name = directory.name();

        self.warp_cmd_cmd
            .send(WarpCmd::Constellation(
                ConstellationCmd::BackToPreviousDirectory { directory, rsp: tx },
            ))
            .map_err(|e| {
                log::error!(
                    "Failed to use send channel on back to previous directory {}: {}",
                    directory_name,
                    e
                );
                warp::error::Error::SenderChannelUnavailable
            })?;

        let rsp = rx.await.expect("command canceled");

        rsp.map_err(|e| {
            log::error!(
                "Failed to back to previous directory {}: {}",
                directory_name,
                e
            );
            e
        })
    }

    pub async fn download_file(
        &self,
        file_name: String,
        local_path_to_save_file: PathBuf,
    ) -> Result<(), warp::error::Error> {
        let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();

        self.warp_cmd_cmd
            .send(WarpCmd::Constellation(ConstellationCmd::DownloadFile {
                file_name: file_name.clone(),
                local_path_to_save_file,
                rsp: tx,
            }))
            .map_err(|e| {
                log::error!(
                    "Failed to use send channel on download file {}: {}",
                    file_name,
                    e
                );
                warp::error::Error::SenderChannelUnavailable
            })?;

        let rsp = rx.await.expect("command canceled");

        rsp.map_err(|e| {
            log::error!("Failed to download file {}: {}", file_name, e);
            e
        })
    }

    pub async fn delete_items(&self, item: Item) -> Result<Storage, warp::error::Error> {
        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();
        let item_name = item.name();
        self.warp_cmd_cmd
            .send(WarpCmd::Constellation(ConstellationCmd::DeleteItems {
                item,
                rsp: tx,
            }))
            .map_err(|e| {
                log::error!(
                    "Failed to use send channel on delete item {}: {}",
                    item_name,
                    e
                );
                warp::error::Error::SenderChannelUnavailable
            })?;

        let rsp = rx.await.expect("command canceled");

        rsp.map_err(|e| {
            log::error!("Failed to delete item {}: {}", item_name, e);
            e
        })
    }

    pub async fn get_storage_size(&self) -> Result<(usize, usize), warp::error::Error> {
        let (tx, rx) = oneshot::channel::<Result<(usize, usize), warp::error::Error>>();

        self.warp_cmd_cmd
            .send(WarpCmd::Constellation(ConstellationCmd::GetStorageSize {
                rsp: tx,
            }))
            .map_err(|e| {
                log::error!("Failed to use send channel on get storage size: {}", e);
                warp::error::Error::SenderChannelUnavailable
            })?;

        let rsp = rx.await.expect("command canceled");

        rsp.map_err(|e| {
            log::error!("Failed to get storage size: {}", e);
            e
        })
    }

    pub async fn rename_item(
        &self,
        old_name: String,
        new_name: String,
    ) -> Result<Storage, warp::error::Error> {
        let (tx, rx) = oneshot::channel::<Result<Storage, warp::error::Error>>();
        let old_name_clone = old_name.clone();
        self.warp_cmd_cmd
            .send(WarpCmd::Constellation(ConstellationCmd::RenameItem {
                old_name,
                new_name,
                rsp: tx,
            }))
            .map_err(|e| {
                log::error!(
                    "Failed to use send channel on rename item {}: {}",
                    old_name_clone,
                    e
                );
                warp::error::Error::SenderChannelUnavailable
            })?;

        let rsp = rx.await.expect("command canceled");

        rsp.map_err(|e| {
            log::error!("Failed to rename item {}: {}", old_name_clone, e);
            e
        })
    }

    pub async fn upload_files(
        &self,
        files_path: Vec<PathBuf>,
    ) -> Result<UnboundedReceiver<FileTransferProgress<Storage>>, warp::error::Error> {
        let (tx, rx) = mpsc::unbounded_channel::<FileTransferProgress<Storage>>();

        self.warp_cmd_cmd
            .send(WarpCmd::Constellation(ConstellationCmd::UploadFiles {
                files_path,
                rsp: tx,
            }))
            .map_err(|e| {
                log::error!("Failed to use send channel on upload files: {}", e);
                warp::error::Error::SenderChannelUnavailable
            })?;
        Ok(rx)
    }
}
