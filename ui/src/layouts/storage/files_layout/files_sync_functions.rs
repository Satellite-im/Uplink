use std::{
    fs, io,
    path::{Path, PathBuf},
};

use common::{
    state::{Action, State, ToastNotification},
    STATIC_ARGS,
};
use dioxus::events::{EvalError, UseEval};
use dioxus_hooks::{Coroutine, UseSharedState};
use once_cell::sync::Lazy;
use warp::constellation::file::File;

use crate::layouts::storage::functions::{self, ChanCmd, UseEvalFn};

use super::controller::UploadFileController;

pub static STORAGE_LOCAL_FOLDER: Lazy<PathBuf> =
    Lazy::new(|| STATIC_ARGS.uplink_path.join("storage_local_folder"));

pub fn sync_local_files<'a>(
    upload_file_controller: UploadFileController,
    state: &'a UseSharedState<State>,
    eval: &UseEvalFn,
    ch: &Coroutine<ChanCmd>,
) {
    if fs::metadata(STORAGE_LOCAL_FOLDER.clone()).is_err() {
        if let Err(e) = fs::create_dir(STORAGE_LOCAL_FOLDER.clone()) {
            log::error!("Error to create storage local folder: {:?}", e);
            return;
        }
    }
    let files_from_storage_local_folder = match list_files(
        STORAGE_LOCAL_FOLDER.to_string_lossy().to_string(),
        &mut vec![],
    ) {
        Ok(vec) => vec,
        Err(e) => {
            println!("err: {:?}", e);
            Vec::new()
        }
    };

    let files_from_current_folder_in_constellation = state.read().storage.files.clone();
    let files_from_constellation_in_root_folder: Vec<String> =
        files_from_current_folder_in_constellation
            .iter()
            .map(|file| {
                let file_path: String = file.path().to_string();
                let file_name: String = file.name();
                if file_path.contains(&file_name) {
                    file_path
                } else {
                    let correct_file_path = format!("{}{}", file_path, file_name);
                    correct_file_path
                }
            })
            .collect();

    println!(
        "files_from_storage_local_folder: {:?}\n\n\n",
        files_from_storage_local_folder.clone()
    );
    println!(
        "files_from_constellation_in_root_folder: {:?}\n\n\n",
        files_from_constellation_in_root_folder.clone()
    );

    sync_files_from_local_to_constellation(
        &files_from_storage_local_folder,
        files_from_constellation_in_root_folder,
        state,
        upload_file_controller,
        eval,
    );

    sync_files_from_constellation_to_local(
        files_from_current_folder_in_constellation,
        files_from_storage_local_folder,
        ch,
    );
}

fn sync_files_from_local_to_constellation(
    files_from_storage_local_folder: &Vec<PathBuf>,
    files_from_constellation_in_root_folder: Vec<String>,
    state: &UseSharedState<State>,
    upload_file_controller: UploadFileController<'_>,
    eval: &std::rc::Rc<dyn Fn(&str) -> Result<UseEval, EvalError>>,
) {
    let unique_local_files: Vec<PathBuf> = files_from_storage_local_folder
        .clone()
        .into_iter()
        .filter(|local_file| {
            let local_file_str = local_file.to_str().unwrap_or("");
            !files_from_constellation_in_root_folder.contains(&local_file_str.to_string())
                && !local_file_str.contains(".DS_Store")
        })
        .map(|file| {
            let correct_local_file_path = format!(
                "{}/{}",
                STORAGE_LOCAL_FOLDER.clone().to_string_lossy(),
                file.to_str().unwrap_or("")
            );
            PathBuf::from(correct_local_file_path)
        })
        .collect();

    log::debug!(
        "unique_local_files available to upload: {:?}",
        unique_local_files.clone()
    );
    if unique_local_files.is_empty() {
        state
            .write()
            .mutate(Action::AddToastNotification(ToastNotification::init(
                "".into(),
                "No files to sync".to_string(),
                None,
                2,
            )));
    } else {
        functions::add_files_in_queue_to_upload(
            upload_file_controller.files_in_queue_to_upload,
            unique_local_files,
            eval,
        );
        upload_file_controller
            .files_been_uploaded
            .with_mut(|i| *i = true);
    }
}

fn sync_files_from_constellation_to_local(
    files_from_current_folder_in_constellation: Vec<File>,
    files_from_storage_local_folder: Vec<PathBuf>,
    ch: &Coroutine<ChanCmd>,
) {
    let unique_constellation_files: Vec<File> = files_from_current_folder_in_constellation
        .into_iter()
        .filter(|constellation_file| {
            !files_from_storage_local_folder
                .clone()
                .iter()
                .any(|local_file| {
                    local_file.to_str().unwrap_or("") == format!("/{}", &constellation_file.name())
                })
        })
        .map(|file| file)
        .collect();
    log::debug!(
        "unique_constellation_files available to download: {:?}",
        unique_constellation_files
            .iter()
            .map(|file| file.name())
            .collect::<Vec<String>>()
    );

    for file in unique_constellation_files {
        let file_name = file.name();
        let dir_to_save_files = STORAGE_LOCAL_FOLDER.to_string_lossy().to_string().clone();
        let path_to_save = PathBuf::from(format!("{}/{}", dir_to_save_files, file_name));
        ch.send(ChanCmd::DownloadFile {
            file_name: file_name.to_string(),
            local_path_to_save_file: path_to_save,
        });
    }
}

fn list_files<P: AsRef<Path>>(path: P, files: &mut Vec<PathBuf>) -> io::Result<Vec<PathBuf>> {
    if path.as_ref().is_dir() {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                list_files(&path, files)?;
            } else {
                if let Some(parent) = path.parent() {
                    if parent.ends_with("storage_local_folder") {
                        let new_path = Path::new("/").join(path.file_name().unwrap());
                        files.push(new_path);
                    } else {
                        files.push(path);
                    }
                } else {
                    files.push(path);
                }
            }
        }
    }
    Ok(files.clone())
}
