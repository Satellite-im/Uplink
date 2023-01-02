use dioxus::{prelude::*, html::input_data::keyboard_types::Code};
use kit::{
    elements::{button::Button, input::{Options, Input}},
};
use rfd::FileDialog;
use mime::*;

use crate::{
    utils::{
        language::{get_local_text},
    },
};

#[allow(non_snake_case)]
pub fn ProfileSettings(cx: Scope) -> Element {
    let image_state = use_state(&cx, String::new);
    let banner_state = use_state(&cx, String::new);
    let edit_mode = use_state(&cx, || false);
    let username = use_state(&cx, || "username".to_owned());

    let change_banner_text = get_local_text("settings-profile.change-banner");
    let change_avatar_text = get_local_text("settings-profile.change-avatar");

    let show_texts = !**edit_mode;
    let show_edit_fields = **edit_mode;
    let button_text = if **edit_mode {"Save".to_owned()} else {"Edit".to_owned()};

    cx.render(rsx!(
        div {
            id: "settings-profile",
            div {
                class: "profile-header",
                div { 
                    class: "profile-banner", 
                    img {
                        class: "profile-banner-photo",
                        src: "{banner_state}",
                        height: "100%",
                        width: "100%",
                        onclick: move |_| change_profile_image(banner_state),
                    },
                    p {class: "change-banner-text", "{change_banner_text}" },
            },
                div {
                    class: "profile-picture",
                    img {
                        class: "profile-avatar",
                        src: "{image_state}",
                        onclick: move |_| change_profile_image(image_state),
                    },
                    p {class: "change-avatar-text", "{change_avatar_text}" },
                }
                div {
                    class: "plus-button", 
                    Button {
                        icon: kit::icons::Icon::Plus,
                        onpress: move |_| change_profile_image(image_state),
                    },
                },
                div {
                    class: "edit-button", 
                    Button {
                        text: button_text,
                        onpress: move |_| edit_mode.set(!edit_mode),
                    },
                },
                show_edit_fields.then(|| rsx!(
                    div {
                        class: "username", 
                        Input {
                            placeholder: format!("{}", username),
                            disabled: false,
                            options: Options {
                                with_clear_btn: true,
                                ..Options::default()
                            },
                        },
                    },
                  div {
                        class: "status-message-edit", 
                        Input {
                            placeholder: "Type new status message".to_owned(),
                            disabled: false,
                            options: Options {
                                with_clear_btn: true,
                                ..Options::default()
                            }
                        }
                    },
                )),
                show_texts.then(|| rsx!(
                    p { 
                        class: "username",
                        "{username}"
                    },
                    p { 
                        class: "status-message",
                        "Status message"
                    }
                ))
            },
        }
    ))
}

fn change_profile_image(image_state: &UseState<String>) {
    let path = match FileDialog::new().add_filter("image", &["jpg", "png", "jpeg", "svg"]).set_directory(".").pick_file() {
        Some(path) => path,
        None => return
    };

    let file = match std::fs::read(&path) {
        Ok(image_vec) => image_vec,
        Err(_) => vec![],
    };

    let filename = std::path::Path::new(&path)
    .file_name()
    .unwrap_or_else(|| std::ffi::OsStr::new(""))
    .to_str()
    .unwrap()
    .to_string();

    let parts_of_filename: Vec<&str> = filename.split('.').collect();

    //Since files selected are filtered to be jpg, jpeg, png or svg the last branch is not reachable
    let mime = match parts_of_filename.last() {
        Some(m) => {
            match *m {
                "png" => IMAGE_PNG.to_string(),
                "jpg" => IMAGE_JPEG.to_string(),
                "jpeg" => IMAGE_JPEG.to_string(),
                "svg" => IMAGE_SVG.to_string(),
                &_ => "".to_string(),
            }
        },
        None =>  "".to_string(),
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
}