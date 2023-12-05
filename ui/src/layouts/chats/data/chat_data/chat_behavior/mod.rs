use common::warp_runner::FetchMessagesConfig;
use serde::{Deserialize, Serialize};

mod scroll_behavior;
mod scroll_to;
mod view_init;
pub use scroll_behavior::*;
pub use scroll_to::*;
pub use view_init::*;

// for a given Chat, the UI will load X messages, Y of which are displayed at any given time. Scrolling changes the set of messages displayed.
// naming this is tough. to start, the X messages loaded will be called a "view". the messages displayed will be called "page". See ViewBehavior::Historical
#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct ChatBehavior {
    // the view behaves differently if the user scrolled up to look at old messages.
    pub view_init: ViewInit,
    // describes how to behave when the user scrolls to the top of the view
    pub on_scroll_top: ScrollBehavior,
    // describes how to behave when the user scrolls to the end of the view
    pub on_scroll_end: ScrollBehavior,

    // if a message is received when the user scrolls up but before they have
    // fetched more messages, need to fetch the message when they scroll back down.
    // but the javascript will have been configured to not trigger on "bottom reached"
    // and reloading everything somehow results in the scroll button staying on the page while
    // everything, including the new message, is rendered. gonna try using this in the onscroll
    // event to trigger a reload.
    pub override_on_scroll_end: bool,
}

impl ChatBehavior {
    pub fn messages_config(&self) -> FetchMessagesConfig {
        match self.view_init.scroll_to {
            ScrollTo::MostRecent => FetchMessagesConfig::MostRecent {
                limit: self.view_init.limit,
            },
            _ => FetchMessagesConfig::Window {
                center: self
                    .view_init
                    .msg_time
                    .unwrap_or(chrono::offset::Utc::now()),
                half_size: self.view_init.limit / 2,
            },
        }
    }

    // pub fn set_view_init(&mut self, init: ViewInit) {
    //     self.view_init = init;
    // }
    //
    // pub fn set_scroll_top_behavior(&mut self, behavior: ScrollBehavior) {
    //     self.on_scroll_top = behavior;
    // }
    //
    // pub fn set_scroll_end_behavior(&mut self, behavior: ScrollBehavior) {
    //     self.on_scroll_end = behavior;
    // }
}

impl Default for ChatBehavior {
    fn default() -> Self {
        Self {
            view_init: ViewInit::default(),
            on_scroll_top: ScrollBehavior::FetchMore,
            on_scroll_end: ScrollBehavior::DoNothing,
            override_on_scroll_end: false,
        }
    }
}
