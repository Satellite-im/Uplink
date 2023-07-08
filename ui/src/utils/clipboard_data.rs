use arboard::Clipboard;
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

pub fn get_files_path_from_clipboard() -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    let file_path = verify_file_path_in_clipboard().unwrap_or(Vec::new());
    if !file_path.is_empty() {
        return Ok(file_path);
    } else {
        let image_from_clipboard = get_image_from_clipboard().unwrap_or(Vec::new());
        return Ok(image_from_clipboard);
    }
}

fn get_image_from_clipboard() -> Result<Vec<PathBuf>, Box<dyn Error>> {
    let mut clipboard = Clipboard::new().unwrap();
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
        .path()
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

fn verify_file_path_in_clipboard() -> Result<Vec<PathBuf>, Box<dyn Error>> {
    // TODO: Try other solution with macros to hide call native code
    // Using swift script
    let output = Command::new("swift").arg(SWIFT_SCRIPT).output()?;

    // return from swift script
    let stdout = str::from_utf8(&output.stdout)?.trim().to_owned();
    let files_path_str: Vec<&str> = stdout.split(|c| c == '\n').collect();
    let files_path_buf: Vec<PathBuf> = files_path_str.into_iter().map(PathBuf::from).collect();
    println!("files_path_buf: {:?}", files_path_buf);
    Ok(files_path_buf)
}
