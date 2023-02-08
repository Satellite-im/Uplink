use std::{
    ffi::OsStr,
    io::Cursor,
    path::{Path, PathBuf},
};

use derive_more::Display;
use futures::{channel::oneshot, StreamExt};
use image::io::Reader as ImageReader;
use mime::*;
use once_cell::sync::Lazy;
use tokio_util::io::ReaderStream;

use crate::state::storage::Storage as uplink_storage;
use crate::warp_runner::Storage as warp_storage;

use warp::{
    constellation::{directory::Directory, Progression},
    error::Error,
    logging::tracing::log,
    sync::RwLock,
};

static DIRECTORIES_AVAILABLE_TO_BROWSE: Lazy<RwLock<Vec<Directory>>> =
    Lazy::new(|| RwLock::new(Vec::new()));

#[derive(Display)]
pub enum ConstellationCmd {
    #[display(fmt = "GetItemsFromCurrentDirectory")]
    GetItemsFromCurrentDirectory {
        rsp: oneshot::Sender<Result<uplink_storage, warp::error::Error>>,
    },
    #[display(fmt = "CreateNewDirectory {{ directory_name: {directory_name} }} ")]
    CreateNewDirectory {
        directory_name: String,
        rsp: oneshot::Sender<Result<(), warp::error::Error>>,
    },
    #[display(fmt = "OpenDirectory {{ directory_name: {directory_name} }} ")]
    OpenDirectory {
        directory_name: String,
        rsp: oneshot::Sender<Result<uplink_storage, warp::error::Error>>,
    },
    #[display(fmt = "BackToPreviousDirectory {{ directory: {:?} }} ", directory)]
    BackToPreviousDirectory {
        directory: Directory,
        rsp: oneshot::Sender<Result<uplink_storage, warp::error::Error>>,
    },
    #[display(fmt = "UploadFiles {{ files_path: {:?} }} ", files_path)]
    UploadFiles {
        files_path: Vec<PathBuf>,
        rsp: oneshot::Sender<Result<uplink_storage, warp::error::Error>>,
    },
}

pub async fn handle_constellation_cmd(cmd: ConstellationCmd, warp_storage: &mut warp_storage) {
    match cmd {
        ConstellationCmd::GetItemsFromCurrentDirectory { rsp } => {
            let r = get_items_from_current_directory(warp_storage);
            let _ = rsp.send(r);
        }
        ConstellationCmd::CreateNewDirectory {
            directory_name,
            rsp,
        } => {
            let r = create_new_directory(&directory_name, warp_storage).await;
            let _ = rsp.send(r);
        }
        ConstellationCmd::OpenDirectory {
            directory_name,
            rsp,
        } => {
            let r = open_new_directory(warp_storage, &directory_name);
            let _ = rsp.send(r);
        }
        ConstellationCmd::BackToPreviousDirectory { directory, rsp } => {
            let r = go_back_to_previous_directory(warp_storage, directory);
            let _ = rsp.send(r);
        }
        ConstellationCmd::UploadFiles { files_path, rsp } => {
            let r = upload_files(warp_storage, files_path).await;
            let _ = rsp.send(r);
        }
    }
}

async fn create_new_directory(
    folder_name: &str,
    warp_storage: &mut warp_storage,
) -> Result<(), Error> {
    println!("Folder path: {}", folder_name.clone());
    warp_storage.create_directory(folder_name, true).await?;
    log::debug!("New directory created: {:?}", folder_name);
    Ok(())
}

