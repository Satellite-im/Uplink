use ::clipboard_win::formats::CF_HDROP;
use arboard::Clipboard as Arboard;
use clipboard_win::{formats, Clipboard as ClipboardWin};
use image::DynamicImage;
use image::ImageBuffer;
use image::ImageOutputFormat;
use image::RgbaImage;
use std::error::Error;
use std::io::BufWriter;
use std::path::PathBuf;
use std::process::Command;
use std::str;
use tempfile::TempDir;

static SWIFT_SCRIPT: &str = "ui/src/utils/clip_code.swift";

/// It will verify if data in clipboard are local paths of files to upload them.
///
/// if not, it will grab pixels of image data in clipboard and transform them into
/// an image file to be possible to upload.
pub fn get_files_path_from_clipboard() -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    let file_path = check_files_path_in_clipboard().unwrap_or(Vec::new());
    if !file_path.is_empty() {
        return Ok(file_path);
    }

    let image_from_clipboard = check_image_pixels_in_clipboard().unwrap_or(Vec::new());
    if !image_from_clipboard.is_empty() {
        return Ok(image_from_clipboard);
    }

    Ok(Vec::new())
}

pub fn get_files_path_or_text_from_clipboard(
) -> Result<(Vec<PathBuf>, String), Box<dyn std::error::Error>> {
    let file_path = check_files_path_in_clipboard().unwrap_or(Vec::new());
    if !file_path.is_empty() {
        return Ok((file_path, String::new()));
    }
    let mut clipboard = Arboard::new().unwrap();
    let clipboard_text = clipboard.get_text().unwrap_or_default();
    if !clipboard_text.is_empty() {
        return Ok((Vec::new(), clipboard_text));
    }
    Ok((Vec::new(), String::new()))
}
use clipboard::ClipboardContext;
use clipboard::ClipboardProvider;
pub fn check_files_path_in_clipboard() -> Result<Vec<PathBuf>, Box<dyn Error>> {
    #[cfg(not(target_os = "windows"))]
    {
        // TODO: Try other solution with macros to hide call native code
        // Using swift script
        let output = Command::new("swift").arg(SWIFT_SCRIPT).output()?;

        // return from swift script
        let stdout = str::from_utf8(&output.stdout)?.trim().to_owned();
        if stdout.is_empty() {
            return Ok(Vec::new());
        }
        let files_path_str: Vec<&str> = stdout.split(|c| c == '\n').collect();
        let files_path_buf: Vec<PathBuf> = files_path_str.into_iter().map(PathBuf::from).collect();
        Ok(files_path_buf)
    }
    // #[cfg(target_os = "windows")]
    // {
    //     let clipboard = ClipboardWin::new().unwrap();
    //     let clipboard_data = clipboard_win::get_clipboard_string().unwrap_or_default();
    //     println!("clipboard_data: {:?}", clipboard_data);
    //     return Ok(Vec::new());
    // }

    let mut ctx: ClipboardContext = ClipboardProvider::new().unwrap();
    println!("{:?}", ctx.get_contents());
    return Ok(Vec::new());
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
