use arboard::Clipboard;
use image::DynamicImage;
use image::ImageBuffer;
use image::ImageOutputFormat;
use image::RgbaImage;
use std::error::Error;
use std::io::BufWriter;
use std::io::Read;
use std::process::Command;
use std::str;
use tempfile::TempDir;

pub fn paste_file_from_clipboard() -> Result<String, Box<dyn std::error::Error>> {
    let file_path = verify_file_path_in_clipboard().unwrap_or(String::new());

    if !file_path.is_empty() {
        let mut file = std::fs::File::open(file_path)?;
        let mut content = Vec::new();
        file.read_to_end(&mut content)?;
        let base64_default_image = format!("data:image/png;base64,{}", base64::encode(content));
        return Ok(base64_default_image);
    }

    let image_from_clipboard = get_image_from_clipboard().unwrap_or(String::new());
    Ok(image_from_clipboard)
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

fn verify_file_path_in_clipboard() -> Result<String, Box<dyn Error>> {
    let output = Command::new("osascript")
        .arg("-e")
        .arg("get the clipboard as «class furl»")
        .output()?;
    let file_path = str::from_utf8(&output.stdout)?
        .trim()
        .to_owned()
        .replace("file Macintosh HD:", "/")
        .replace(":", "/");
    Ok(file_path)
}
