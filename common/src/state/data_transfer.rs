use warp::constellation::Progression;

#[derive(Debug, Clone)]
pub enum TransferProgress {
    Starting,
    Progress(u8),
    Finishing,
    Cancelling,
    Error,
}

#[derive(Debug, Clone)]
pub enum TrackerType {
    FileUpload,
    FileDownload,
    ChatDownload,
}

#[derive(Debug, Clone)]
pub struct FileProgress {
    pub file: String,
    pub progress: TransferProgress,
}

#[derive(Debug, Clone, Default)]
pub struct TransferTracker {
    pub file_progress_upload: Vec<FileProgress>,
    pub file_progress_download: Vec<FileProgress>,
    pub chat_progress_download: Vec<FileProgress>,
}

impl TransferTracker {
    pub fn start_file_transfer(&mut self, file: String, tracker: TrackerType) {
        match tracker {
            TrackerType::FileUpload => self.file_progress_upload.push(FileProgress {
                file,
                progress: TransferProgress::Starting,
            }),
            TrackerType::FileDownload => self.file_progress_download.push(FileProgress {
                file,
                progress: TransferProgress::Starting,
            }),
            TrackerType::ChatDownload => self.chat_progress_download.push(FileProgress {
                file,
                progress: TransferProgress::Starting,
            }),
        }
    }

    pub fn update_file_upload(
        &mut self,
        file: &String,
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
            .find(|p| file.eq(&p.file))
        {
            f.progress = progress;
        }
    }

    pub fn cancel_file_upload(&mut self, file: &String, tracker: TrackerType) {
        if let Some(f) = self
            .get_tracker_from(tracker)
            .iter_mut()
            .find(|p| file.eq(&p.file))
        {
            f.progress = TransferProgress::Cancelling;
        }
    }

    pub fn remove_file_upload(&mut self, file: &String, tracker: TrackerType) {
        self.get_tracker_from(tracker).retain(|p| !file.eq(&p.file))
    }

    fn get_tracker_from(&mut self, tracker: TrackerType) -> &mut Vec<FileProgress> {
        match tracker {
            TrackerType::FileUpload => &mut self.file_progress_upload,
            TrackerType::FileDownload => &mut self.file_progress_download,
            TrackerType::ChatDownload => &mut self.chat_progress_download,
        }
    }

    pub fn total_progress(&self, files: bool) -> i8 {
        if files {
            let upload = self.file_progress_upload.iter().filter_map(|f| {
                if let TransferProgress::Progress(p) = f.progress {
                    Some(p as u32)
                } else {
                    None
                }
            });
            let download = self.file_progress_download.iter().filter_map(|f| {
                if let TransferProgress::Progress(p) = f.progress {
                    Some(p as u32)
                } else {
                    None
                }
            });
            let count = (upload.clone().count() + download.clone().count()) as f64 * 100.;
            let sum = (upload.sum::<u32>() + download.sum::<u32>()) as f64;
            return if count > 0. {
                ((sum / count) * 100.) as i8
            } else {
                -1
            };
        }
        let iter = self.chat_progress_download.iter().filter_map(|f| {
            if let TransferProgress::Progress(p) = f.progress {
                Some(p as u32)
            } else {
                None
            }
        });
        let count = iter.clone().count() as f64 * 100.;
        let sum = iter.sum::<u32>() as f64;
        if count > 0. {
            ((sum / count) * 100.) as i8
        } else {
            -1
        }
    }
}
