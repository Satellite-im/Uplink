use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub enum ViewBehavior {
    // start at the most recent message and automatically update the view when messages are received
    MostRecent,
    // the user scrolled up. don't automatically update the view when messages are received
    Historical {
        // id of the most recent message in the view
        view_start: Uuid,
        // the message id that should be at the top of the chats page
        page_top: Uuid,
    },
}

impl Default for ViewBehavior {
    fn default() -> Self {
        Self::MostRecent
    }
}
