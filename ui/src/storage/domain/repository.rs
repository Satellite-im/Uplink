pub struct StorageRepository {
    storageRemoteDataSource: StorageRemoteDataSource,
}

impl StorageRepository {
    pub fn new(storageRemoteDataSource: StorageRemoteDataSource) -> Self {
        Self {
            storageRemoteDataSource,
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
}
