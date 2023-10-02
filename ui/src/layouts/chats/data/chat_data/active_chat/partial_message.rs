use std::cmp::Ordering;

use chrono::{DateTime, Utc};
use common::warp_runner::ui_adapter;
use uuid::Uuid;
use warp::raygun;

#[derive(Clone, Debug, Default, Eq)]
pub struct PartialMessage {
    pub message_id: Uuid,
    /// Timestamp of the message
    pub date: DateTime<Utc>,
}
impl std::cmp::PartialOrd for PartialMessage {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        if self.message_id == other.message_id {
            return Some(Ordering::Equal);
        }
        Some(self.date.cmp(&other.date))
    }
}

impl std::cmp::PartialEq for PartialMessage {
    fn eq(&self, other: &Self) -> bool {
        self.message_id == other.message_id
    }
}

impl From<ui_adapter::Message> for PartialMessage {
    fn from(value: ui_adapter::Message) -> Self {
        value.inner.into()
    }
}

impl From<raygun::Message> for PartialMessage {
    fn from(value: raygun::Message) -> Self {
        Self {
            message_id: value.id(),
            date: value.date(),
        }
    }
}
