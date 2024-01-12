use std::{fs, io, path::PathBuf};

use crate::STATIC_ARGS;

pub fn clear_temp_files_directory(path_to_delete_specific_file: Option<PathBuf>) -> io::Result<()> {
    match path_to_delete_specific_file {
        Some(path) => fs::remove_file(path)?,
        None => {
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
        }
    }

    Ok(())
}
