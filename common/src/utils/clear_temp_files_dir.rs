use std::{fs, io};
use tracing::log;

use crate::STATIC_ARGS;

pub fn clear_temp_files_directory() -> io::Result<()> {
    let temp_files_dir = fs::read_dir(STATIC_ARGS.temp_files.clone())?;
    for entry in temp_files_dir {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            fs::remove_dir_all(&path)?;
        } else {
            fs::remove_file(&path)?;
        }
    }
    log::debug!("Temporary files directory cleared");
    Ok(())
}
