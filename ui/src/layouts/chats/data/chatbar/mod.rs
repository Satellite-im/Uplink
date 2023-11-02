pub type ChatInput = (Vec<String>, Uuid, Option<Uuid>, Option<Uuid>);

mod typing_indicator;
mod typing_info;

pub use typing_indicator::*;
pub use typing_info::*;
use uuid::Uuid;
