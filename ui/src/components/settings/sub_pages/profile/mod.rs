use dioxus::{prelude::*};
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
    let status_message = use_state(&cx, || "status message".to_owned());


    let change_banner_text = get_local_text("settings-profile.change-banner");
    let change_avatar_text = get_local_text("settings-profile.change-avatar");

    let show_texts = !**edit_mode;
    let show_edit_fields = **edit_mode;

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
                show_texts.then(|| rsx!(
                    div {
                        class: "edit-button", 
                        Button {
                            text: get_local_text("settings-profile.edit-button"),
                            onpress: move |_| edit_mode.set(!edit_mode),
                        },
                    },
                    p { 
                        class: "username",
                        "{username}"
                    },
                    p { 
                        class: "status-message",
                        "{status_message}"
                    }
                ))
                show_edit_fields.then(|| 
                    {
                    let new_username_val = use_ref(&cx, String::new);
                    let new_status_message_val = use_ref(&cx, || format!("{}", status_message));
                    rsx!(
                    div {
                        class: "edit-button", 
                        Button {
                            text: get_local_text("settings-profile.save-button"),
                            onpress: move |_| {
                                let new_username = new_username_val.with(|i| i.clone());
                                if !new_username.is_empty() && new_username.len() > 3 {
                                    username.set(new_username);
                                }
                                let new_status_message = new_status_message_val.with(|i| i.clone());
                                status_message.set(new_status_message);
                                edit_mode.set(!edit_mode);
                            },
                        },
                    },
                    div {
                        class: "username", 
                        Input {
                            id: "username_text_field".to_owned(),
                            focus: true,
                            placeholder: format!("{}", username),
                            disabled: false,
                            onchange: move |value| {
                                *new_username_val.write_silent() = value;
                            }, 
                            options: Options {
                                with_clear_btn: true,
                                ..Options::default()
                            },
                        },
                    },
                  div {
                        class: "status-message-edit", 
                        Input {
                            placeholder: format!("{}", status_message),
                            disabled: false,
                            onchange: move |value| {
                                *new_status_message_val.write_silent() = value;
                            }, 
                            options: Options {
                                with_clear_btn: true,
                                ..Options::default()
                            }
                        }
                    },
                    )}),
              
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