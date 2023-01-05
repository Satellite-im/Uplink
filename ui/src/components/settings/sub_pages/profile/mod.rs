use dioxus::prelude::*;
use kit::elements::{
    button::Button,
    input::{Input, Options, Validation},
    label::Label,
};
use mime::*;
use rfd::FileDialog;
use warp::{error::Error, logging::tracing::log};

use crate::utils::language::get_local_text;

#[allow(non_snake_case)]
pub fn ProfileSettings(cx: Scope) -> Element {
    // Set up validation options for the input field
    let validation_options = Validation {
        // The input should have a maximum length of 32
        max_length: Some(32),
        // The input should have a minimum length of 4
        min_length: Some(4),
        // The input should only contain alphanumeric characters
        alpha_numeric_only: true,
        // The input should not contain any whitespace
        no_whitespace: true,
    };

    let validation_options_status = Validation {
        // The input should have a maximum length of 128
        max_length: Some(128),
        // The input should have a minimum length of 0
        min_length: Some(0),
        // The input should only contain alphanumeric characters
        alpha_numeric_only: false,
        // The input should not contain any whitespace
        no_whitespace: false,
    };

    let image_state = use_state(&cx, String::new);
    let banner_state = use_state(&cx, String::new);

    let change_banner_text = get_local_text("settings-profile.change-banner");

    cx.render(rsx!(
        div {
            id: "settings-profile",
            div {
                class: "profile-header",
                div {
                    class: "profile-banner",
                    style: "background-image: url({banner_state});",
                    onclick: move |_| {
                        if let Err(error) = change_profile_image(banner_state) {
                            log::error!("Error to change profile avatar image {error}");
                        };
                    },
                    p {class: "change-banner-text", "{change_banner_text}" },
                },
                div {
                    class: "profile-picture",
                    style: "background-image: url({image_state});",
                    onclick: move |_| {
                        if let Err(error) = change_profile_image(image_state) {
                            log::error!("Error to change profile avatar image {error}");
                        };
                    },
                    Button {
                        icon: kit::icons::Icon::Plus,
                        onpress: move |_| {
                            if let Err(error) = change_profile_image(image_state) {
                                log::error!("Error to change profile avatar image {error}");
                            };
                        }
                    },
                }
            },
            div{
                class: "profile-content",
                div {
                    class: "plus-button",
                    Button {
                        icon: kit::icons::Icon::Plus,
                        onpress: move |_| {
                            if let Err(error) = change_profile_image(image_state) {
                                log::error!("Error to change profile avatar image {error}");
                            };
                        }
                    }
                },
                div {
                    class: "content-item",
                    Label {
                        text: get_local_text("uplink.username"),
                    },
                    Input {
                        placeholder: get_local_text("uplink.username"),
                        default_text: "Mock Username".into(),
                        options: get_input_options(validation_options),
                    },
                },
                div {
                    class: "content-item",
                    Label {
                        text: get_local_text("uplink.status"),
                    },
                    Input { 
                        placeholder: get_local_text("uplink.status"),
                        default_text: "Mock status messages are so 2008.".into(),
                        options: Options {
                            with_clear_btn: true,
                            ..get_input_options(validation_options_status)
                        }
                    }
                }
            }
        }
    ))
}

fn change_profile_image(image_state: &UseState<String>) -> Result<(), Box<dyn std::error::Error>> {
    let path = match FileDialog::new()
        .add_filter("image", &["jpg", "png", "jpeg", "svg"])
        .set_directory(".")
        .pick_file()
    {
        Some(path) => path,
        None => return Err(Box::from(Error::InvalidItem)),
    };

    let file = std::fs::read(&path)?;

    let filename = path
        .file_name()
        .map(|file| file.to_string_lossy().to_string())
        .unwrap_or_default();

    let parts_of_filename: Vec<&str> = filename.split('.').collect();

    //Since files selected are filtered to be jpg, jpeg, png or svg the last branch is not reachable
    let mime = match parts_of_filename.last() {
        Some(m) => match *m {
            "png" => IMAGE_PNG.to_string(),
            "jpg" => IMAGE_JPEG.to_string(),
            "jpeg" => IMAGE_JPEG.to_string(),
            "svg" => IMAGE_SVG.to_string(),
            &_ => "".to_string(),
        },
        None => "".to_string(),
    };

    let image = match &file.len() {
        0 => "".to_string(),
        _ => {
            let prefix = format!("data:{};base64,", mime);
            let base64_image = base64::encode(&file);
            let img = prefix + base64_image.as_str();
            img
        }
    };

    // TODO: Add upload picture to multipass here

    image_state.set(image);
    Ok(())
}

fn get_input_options(validation_options: Validation) -> Options {
        // Set up options for the input field
    Options {
        // Enable validation for the input field with the specified options
        with_validation: Some(validation_options),
        // Do not replace spaces with underscores
        replace_spaces_underscore: false,
        // Show a clear button inside the input field
        with_clear_btn: false,
        // Use the default options for the remaining fields
        ..Options::default()
    }
}