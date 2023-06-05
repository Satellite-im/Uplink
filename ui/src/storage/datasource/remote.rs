pub struct StorageRemoteDataSource {
    warp_cmd_tx: Sender<WarpCmd>,
}

impl StorageRemoteDataSource {
    pub fn new(warp_cmd_tx: Sender<WarpCmd>) -> Self {
        Self { warp_cmd_tx }
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
                warp::error::Error::new(e)
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
}