fn get_items_from_current_directory(
    warp_storage: &mut warp_storage,
) -> Result<uplink_storage, Error> {
    let current_dir = match warp_storage.current_directory() {
        Ok(dir) => dir,
        Err(error) => {
            println!("Error on get current directory: {error}");
            return Err(error);
        }
    };
    let mut current_dirs = get_directories_opened();
    set_new_directory_opened(current_dirs.as_mut(), current_dir.clone());

    let items = current_dir.get_items();

    let mut directories = items
        .iter()
        .filter_map(|item| item.get_directory().ok())
        .collect::<Vec<_>>();
    let mut files = items
        .iter()
        .filter_map(|item| item.get_file().ok())
        .collect::<Vec<_>>();

    directories.sort_by_key(|b| std::cmp::Reverse(b.modified()));
    files.sort_by_key(|b| std::cmp::Reverse(b.modified()));

    let uplink_storage = uplink_storage {
        initialized: true,
        current_dir,
        directories_opened: get_directories_opened(),
        directories,
        files,
    };
    log::info!("Get items from current directory worked!");
    Ok(uplink_storage)
}

fn get_directories_opened() -> Vec<Directory> {
    DIRECTORIES_AVAILABLE_TO_BROWSE.read().to_owned()
}

fn set_new_directory_opened(current_dir: &mut Vec<Directory>, new_dir: Directory) {
    if !current_dir.contains(&new_dir) {
        log::debug!("Updating directories opened to browse");
        current_dir.push(new_dir);
        *DIRECTORIES_AVAILABLE_TO_BROWSE.write() = current_dir.to_owned()
    }
}

fn open_new_directory(
    warp_storage: &mut warp_storage,
    folder_name: &str,
) -> Result<uplink_storage, Error> {
    println!("Folder path: {}", folder_name.clone());
    match warp_storage.select(&folder_name) {
        Ok(_) => println!("folder selected"),
        Err(error) => println!("Error on select folder {error}"),
    }
    log::info!("Navigation to directory {} worked!", folder_name);
    get_items_from_current_directory(warp_storage)
}

fn go_back_to_previous_directory(
    warp_storage: &mut warp_storage,
    directory: Directory,
) -> Result<uplink_storage, Error> {
    let mut current_dirs = get_directories_opened();
    loop {
        let current_dir = match warp_storage.current_directory() {
            Ok(dir) => dir,
            Err(error) => {
                log::error!("Error on get current directory: {error}");
                return Err(error);
            }
        };
        current_dirs.remove(current_dirs.len() - 1);
        if current_dir.id() == directory.id() {
            set_new_directory_opened(current_dirs.as_mut(), current_dir);
            break;
        }

        if let Err(error) = warp_storage.go_back() {
            log::error!("Error on go back a directory: {error}");
            return Err(error);
        };
    }
    log::info!("Navigation to directory {} worked!", directory.name());
    get_items_from_current_directory(warp_storage)
}

async fn upload_files(
    warp_storage: &mut warp_storage,
    files_path: Vec<PathBuf>,
) -> Result<uplink_storage, Error> {
    let current_directory = warp_storage.current_directory()?;

    for file_path in files_path {
        let mut filename = match file_path
            .file_name()
            .map(|file| file.to_string_lossy().to_string())
        {
            Some(file) => file,
            None => continue,
        };
        let local_path = Path::new(&file_path).to_string_lossy().to_string();
        let original = filename.clone();
        let file = PathBuf::from(&original);

        filename = verify_duplicate_name(current_directory.clone(), filename, file);

        let tokio_file = match tokio::fs::File::open(&local_path).await {
            Ok(file) => file,
            Err(error) => {
                log::error!("Error on get tokio file, cancelling upload action, error: {error}");
                continue;
            }
        };

        let total_size_for_stream = match tokio_file.metadata().await {
            Ok(data) => Some(data.len() as usize),
            Err(error) => {
                log::error!("Error getting metadata: {:?}", error);
                None
            }
        };

        let file_stream = ReaderStream::new(tokio_file)
            .filter_map(|x| async { x.ok() })
            .map(|x| x.into());

        match warp_storage
            .put_stream(&filename, total_size_for_stream, file_stream.boxed())
            .await
        {
            Ok(mut upload_progress) => {
                let mut previous_percentage: usize = 0;
                let mut upload_process_started = false;

                while let Some(upload_progress) = upload_progress.next().await {
                    match upload_progress {
                        Progression::CurrentProgress {
                            name,
                            current,
                            total,
                        } => {
                            if !upload_process_started {
                                upload_process_started = true;
                                log::info!("Starting upload for {name}");
                                log::info!("0% completed -> written 0 bytes")
                            };

                            if let Some(total) = total {
                                let current_percentage =
                                    (((current as f64) / (total as f64)) * 100.) as usize;
                                if previous_percentage != current_percentage {
                                    previous_percentage = current_percentage;
                                    log::info!(
                                        "{}% completed -> written {current} bytes",
                                        (((current as f64) / (total as f64)) * 100.) as usize
                                    )
                                }
                            }
                        }
                        Progression::ProgressComplete { name, total } => {
                            log::info!(
                                "{name} has been uploaded with {} MB",
                                total.unwrap_or_default() / 1024 / 1024
                            );
                        }
                        Progression::ProgressFailed {
                            name,
                            last_size,
                            error,
                        } => {
                            log::info!(
                                "{name} failed to upload at {} MB due to: {}",
                                last_size.unwrap_or_default(),
                                error.unwrap_or_default()
                            );
                        }
                    }
                }
                match set_thumbnail_if_file_is_image(warp_storage, filename.clone()).await {
                    Ok(success) => log::info!("{:?}", success),
                    Err(error) => log::error!("Error on update thumbnail: {:?}", error),
                }
                log::info!("{:?} file uploaded!", filename);
            }
            Err(error) => log::error!("Error when upload file: {:?}", error),
        }
    }
    get_items_from_current_directory(warp_storage)
}

