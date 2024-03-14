use base64::{engine::general_purpose, Engine};

pub mod circle_format_tool;
pub mod rectangle_format_tool;

pub fn b64_encode((data, prefix): (Vec<u8>, String)) -> String {
    let base64_image = general_purpose::STANDARD.encode(data);
    let img = prefix + base64_image.as_str();
    img
}
