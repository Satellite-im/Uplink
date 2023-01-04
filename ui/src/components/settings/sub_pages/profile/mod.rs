use dioxus::{prelude::*};
use dioxus_desktop::use_eval;
use kit::{
    elements::{button::Button, input::{Options, Input}},
};
use rfd::FileDialog;
use mime::*;
use warp::{error::Error, logging::tracing::log};

use crate::{
    utils::{
        language::{get_local_text},
    },
};

#[allow(non_snake_case)]
pub fn ProfileSettings(cx: Scope) -> Element {
    let image_state = use_state(&cx, String::new);
    let banner_state = use_state(&cx, String::new);
    let username = use_state(&cx, || "username".to_owned());
    let status_message = use_state(&cx, || "status message".to_owned());

    let change_banner_text = get_local_text("settings-profile.change-banner");
    let change_avatar_text = get_local_text("settings-profile.change-avatar");
    let username_limited_to_32 = get_local_text("settings-profile.limited-to-32");
    let username_less_than_4 = get_local_text("settings-profile.less-than-4");
    let status_message_limited_to_128 = get_local_text("settings-profile.limited-to-128");

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
                        onclick: move |_| {
                            if let Err(error) = change_profile_image(banner_state) {
                                log::error!("Error to change profile avatar image {error}");
                            };
                        }
                    },
                    p {class: "change-banner-text", "{change_banner_text}" },
            },
                div {
                    class: "profile-picture",
                    img {
                        class: "profile-avatar",
                        src: "{image_state}",
                        onclick: move |_| {
                            if let Err(error) = change_profile_image(image_state) {
                                log::error!("Error to change profile avatar image {error}");
                            };
                        }
                    },
                    p {class: "change-avatar-text", "{change_avatar_text}" },
                }
                div {
                    class: "plus-button", 
                    Button {
                        icon: kit::icons::Icon::Plus,
                        onpress: move |_| {
                            if let Err(error) = change_profile_image(image_state) {
                                log::error!("Error to change profile avatar image {error}");
                            };
                        }
                    },
                },
                div {
                        id: "edit_button",
                        class: "edit-button", 
                        Button {
                            text: get_local_text("settings-profile.edit-button"),
                            onpress: move |_| {
                                use_eval(cx)(get_edit_mode_scripts()[0].clone());
                            },
                        },
                    },
                    p { 
                        id: "p_username",
                        class: "username",
                        "{username}"
                    },
                    p { 
                        id: "status_message",
                        class: "status-message",
                        "{status_message}"
                    }
                {
                    let new_username_val = use_ref(&cx,  || format!("{}", username));
                    let new_status_message_val = use_ref(&cx, || format!("{}", status_message));
                    rsx!(
                    div {
                        id: "save_button",
                        class: "save-button", 
                        Button {
                            text: get_local_text("settings-profile.save-button"),
                            onpress: move |_| {
                                let new_username = new_username_val.with(|i| i.clone());
                                if new_username_val.read().len() < 4 {
                                    return;
                                }
                                if new_username.len() > 3 {
                                    username.set(new_username.clone());
                                }
                                let new_status_message = new_status_message_val.with(|i| i.clone());
                                status_message.set(new_status_message);
                                use_eval(cx)(get_edit_mode_scripts()[1].clone());
                            },
                        },
                    },
                    div {
                        id: "username_edit",
                        class: "username-edit", 
                            Input {
                            id: "username_text_field".to_owned(),
                            focus: true,
                            placeholder: "".to_owned(),
                            default_text: format!("{}", if !new_username_val.read().is_empty() {username} else {""}),
                            max_length: 32,
                            disabled: false,
                            onchange: move |value| {
                                let val: String = value;
                                *new_username_val.write() = val.clone();
                                if val.len() < 4 {
                                    use_eval(cx)(get_username_rules_scripts()[2].clone());
                                }
                                if val.len() == 32 {
                                    use_eval(cx)(get_username_rules_scripts()[1].clone());
                                } else if val.len() < 32 && val.len() > 3 {
                                    use_eval(cx)(get_username_rules_scripts()[0].clone());
                                }
                            }, 
                            options: Options {
                                with_clear_btn: true,
                                ..Options::default()
                            },
                        }
                        p {class: "username-len-counter", format!("{}/32", new_username_val.read().len())},
                        p {id: "username_warning", class: "username-warning", format!("{}", username_limited_to_32)},
                        p {id: "username_warning_2", class: "username-warning-2", format!("{}", username_less_than_4)},
                    },
                  div {
                        id: "status_message_edit",
                        class: "status-message-edit", 
                        Input {
                            placeholder: "".to_owned(),
                            disabled: false,
                            default_text: format!("{}", if !new_status_message_val.read().is_empty() {status_message} else {""}),
                            max_length: 128,
                            onchange: move |value| {
                                let val: String = value;
                                *new_status_message_val.write() = val.clone();
                                if val.len() == 128 {
                                    use_eval(cx)(get_limited_to_128_chars_scripts()[0].clone());
                                } else if val.len() < 128 {
                                    use_eval(cx)(get_limited_to_128_chars_scripts()[1].clone());
                                }
                            }, 
                            options: Options {
                                with_clear_btn: true,
                                ..Options::default()
                            }
                        }
                        p {class: "status-message-len-counter", format!("{}/128", new_status_message_val.read().len())},
                        p {id: "status_message_warning", class: "status-message-warning", format!("{}", status_message_limited_to_128)},
                    },
                )}
            // ),
            },
        }
    ))
}

