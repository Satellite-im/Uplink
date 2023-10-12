use common::{icons::outline::Shape, language::get_local_text, STATIC_ARGS};
use dioxus::prelude::*;
use kit::{
    elements::{button::Button, label::Label, range::Range, Appearance},
    layout::modal::Modal,
};
use std::path::PathBuf;
use tokio::io::AsyncWriteExt;

const ADJUST_CROP_CIRCLE_SIZE_SCRIPT: &str = include_str!("./adjust_crop_circle_size.js");

const GET_IMAGE_DIMENSIONS_SCRIPT: &str = include_str!("./get_image_dimensions.js");

const SAVE_CROPPED_IMAGE_SCRIPT: &str = include_str!("./save_cropped_image.js");

#[derive(Debug, Clone)]
struct ImageDimensions {
    height: i64,
    width: i64,
}

#[derive(Props)]
pub struct Props<'a> {
    pub large_thumbnail: String,
    pub on_cancel: EventHandler<'a, ()>,
    pub on_crop: EventHandler<'a, PathBuf>,
}

#[allow(non_snake_case)]
pub fn CropImageModal<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let large_thumbnail = use_ref(cx, || cx.props.large_thumbnail.clone());

    let image_scale: &UseRef<f32> = use_ref(cx, || 1.0);
    let crop_image = use_state(cx, || true);
    let cropped_image_pathbuf = use_ref(cx, PathBuf::new);
    let clicked_button_to_crop = use_state(cx, || false);

    let image_dimensions = use_ref(cx, || ImageDimensions {
        height: 0,
        width: 0,
    });

    if *clicked_button_to_crop.get() {
        cx.props.on_crop.call(cropped_image_pathbuf.read().clone());
        clicked_button_to_crop.set(false);
        crop_image.set(false);
    }

    let eval = use_eval(cx);

    use_future(cx, (), |_| {
        to_owned![eval, image_dimensions];
        async move {
            while image_dimensions.read().width == 0 && image_dimensions.read().height == 0 {
                if let Ok(r) = eval(GET_IMAGE_DIMENSIONS_SCRIPT) {
                    if let Ok(val) = r.join().await {
                        *image_dimensions.write_silent() = ImageDimensions {
                            height: val["height"].as_i64().unwrap_or_default(),
                            width: val["width"].as_i64().unwrap_or_default(),
                        };
                    }
                };
            }
            let _ = eval(ADJUST_CROP_CIRCLE_SIZE_SCRIPT);
        }
    });

    return cx.render(rsx!(div {
        Modal {
            open: *crop_image.clone(),
            onclose: move |_| {
                // Not close if user clicks outside modal
            },
            transparent: false,
            show_close_button: false,
            close_on_click_inside_modal: false,
            dont_pad: false,
            div {
                max_height: "85vh",
                max_width: "80vw",
                padding: "16px",
                onclick: move |_| {},
                div {
                    id: "crop-image-topbar", 
                    aria_label: "crop-image-topbar",
                    background: "var(--secondary)",
                    height: "70px",
                    border_radius: "12px",
                    div {
                        id: "crop-image-topbar-left",
                        padding: "16px",
                        display: "inline-flex",
                        align_items: "center",
                        div {
                            class: "crop-image-topbar-left-title",
                            Label {
                                text: get_local_text("settings.please-select-area-you-want-to-crop"),
                                aria_label: "crop-image-topbar-label".into(),
                            }
                        },
                        Button {
                            appearance: Appearance::DangerAlternative,
                            aria_label: "crop-image-cancel-button".into(),
                            icon: Shape::XMark,
                            onpress: move |_| {
                                cx.props.on_cancel.call(());
                                crop_image.set(false);
                            }
                        },
                        div {
                            margin_right: "16px",
                        }
                        Button {
                            appearance: Appearance::Success,
                            aria_label: "crop-image-confirm-button".into(),
                            icon: Shape::Check,
                            onpress: move |_| {
                                cx.spawn({
                                    to_owned![eval, image_scale, cropped_image_pathbuf, clicked_button_to_crop];
                                    async move {
                                        let save_image_cropped_js = SAVE_CROPPED_IMAGE_SCRIPT
                                        .replace("$IMAGE_SCALE", (1.0 / *image_scale.read()).to_string().as_str());
                                        if let Ok(r) = eval(&save_image_cropped_js) {
                                            if let Ok(val) = r.join().await {
                                                let thumbnail = val.as_str().unwrap_or_default();
                                                let base64_string = thumbnail.trim_matches('\"');
                                                let decoded_bytes = match base64::decode(base64_string) {
                                                    Ok(bytes) => bytes,
                                                    Err(e) => {
                                                        log::error!("Error decoding base64 string for cropped image: {}", e);
                                                        return;
                                                    },
                                                };
                                                let cropped_image_path = STATIC_ARGS.uplink_path.join("cropped_image.png");
                                                let mut file = match tokio::fs::File::create(cropped_image_path.clone()).await {
                                                    Ok(file) => file,
                                                    Err(e) => {
                                                        log::error!("Error creating cropped image file: {}", e);
                                                        return;
                                                    },
                                                };

                                                if let Err(e) = file.write_all(&decoded_bytes).await {
                                                    log::error!("Error writing cropped image file. {}", e);
                                                    return;
                                                }
                                                cropped_image_pathbuf.with_mut(|f| *f = cropped_image_path.clone());
                                                clicked_button_to_crop.set(true);
                                            }
                                    }
                                }
                                });
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
                        id: "image-crop-box-container",
                        display: "inline-flex",
                        div {
                            overflow: "hidden",
                           width: "auto", 
                           height: "auto",
                            border: "3px solid var(--secondary)",
                            img {
                                id: "image-preview-modal-file-embed",
                                aria_label: "image-preview-modal-file-embed",
                                src: format_args!("{}", large_thumbnail.read()),
                                transform: format_args!("scale({})", image_scale.read()),
                                overflow: "hidden",
                                transition: "transform 0.2s ease",
                                max_height: "50vh",
                                max_width: "50vw",
                                display: "inline-block",
                                vertical_align: "middle",
                                onclick: move |e| e.stop_propagation(),
                            },
                        }
                        div {
                            id: "crop-box",
                            class: "crop-box",
                        },
                        div {
                            id: "shadow-img-mask",
                            class: "shadow-img-mask",
                        }
                    }
                },
                div {
                    class: "range-background",
                    Range {
                        aria_label: "range-crop-image".into(),
                        initial_value: 1.0,
                        min: 1.0,
                        max: 5.0,
                        step: 0.1,
                        with_buttons: true,
                        onchange: move |size_f32| {
                            *image_scale.write() = size_f32;
                        }
                    }
                }
            }
        }
    },
));
}
