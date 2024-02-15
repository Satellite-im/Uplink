use std::sync::Arc;

use tokio::sync::Mutex;
use uuid::Uuid;
use warp::constellation::Progression;

use crate::language::get_local_text;

// Struct to ease updating/reading from it
#[derive(Debug, Clone, Default)]
pub struct TransferState {
    inner: Arc<Mutex<TransferStates>>,
}

impl TransferState {
    pub fn new() -> TransferState {
        TransferState {
            inner: Arc::new(Mutex::new(TransferStates::default())),
        }
    }

    pub async fn matches(&self, state: TransferStates) -> bool {
        *self.inner.lock().await == state
    }

    pub async fn update(&self, cancel: bool) {
        let mut v = self.inner.lock().await;
        *v = v.swap(cancel);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransferProgress {
    Starting,
    Progress(u8),
    Finishing,
    Paused(u8),
    Cancelling,
    Error,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum TransferStates {
    #[default]
    Normal,
    Cancel,
    Pause,
}

impl TransferStates {
    pub fn swap(&self, cancel: bool) -> TransferStates {
        match self {
            TransferStates::Normal => {
                if cancel {
                    TransferStates::Cancel
                } else {
                    TransferStates::Pause
                }
            }
            TransferStates::Cancel => TransferStates::Cancel,
            TransferStates::Pause => {
                if cancel {
                    TransferStates::Cancel
                } else {
                    TransferStates::Normal
                }
            }
        }
    }
}

unsafe impl Send for TransferStates {}

#[derive(Debug, Clone)]
pub enum TrackerType {
    FileUpload,
    FileDownload,
}

#[derive(Debug, Clone)]
pub struct FileProgress {
    // Use an uuid for duplicate file names
    pub id: Uuid,
    pub file: String,
    pub progress: TransferProgress,
    pub description: Option<String>,
    // Flag used to pause or cancel this transfer
    pub state: TransferState,
}

impl PartialEq for FileProgress {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
            && self.file == other.file
            && self.progress == other.progress
            && self.description == other.description
    }
}

#[derive(Debug, Clone, Default)]
pub struct TransferTracker {
    pub file_progress_upload: Vec<FileProgress>,
    pub file_progress_download: Vec<FileProgress>,
}

impl TransferTracker {
    pub fn start_file_transfer(
        &mut self,
        id: Uuid,
        file: String,
        state: TransferState,
        tracker: TrackerType,
    ) {
        match tracker {
            TrackerType::FileUpload => self.file_progress_upload.push(FileProgress {
                id,
                file,
                progress: TransferProgress::Starting,
                description: None,
                state,
            }),
            TrackerType::FileDownload => self.file_progress_download.push(FileProgress {
                id,
                file,
                progress: TransferProgress::Starting,
                description: None,
                state,
            }),
        }
    }

    pub fn update_file_upload(
        &mut self,
        file_id: &Uuid,
        progression: Progression,
        tracker: TrackerType,
    ) {
        let progress = match progression {
            Progression::CurrentProgress {
                name: _,
                current,
                total,
            } => TransferProgress::Progress(
                total
                    .map(|total| current as f64 / total as f64 * 100.)
                    .unwrap_or_default() as u8,
            ),
            Progression::ProgressComplete { name: _, total: _ } => TransferProgress::Finishing,
            Progression::ProgressFailed {
                name: _,
                last_size: _,
                error: _,
            } => TransferProgress::Error,
        };
        if let Some(f) = self
            .get_tracker_from(tracker)
            .iter_mut()
            .find(|p| file_id.eq(&p.id))
        {
            f.progress = progress;
        }
    }

    pub fn update_file_description(
        &mut self,
        file_id: &Uuid,
        description: String,
        tracker: TrackerType,
    ) {
        if let Some(f) = self
            .get_tracker_from(tracker)
            .iter_mut()
            .find(|p| file_id.eq(&p.id))
        {
            f.description = Some(description);
        }
    }

    pub fn pause_file_upload(&mut self, file_id: &Uuid, tracker: TrackerType) {
        if let Some(f) = self
            .get_tracker_from(tracker)
            .iter_mut()
            .find(|p| file_id.eq(&p.id))
        {
            let current = if let TransferProgress::Progress(p) = f.progress {
                p
            } else {
                0
            };
            f.progress = TransferProgress::Paused(current);
        }
    }

    pub fn cancel_file_upload(&mut self, file_id: &Uuid, tracker: TrackerType) {
        if let Some(f) = self
            .get_tracker_from(tracker)
            .iter_mut()
            .find(|p| file_id.eq(&p.id))
        {
            f.progress = TransferProgress::Cancelling;
        }
    }

    pub fn error_file_upload(&mut self, file_id: &Uuid, tracker: TrackerType) {
        if let Some(f) = self
            .get_tracker_from(tracker)
            .iter_mut()
            .find(|p| file_id.eq(&p.id))
        {
            f.progress = TransferProgress::Error;
            f.description = Some(get_local_text("files.error-to-upload"));
        }
    }

    pub fn remove_file_upload(&mut self, file_id: &Uuid, tracker: TrackerType) {
        self.get_tracker_from(tracker)
            .retain(|p| !file_id.eq(&p.id))
    }

    fn get_tracker_from(&mut self, tracker: TrackerType) -> &mut Vec<FileProgress> {
        match tracker {
            TrackerType::FileUpload => &mut self.file_progress_upload,
            TrackerType::FileDownload => &mut self.file_progress_download,
        }
    }

    pub fn get_tracker(&self, upload: bool) -> &Vec<FileProgress> {
        if upload {
            &self.file_progress_upload
        } else {
            &self.file_progress_download
        }
    }

    pub fn total_progress(&self) -> i8 {
        let upload = self
            .file_progress_upload
            .iter()
            .filter_map(|f| match f.progress {
                TransferProgress::Progress(p) | TransferProgress::Paused(p) => Some(p as u32),
                _ => None,
            });
        let download = self
            .file_progress_download
            .iter()
            .filter_map(|f| match f.progress {
                TransferProgress::Progress(p) | TransferProgress::Paused(p) => Some(p as u32),
                _ => None,
            });
        let count = (upload.clone().count() + download.clone().count()) as f64 * 100.;
        let sum = (upload.sum::<u32>() + download.sum::<u32>()) as f64;
        if count > 0. {
            ((sum / count) * 100.) as i8
        } else {
            -1
        }
    }
}
