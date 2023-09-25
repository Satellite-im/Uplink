use chrono::{DateTime, Utc};

use super::ui_adapter;

#[derive(Debug)]
pub struct FetchMessagesResponse {
    pub messages: Vec<ui_adapter::Message>,
    pub has_more: bool,
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
}

impl FetchMessagesConfig {
    pub fn get_limit(&self) -> usize {
        match self {
            Self::Earlier { limit, .. }
            | Self::Later { limit, .. }
            | Self::MostRecent { limit } => *limit,
        }
    }
}
