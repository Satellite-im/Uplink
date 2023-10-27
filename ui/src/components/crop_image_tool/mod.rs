pub mod circle_format_tool;
pub mod rectangle_format_tool;

pub fn b64_encode((data, prefix): (Vec<u8>, String)) -> String {
    let base64_image = base64::encode(data);
    let img = prefix + base64_image.as_str();
    img
}
