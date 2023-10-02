mod chat_data;
mod chat_props;
mod js_msg;
mod misc;
mod msg_group;

pub use chat_data::*;
pub use chat_props::*;
pub use js_msg::*;
pub use misc::*;
pub use msg_group::*;

pub const DEFAULT_MESSAGES_TO_TAKE: usize = 40;
