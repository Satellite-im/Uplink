use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub enum ScrollTo {
    // start at the most recent message and automatically update the view when messages are received
    MostRecent,
    // the user scrolled up. don't automatically update the view when messages are received
    ScrollUp {
        // the message id that should be at the top of the chats page
        view_top: Uuid,
    },
    ScrollDown {
        // the message id that should be at the bottom of the chats page
        view_bottom: Uuid,
    },
}

impl Default for ScrollTo {
    fn default() -> Self {
        Self::MostRecent
    }
}
