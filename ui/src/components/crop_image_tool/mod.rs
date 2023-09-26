use common::icons::outline::Shape;
use dioxus::{html::a, prelude::*};
use dioxus_desktop::{use_wry_event_handler, tao::event::{Event, WindowEvent}};
use image::{DynamicImage, GenericImageView, ImageBuffer, Rgba};
use kit::{
    elements::{button::Button, range::Range, select::Select, Appearance},
    layout::modal::Modal,
};
use std::{path::PathBuf, time::Duration};

#[derive(Debug, Clone)]
struct ImageDimensions {
    height: i64,
    width: i64,
}

#[inline_props]
pub fn CropImageModal(cx: Scope<'a>, large_thumbnail: String) -> Element<'a> {
    let large_thumbnail = cx.props.large_thumbnail.clone();

    let crop_circle_size = use_ref(cx, || 0);
    let image_scale: &UseRef<f64> = use_ref(cx, || 1.0);
    let crop_image = use_state(cx, || true);
    let get_image_dimensions_script = include_str!("./get_image_dimensions.js");
    let adjust_crop_circle_size = include_str!("./adjust_crop_circle_size.js");

    let image_dimensions = use_ref(cx, || ImageDimensions {
        height: 0,
        width: 0,
    });
    let eval = use_eval(cx);

    eval(&adjust_crop_circle_size);

    use_future(cx, (), |_| {
        to_owned![get_image_dimensions_script, eval, image_dimensions, crop_circle_size];
        async move {
            if let Ok(r) = eval(&get_image_dimensions_script) {
                if let Ok(val) = r.join().await {
                    *image_dimensions.write_silent() = ImageDimensions {
                        height: val["height"].as_i64().unwrap_or_default(),
                        width: val["width"].as_i64().unwrap_or_default(),
                    }; 
                    let min_dimension = std::cmp::min(image_dimensions.read().width, image_dimensions.read().height);
                    *crop_circle_size.write_silent() = min_dimension;
                    println!("image_dimensions: {:?}", image_dimensions.read());
                }
            };
        }
    });

    return cx.render(rsx!(div {
        Modal {
            open: *crop_image.clone(),
            onclose: move |_| crop_image.set(false),
            transparent: false, 
            show_close_button: false,
            dont_pad: false,
            div {
                max_height: "85vh",
                max_width: "80vw",
                padding: "16px",
                onclick: move |_| {},
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
                    class: "container",
                    margin_bottom: "16px",
                    text_align: "center",
                    padding: "16px",
                    div {
                        width: "auto",
                        overflow: "hidden",
                        border: "3px solid var(--secondary)",
                        img {
                            id: "image-preview-modal-file-embed",
                            aria_label: "image-preview-modal-file-embed",
                            src: "{large_thumbnail}",
                            transform: format_args!("scale({})", image_scale.read()),
                            overflow: "hidden",
                            transition: "transform 0.2s ease",
                            max_height: "50vh",
                            max_width: "50vw",
                            display: "inline-block",
                            vertical_align: "middle",
                            onclick: move |e| e.stop_propagation(),
                            
                        },
                        div {
                            id: "crop-box",
                            class: "crop-box",
                            // width: format_args!("{}px", crop_circle_size.read()),
                            // height: format_args!("{}px", crop_circle_size.read()),
                        }
                    }
                }
                Range {
                    initial_value: 1.0,
                    min: 0.5,
                    max: 5.0,
                    step: 0.01,
                    icon_left: Shape::Minus,
                    icon_right: Shape::Plus,
                    onchange: move |size_f64| {
                        println!("size: {}", size_f64);
                        *image_scale.write() = size_f64;
                    }
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
