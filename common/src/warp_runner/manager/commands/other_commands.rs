use std::path::PathBuf;

use derive_more::Display;
#[derive(Display)]
pub enum OtherCmd {
    #[display(fmt = "CompressFolder {{ src: {src:?}, dest: {dest:?} }} ")]
    CompressFolder { src: PathBuf, dest: PathBuf },
}
