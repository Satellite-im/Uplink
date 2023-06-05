use common::state::storage::Storage;

use crate::layouts::storage::datasource::remote::StorageRemoteDataSource;

#[derive(Clone)]
pub struct StorageRepository {
    storageRemoteDataSource: StorageRemoteDataSource,
}

impl StorageRepository {
    pub fn new() -> Self {
        Self {
            storageRemoteDataSource: StorageRemoteDataSource::new(),
        }
    }

    pub async fn create_new_directory(
        &self,
        directory_name: String,
    ) -> Result<(), warp::error::Error> {
        self.storageRemoteDataSource
            .create_new_directory(directory_name)
            .await
    }

    pub async fn get_items_from_current_directory(&self) -> Result<Storage, warp::error::Error> {
        self.storageRemoteDataSource
            .get_items_from_current_directory()
            .await
    }
}
