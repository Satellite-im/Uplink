#[cfg(target_os = "macos")]
use super::macos_clipboard::MacOSClipboard;
#[cfg(target_os = "linux")]
use crate::utils::verify_valid_paths::decoded_pathbufs;

use arboard::Clipboard as Arboard;
#[cfg(target_os = "linux")]
use cli_clipboard::ClipboardContext;
#[cfg(target_os = "linux")]
use cli_clipboard::ClipboardProvider;
#[cfg(target_os = "windows")]
use clipboard_win::{formats, get_clipboard};
use image::DynamicImage;
use image::ImageBuffer;
use image::ImageOutputFormat;
use image::RgbaImage;
use std::error::Error;
use std::io::BufWriter;
#[cfg(target_os = "linux")]
use std::path::Path;
use std::path::PathBuf;
use tempfile::TempDir;

#[derive(Debug)]
pub enum ClipboardDataType {
    File,
    String,
}

/// It will verify if data in clipboard are local paths of files to upload them.
///
/// if not, it will grab pixels of image data in clipboard and transform them into
/// an image file to be possible to upload.
pub fn get_files_path_from_clipboard() -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    #[cfg(target_os = "windows")]
    {
        let file_path: Vec<PathBuf> = get_clipboard(formats::FileList {})
            .unwrap_or_default()
            .into_iter()
            .map(PathBuf::from)
            .collect();
        if !file_path.is_empty() {
            return Ok(file_path);
        }
    }
    // #[cfg(target_os = "macos")]
    {
        println!("MAcOS clipboard");
        let macos_clipboard = MacOSClipboard::new()?;
        let file_path = macos_clipboard
            .get_files_path_from_clipboard()
            .unwrap_or_default();
        if !file_path.is_empty() {
            return Ok(file_path);
        }
    }

    // #[cfg(target_os = "linux")]
    // {
    //     if let Ok(mut ctx) = ClipboardContext::new() {
    //         let clipboard_text = ctx.get_contents().unwrap_or_default();
    //         let paths_vec: Vec<PathBuf> = clipboard_text.lines().map(PathBuf::from).collect();
    //         println!("paths_vec text: {:?}", paths_vec.clone());
    //         let is_valid_paths = match paths_vec.first() {
    //             Some(first_path) => Path::new(first_path).exists(),
    //             None => false,
    //         };
    //         if is_valid_paths {
    //             let files_path = decoded_pathbufs(paths_vec);
    //             if !files_path.is_empty() {
    //                 return Ok(files_path);
    //             }
    //         }
    //     }
    // }

    let image_from_clipboard = check_image_pixels_in_clipboard().unwrap_or_default();
    if !image_from_clipboard.is_empty() {
        return Ok(image_from_clipboard);
    }

    Ok(Vec::new())
}

pub fn check_if_there_is_file_or_string_in_clipboard(
) -> Result<ClipboardDataType, Box<dyn std::error::Error>> {
    #[cfg(target_os = "windows")]
    {
        let file_path: Vec<PathBuf> = get_clipboard(formats::FileList {})
            .unwrap_or_default()
            .into_iter()
            .map(PathBuf::from)
            .collect();
        if !file_path.is_empty() {
            return Ok(ClipboardDataType::File);
        }
    }
    #[cfg(target_os = "macos")]
    {
        let macos_clipboard = MacOSClipboard::new()?;
        let file_path = macos_clipboard
            .get_files_path_from_clipboard()
            .unwrap_or_default();
        if !file_path.is_empty() {
            return Ok(ClipboardDataType::File);
        }
    }

    if let Ok(mut clipboard) = Arboard::new() {
        let clipboard_text = clipboard.get_text().unwrap_or_default();
        #[cfg(target_os = "linux")]
        {
            let paths_vec: Vec<PathBuf> = clipboard_text.lines().map(PathBuf::from).collect();
            let is_valid_paths = match paths_vec.first() {
                Some(first_path) => Path::new(first_path).exists(),
                None => false,
            };
            if is_valid_paths {
                return Ok(ClipboardDataType::File);
            }
        }

        if clipboard_text.is_empty() {
            // It means image pixels in clipboard
            Ok(ClipboardDataType::File)
        } else {
            Ok(ClipboardDataType::String)
        }
    } else {
        Ok(ClipboardDataType::String)
    }
}

fn check_image_pixels_in_clipboard() -> Result<Vec<PathBuf>, Box<dyn Error>> {
    match Arboard::new() {
        Err(_) => Ok(Vec::new()),
        Ok(mut clipboard) => {
            let image = match clipboard.get_image() {
                Ok(img) => img,
                Err(e) => {
                    log::warn!("Error to get image from clipboard: {}", e);
                    return Ok(Vec::new());
                }
            };
            let image: RgbaImage = match ImageBuffer::from_raw(
                image.width.try_into().unwrap_or(256),
                image.height.try_into().unwrap_or(256),
                image.bytes.into_owned(),
            ) {
                Some(data) => data,
                None => {
                    log::warn!("Not possible to transform Image Bytes in Image Buffer");
                    return Ok(Vec::new());
                }
            };
            let temp_dir = TempDir::new()?;
            let temp_path = temp_dir
                .into_path()
                .join(String::from("img_from_clipboard.png"));
            let image = DynamicImage::ImageRgba8(image);
            let file = std::fs::File::create(temp_path.clone())?;
            let mut buffered_writer = BufWriter::new(file);
            if let Err(e) = image.write_to(&mut buffered_writer, ImageOutputFormat::Png) {
                log::warn!("Error to write image in a temp file: {}", e);
                return Ok(Vec::new());
            };
            Ok(vec![temp_path])
        }
    }
}
