use chrono::{DateTime, Utc};
use uuid::Uuid;

use super::ui_adapter;

#[derive(Debug)]
pub struct FetchMessagesResponse {
    pub messages: Vec<ui_adapter::Message>,
    pub has_more: bool,
    pub most_recent: Option<Uuid>,
}

pub enum FetchMessagesConfig {
    MostRecent {
        limit: usize,
    },
    // fetch messages which occur earlier in time
    Earlier {
        start_date: DateTime<Utc>,
        limit: usize,
    },
    // fetch messages which occur later in time
    Later {
        start_date: DateTime<Utc>,
        limit: usize,
    },
    // fetch half_size messages before and after center.
    Window {
        center: DateTime<Utc>,
        half_size: usize,
    },
}

impl FetchMessagesConfig {
    pub fn get_limit(&self) -> usize {
        match self {
            Self::Earlier { limit, .. }
            | Self::Later { limit, .. }
            | Self::MostRecent { limit } => *limit,
            Self::Window { half_size, .. } => *half_size,
        }
    }
}
