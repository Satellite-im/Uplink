mod typing_indicator;
mod typing_info;

pub use typing_indicator::*;
pub use typing_info::*;
use uuid::Uuid;

pub struct MsgChInput {
    pub msg: Vec<String>,
    pub conv_id: Uuid,
    pub replying_to: Option<Uuid>,
}
