use arboard::Clipboard as Arboard;
use image::DynamicImage;
use image::ImageBuffer;
use image::ImageOutputFormat;
use image::RgbaImage;
use std::error::Error;
use std::io::BufWriter;
use std::path::PathBuf;
use tempfile::TempDir;

use super::macos_clipboard::MacOSClipboard;

/// It will verify if data in clipboard are local paths of files to upload them.
///
/// if not, it will grab pixels of image data in clipboard and transform them into
/// an image file to be possible to upload.
pub fn get_files_path_from_clipboard() -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    let macos_clipboard = MacOSClipboard::new()?;
    let file_path = macos_clipboard.read().unwrap_or_default();
    if !file_path.is_empty() {
        return Ok(file_path);
    }

    let image_from_clipboard = check_image_pixels_in_clipboard().unwrap_or(Vec::new());
    if !image_from_clipboard.is_empty() {
        return Ok(image_from_clipboard);
    }

    Ok(Vec::new())
}

pub enum ClipboardDataType {
    File,
    String,
}

pub fn check_if_there_is_file_or_string_in_clipboard(
) -> Result<ClipboardDataType, Box<dyn std::error::Error>> {
    let macos_clipboard = MacOSClipboard::new()?;
    let file_path = macos_clipboard.read().unwrap_or_default();
    let mut clipboard = Arboard::new().unwrap();
    let clipboard_text = clipboard.get_text().unwrap_or_default();
    if !file_path.is_empty() {
        return Ok(ClipboardDataType::File);
    } else if file_path.is_empty() && clipboard_text.is_empty() {
        // It means image pixes in clipboard
        return Ok(ClipboardDataType::File);
    } else {
        return Ok(ClipboardDataType::String);
    }
}

fn check_image_pixels_in_clipboard() -> Result<Vec<PathBuf>, Box<dyn Error>> {
    let mut clipboard = Arboard::new().unwrap();
    let image = match clipboard.get_image() {
        Ok(img) => img,
        Err(e) => {
            log::warn!("Error to get image from clipboard: {}", e);
            return Ok(Vec::new());
        }
    };
    let image: RgbaImage = match ImageBuffer::from_raw(
        image.width.try_into().unwrap(),
        image.height.try_into().unwrap(),
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
        .join(String::from("image_uplink_clipboard.png"));
    let image = DynamicImage::ImageRgba8(image);
    let file = std::fs::File::create(temp_path.clone())?;
    let mut buffered_writer = BufWriter::new(file);
    if let Err(e) = image.write_to(&mut buffered_writer, ImageOutputFormat::Png) {
        log::warn!("Error to write image in a temp file: {}", e);
        return Ok(Vec::new());
    };
    Ok(vec![temp_path])
}