fn change_profile_image(image_state: &UseState<String>) -> Result<(), Box<dyn std::error::Error>>{
    let path = match FileDialog::new()
    .add_filter("image", &["jpg", "png", "jpeg", "svg"])
    .set_directory(".").pick_file() {
        Some(path) => path,
        None => return Err(Box::from(Error::InvalidItem)),
    };

    let file = std::fs::read(&path)?;

    let filename = path.file_name().map(|file| file.to_string_lossy().to_string()).unwrap_or_default();

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
    Ok(())
}

fn get_username_rules_scripts() -> Vec<String> {
    let script_less_than_4_chars = r#"
        document.getElementById("username_warning_2").style.opacity = 1
        document.getElementById("status_message_edit").style.top = "324px";
    "#;
    let script_32_chars_limit = r#"
            document.getElementById("status_message_edit").style.top = "324px";
            document.getElementById("username_warning").style.opacity = 1
        "#;
    let script_normal =  r#"
            document.getElementById("username_warning").style.opacity = 0
            document.getElementById("username_warning_2").style.opacity = 0
            document.getElementById("status_message_edit").style.top = "308px";
    "#;
    return vec![script_normal.to_owned(), script_32_chars_limit.to_owned(), script_less_than_4_chars.to_owned()];
}

fn get_limited_to_128_chars_scripts() -> Vec<String> {
    let script_forward = r#"
        document.getElementById("status_message_warning").style.opacity = 1
    "#;
    let script_back =  r#"
        document.getElementById("status_message_warning").style.opacity = 0
    "#;
    return vec![script_forward.to_owned(), script_back.to_owned()];
}

fn get_edit_mode_scripts() -> Vec<String> {
    let script_forward = r#"
        document.getElementById("p_username").style.opacity = 0
        document.getElementById("status_message").style.opacity = 0
        document.getElementById("status_message_edit").style.opacity = 1
        document.getElementById("username_edit").style.opacity = 1
        document.getElementById("edit_button").style.opacity = 0
        document.getElementById("save_button").style.opacity = 1

        document.getElementById("edit_button").style.zIndex = 1
        document.getElementById("save_button").style.zIndex = 2
    "#;
    let script_back = r#"
        document.getElementById("p_username").style.opacity = 1
        document.getElementById("status_message").style.opacity = 1
        document.getElementById("status_message_edit").style.opacity = 0
        document.getElementById("username_edit").style.opacity = 0
        document.getElementById("edit_button").style.opacity = 1
        document.getElementById("save_button").style.opacity = 0

        document.getElementById("edit_button").style.zIndex = 2
        document.getElementById("save_button").style.zIndex = 1
    "#;
    return vec![script_forward.to_owned(), script_back.to_owned()];
}