fn verify_duplicate_name(
    current_directory: Directory,
    filename: String,
    file_pathbuf: PathBuf,
) -> String {
    let mut count_index_for_duplicate_filename = 1;
    let mut new_file_name = filename.clone();
    let original = filename;
    loop {
        if !current_directory.has_item(&new_file_name) {
            break;
        }
        let file_extension = file_pathbuf
            .extension()
            .and_then(OsStr::to_str)
            .map(str::to_string);
        let file_stem = file_pathbuf
            .file_stem()
            .and_then(OsStr::to_str)
            .map(str::to_string);

        new_file_name = match (file_stem, file_extension) {
            (Some(file_stem), Some(file_extension)) => {
                format!("{file_stem} ({count_index_for_duplicate_filename}).{file_extension}")
            }
            _ => format!("{original} ({count_index_for_duplicate_filename})"),
        };

        log::info!("Duplicate name, changing file name to {}", new_file_name);
        count_index_for_duplicate_filename += 1;
    }
    new_file_name
}

async fn set_thumbnail_if_file_is_image(
    warp_storage: &mut warp_storage,
    filename_to_save: String,
) -> Result<String, Box<dyn std::error::Error>> {
    let item = warp_storage
        .current_directory()?
        .get_item(&filename_to_save)?;
    let parts_of_filename: Vec<&str> = filename_to_save.split('.').collect();

    let file = warp_storage.get_buffer(&filename_to_save).await?;

    // Guarantee that is an image that has been uploaded
    ImageReader::new(Cursor::new(&file))
        .with_guessed_format()?
        .decode()?;

    // Since files selected are filtered to be jpg, jpeg, png or svg the last branch is not reachable
    let mime = match parts_of_filename
        .iter()
        .map(|extension| extension.to_lowercase())
        .last()
    {
        Some(m) => match m.as_str() {
            "png" => IMAGE_PNG.to_string(),
            "jpg" => IMAGE_JPEG.to_string(),
            "jpeg" => IMAGE_JPEG.to_string(),
            "svg" => IMAGE_SVG.to_string(),
            &_ => "".to_string(),
        },
        None => "".to_string(),
    };

    if !file.is_empty() || !mime.is_empty() {
        let prefix = format!("data:{mime};base64,");
        let base64_image = base64::encode(&file);
        let img = prefix + base64_image.as_str();
        item.set_thumbnail(&img);
        Ok(format_args!("{} thumbnail updated with success!", item.name()).to_string())
    } else {
        Err(Box::from(Error::InvalidItem))
    }
}
