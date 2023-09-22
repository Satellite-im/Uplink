use common::icons::outline::Shape;
use dioxus::{html::a, prelude::*};
use image::{DynamicImage, GenericImageView, ImageBuffer, Rgba};
use kit::{
    elements::{button::Button, range::Range, select::Select, Appearance},
    layout::modal::Modal,
};
use std::path::PathBuf;

#[inline_props]
pub fn CropImageModal(cx: Scope<'a>, large_thumbnail: String) -> Element<'a> {
    // let image_path = cx.props.image_path.clone();
    // let img = image::open(image_path).unwrap();
    let large_thumbnail = cx.props.large_thumbnail.clone();

    // // Initial crop parameters
    // let mut center_x = img.width() as i32 / 2;
    // let mut center_y = img.height() as i32 / 2;
    // let mut radius = (img.width() as f32 / 2.0) as i32;
    // let mut zoom = 1.0;

    // // Create a circular cropped image
    // let cropped_img = crop_circle(&img, center_x, center_y, radius);

    let crop_image = use_state(cx, || true);
    // let circular_crop_cursor_script = include_str!("./crop_cursor.js");

    // let _ = use_eval(cx)(circular_crop_cursor_script);

    return cx.render(rsx!(div {
        Modal {
            open: *crop_image.clone(),
            onclose: move |_| crop_image.set(false),
            transparent: false, 
            show_close_button: false,
            dont_pad: false,
            div {
                max_height: "80vh",
                max_width: "80vw",
                padding: "16px",
                div {
                    id: "crop-image-topbar", 
                    background: "var(--secondary)",
                    height: "70px",
                    border_radius: "12px",
                    div {
                        id: "crop-image-topbar-left",
                        padding: "16px",
                        display: "inline-flex",
                        div {
                            id: "crop-image-topbar-left-title",
                            color: "var(--text-color)",
                            margin_right: "32px",
                            "Please select the area\n you want to crop"
                        },
                        Button {
                            appearance: Appearance::DangerAlternative,
                            icon: Shape::XMark,
                            onpress: move |_| {

                            }
                        },
                        div {
                            margin_right: "16px",
                        }
                        Button {
                            appearance: Appearance::Success,
                            icon: Shape::Check,
                            onpress: move |_| {

                            }
                        }
                    },
                }
                div {
                    margin_bottom: "16px",
                    img {
                        id: "image-preview-modal-file-embed",
                        aria_label: "image-preview-modal-file-embed",
                        padding: "16px",
                        src: "{large_thumbnail}",
                        max_height: "60vh",
                        max_width: "60vw",
                        onclick: move |e| e.stop_propagation(),
                    },
                }
                Range {
                    initial_value: 100,
                    min: 0,
                    max: 200,
                    icon_left: Shape::Minus,
                    icon_right: Shape::Plus,
                    onchange: move |_| {}
                }
            }
            
        }
    },));
}

fn crop_circle(
    img: &DynamicImage,
    center_x: i32,
    center_y: i32,
    radius: i32,
) -> ImageBuffer<Rgba<u8>, Vec<u8>> {
    let mut cropped_img = ImageBuffer::new(radius as u32 * 2, radius as u32 * 2);

    for y in 0..radius * 2 {
        for x in 0..radius * 2 {
            let dx = x - radius;
            let dy = y - radius;
            let distance_squared = (dx * dx + dy * dy) as f32;

            if distance_squared <= (radius * radius) as f32 {
                let original_x = center_x - radius + x;
                let original_y = center_y - radius + y;

                if original_x >= 0
                    && original_x < img.width() as i32
                    && original_y >= 0
                    && original_y < img.height() as i32
                {
                    let pixel = img.get_pixel(original_x as u32, original_y as u32);
                    cropped_img.put_pixel(x as u32, y as u32, pixel);
                }
            }
        }
    }

    cropped_img
}
