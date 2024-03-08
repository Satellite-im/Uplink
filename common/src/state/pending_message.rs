use std::{collections::HashMap, ffi::OsStr, path::PathBuf};

use uuid::Uuid;
use warp::{constellation::Progression, crypto::DID, raygun::Location};

use crate::warp_runner::ui_adapter::Message;
// We can improve message equality detection if warp e.g. can send us their assigned uuid.
// Else it is just a guesswork
#[derive(Clone, Debug)]
pub struct PendingMessage {
    attachments: Vec<String>,
    pub attachments_progress: HashMap<String, FileProgression>,
    pub message: Message,
}

impl PendingMessage {
    // Use this for comparison cases
    pub fn for_compare(text: Vec<String>, attachments: &[Location], id: Option<Uuid>) -> Self {
        let mut inner = warp::raygun::Message::default();
        if let Some(m_id) = id {
            inner.set_id(m_id);
        }
        inner.set_lines(text);
        let message = Message::new(inner, None, Uuid::new_v4().to_string());
        PendingMessage {
            attachments: attachments
                .iter()
                .filter_map(|p| {
                    let path = match p {
                        Location::Disk { path } => path.clone(),
                        Location::Constellation { path } => PathBuf::from(path),
                    };

                    path.file_name().and_then(OsStr::to_str).map(str::to_string)
                })
                .collect::<Vec<_>>(),
            attachments_progress: HashMap::new(),
            message,
        }
    }

    pub fn new(chat_id: Uuid, did: DID, text: Vec<String>, attachments: &[Location]) -> Self {
        // Create a dummy message
        let mut inner = warp::raygun::Message::default();
        inner.set_id(Uuid::new_v4());
        inner.set_sender(did);
        inner.set_conversation_id(chat_id);
        inner.set_lines(text);
        let attachments = attachments
            .iter()
            .filter(|location| match location {
                Location::Disk { path } => path.is_file(),
                Location::Constellation { .. } => true,
            })
            .cloned()
            .collect::<Vec<_>>();

        let message = Message::new(inner, None, Uuid::new_v4().to_string());
        PendingMessage {
            attachments: attachments
                .iter()
                .map(|p| {
                    let pathbuf = match p {
                        Location::Disk { path } => path.clone(),
                        Location::Constellation { path } => PathBuf::from(path),
                    };
                    pathbuf
                        .file_name()
                        .map_or_else(String::new, |ostr| ostr.to_string_lossy().to_string())
                })
                .collect(),
            attachments_progress: HashMap::new(),
            message,
        }
    }

    // UI side id. Messages arriving at warp have a different id!
    // This is only for messages that have not been sent to warp yet
    pub fn id(&self) -> Uuid {
        self.message.inner.id()
    }
}

impl PartialEq for PendingMessage {
    fn eq(&self, other: &Self) -> bool {
        self.message.inner.lines().eq(&other.message.inner.lines())
            && self
                .attachments
                .iter()
                .all(|k| other.attachments.contains(k))
            && self.id().eq(&other.id())
    }
}

impl Eq for PendingMessage {}

#[derive(Debug, Clone)]
pub enum FileProgression {
    CurrentProgress {
        /// name of the file
        name: String,

        /// size of the progression
        current: usize,

        /// total size of the file, if any is supplied
        total: Option<usize>,
    },
    ProgressComplete {
        /// name of the file
        name: String,

        /// total size of the file, if any is supplied
        total: Option<usize>,
    },
    ProgressFailed {
        /// name of the file that failed
        name: String,

        /// last known size, if any, of where it failed
        last_size: Option<usize>,

        /// error of why it failed, if any
        error: std::sync::Arc<warp::error::Error>,
    },
}

impl From<Progression> for FileProgression {
    fn from(progress: Progression) -> Self {
        match progress {
            Progression::CurrentProgress {
                name,
                current,
                total,
            } => FileProgression::CurrentProgress {
                name,
                current,
                total,
            },
            Progression::ProgressComplete { name, total } => {
                FileProgression::ProgressComplete { name, total }
            }
            Progression::ProgressFailed {
                name,
                last_size,
                error,
            } => FileProgression::ProgressFailed {
                name,
                last_size,
                error: std::sync::Arc::new(error),
            },
        }
    }
}

pub fn progress_file(progress: &FileProgression) -> String {
    match progress {
        FileProgression::CurrentProgress {
            name,
            current: _,
            total: _,
        } => name.clone(),
        FileProgression::ProgressComplete { name, total: _ } => name.clone(),
        FileProgression::ProgressFailed {
            name,
            last_size: _,
            error: _,
        } => name.clone(),
    }
}
