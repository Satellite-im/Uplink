use derive_more::Display;

use crate::warp_runner::Calling;

#[derive(Display)]
pub enum BlinkCmd {
    None,
}

pub async fn handle_blink_cmd(cmd: BlinkCmd, blink: &mut Calling) {}
