use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::layouts::chats::data::DEFAULT_MESSAGES_TO_TAKE;

use super::ScrollTo;

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct ViewInit {
    pub scroll_to: ScrollTo,
    pub msg_time: Option<DateTime<Utc>>,
    // fetch at most `limit` messages starting at `earliest_time` or now() (if it's none)
    pub limit: usize,
}

impl Default for ViewInit {
    fn default() -> Self {
        Self {
            scroll_to: ScrollTo::MostRecent,
            msg_time: None,
            limit: DEFAULT_MESSAGES_TO_TAKE,
        }
    }
}
