use arboard::Clipboard;
use image::DynamicImage;
use image::ImageBuffer;
use image::ImageOutputFormat;
use image::RgbaImage;
use std::error::Error;
use std::io::BufWriter;
use std::io::Read;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::str;
use tempfile::TempDir;

pub fn paste_file_from_clipboard() -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    let file_path = verify_file_path_in_clipboard().unwrap_or(Vec::new());
    if !file_path.is_empty() {
        return Ok(file_path);
    } else {
        return Ok(Vec::new());
    }
    // if !file_path.is_empty() {
    //     let mut file = std::fs::File::open(file_path)?;
    //     let mut content = Vec::new();
    //     file.read_to_end(&mut content)?;
    //     let base64_default_image = format!("data:image/png;base64,{}", base64::encode(content));
    //     return Ok(base64_default_image);
    // }

    // let image_from_clipboard = get_image_from_clipboard().unwrap_or(String::new());
    // Ok(image_from_clipboard)
}

fn get_image_from_clipboard() -> Result<String, Box<dyn Error>> {
    let mut clipboard = Clipboard::new().unwrap();
    let image = match clipboard.get_image() {
        Ok(img) => img,
        Err(e) => {
            eprintln!("error getting image: {}", e);
            return Ok("".to_owned());
        }
    };
    eprintln!("getting {}×{} image", image.width, image.height);

    let image: RgbaImage = ImageBuffer::from_raw(
        image.width.try_into().unwrap(),
        image.height.try_into().unwrap(),
        image.bytes.into_owned(),
    )
    .unwrap();
    let temp_dir = TempDir::new()?;
    let temp_path = temp_dir
        .path()
        .join(String::from("image_uplink_clipboard.png"));
    let image = DynamicImage::ImageRgba8(image);
    let file = std::fs::File::create(temp_path.clone())?;
    let mut buffered_writer = BufWriter::new(file);
    image
        .write_to(&mut buffered_writer, ImageOutputFormat::Png)
        .unwrap();
    let mut file = std::fs::File::open(temp_path)?;
    let mut content = Vec::new();
    file.read_to_end(&mut content)?;
    let base64_default_image = format!("data:image/png;base64,{}", base64::encode(content));
    Ok(base64_default_image)
}

fn verify_file_path_in_clipboard() -> Result<Vec<PathBuf>, Box<dyn Error>> {
    // // Get files local path
    // let output1 = Command::new("osascript")
    //     .arg("-e")
    //     .arg("get the clipboard as «class furl»")
    //     .output()?;
    // let files_local_path = str::from_utf8(&output1.stdout)?
    //     .trim()
    //     .to_owned()
    //     .replace("file Macintosh HD:", "/")
    //     .replace(":", "/");
    // let path = Path::new(files_local_path.as_str()).parent().unwrap();
    // // Get files name
    // let output2 = Command::new("osascript")
    //     .arg("-e")
    //     .arg("get the clipboard as Unicode text")
    //     .output()?;
    // let output_str = str::from_utf8(&output2.stdout)?.trim().to_owned();
    // let file_names: Vec<&str> = output_str.split(|c| c == '\n' || c == '\r').collect();
    // let file_paths: Vec<PathBuf> = file_names
    //     .into_iter()
    //     .map(|file_name| Path::new(path).join(file_name.clone()))
    //     .collect();

    // Using swift script
    let output = Command::new("swift")
        .arg("ui/src/utils/clip_code.swift")
        .output()?;

    // return from swift script
    let stdout = str::from_utf8(&output.stdout)?.trim().to_owned();
    let files_path_str: Vec<&str> = stdout.split(|c| c == '\n').collect();
    let files_path_buf: Vec<PathBuf> = files_path_str.into_iter().map(PathBuf::from).collect();

    Ok(files_path_buf)
}
