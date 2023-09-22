use serde::{Deserialize, Serialize};

use super::{MessageIndices, ScrollBehavior, ViewBehavior};

// for a given Chat, the UI will load X messages, Y of which are displayed at any given time. Scrolling changes the set of messages displayed.
// naming this is tough. to start, the X messages loaded will be called a "view". the messages displayed will be called "page". See ViewBehavior::Historical
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct ChatBehavior {
    // the view behaves differently if the user scrolled up to look at old messages.
    pub view_behavior: ViewBehavior,
    // describes how to behave when the user scrolls to the top of the view
    pub on_scroll_top: ScrollBehavior,
    // describes how to behave when the user scrolls to the end of the view
    pub on_scroll_end: ScrollBehavior,
    pub messages_indices: Option<MessageIndices>,
}

impl ChatBehavior {
    pub fn new(
        view_behavior: ViewBehavior,
        on_scroll_top: ScrollBehavior,
        on_scroll_end: ScrollBehavior,
    ) -> Self {
        Self {
            view_behavior,
            on_scroll_end,
            on_scroll_top,
            messages_indices: None,
        }
    }

    pub fn set_view_behavior(&mut self, behavior: ViewBehavior) {
        self.view_behavior = behavior;
    }

    pub fn set_scroll_top_behavior(&mut self, behavior: ScrollBehavior) {
        self.on_scroll_top = behavior;
    }

    pub fn set_scroll_end_behavior(&mut self, behavior: ScrollBehavior) {
        self.on_scroll_end = behavior;
    }

    pub fn increment_end_idx(&mut self) {
        if let Some(idxs) = self.messages_indices.as_mut() {
            idxs.end += 1;
        }
    }
}

impl Default for ChatBehavior {
    fn default() -> Self {
        Self {
            view_behavior: ViewBehavior::default(),
            on_scroll_top: ScrollBehavior::FetchMore,
            on_scroll_end: ScrollBehavior::DoNothing,
            messages_indices: None,
        }
    }
}
