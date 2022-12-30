use std::alloc::Layout;

use dioxus::{prelude::*, desktop::tao::dpi::Position};
use kit::{
    elements::{button::Button, select::Select, switch::Switch},
    icons::Icon, components::{user_image::UserImage, indicator::{Status, Platform}},
};
use rfd::FileDialog;
use mime::*;

use crate::{
    components::settings::SettingSection,
    state::{Action, State},
    utils::{
        get_available_themes,
        language::{change_language, get_available_languages, get_local_text},
    },
};

#[allow(non_snake_case)]
pub fn ProfileSettings(cx: Scope) -> Element {
    let state = use_context::<State>(&cx).unwrap();
    let initial_lang_value = state.read().settings.language.clone();
    let image_state = use_state(&cx, || "https://external-content.duckduckgo.com/iu/?u=https%3A%2F%2Fi.pinimg.com%2F736x%2F23%2Ffd%2Fbc%2F23fdbc96c0bdae69856c384d9f9f7328.jpg&f=1&nofb=1&ipt=4329959aa2081717ab982055642109e7712d944070af26ecbbf914fb227213b5&ipo=images".to_owned());

    let themes = get_available_themes();

    cx.render(rsx!(
        div {
            id: "settings-profile",
            div {
                class: "profile-header",
                div {
                    class: "profile-picture",
                    img {
                        class: "profile_photo",
                        src: "{image_state}",
                        height: "100",
                        width: "100",
                        onclick: move |_| change_profile_image(image_state),
                    },
                    p {class: "change-avatar-text",  "Change Avatar" },
                }
                div {
                    class: "plus-button", 
                    Button {
                        icon: kit::icons::Icon::Plus,
                        onpress: move |_| change_profile_image(image_state),
                    },
                },

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

    // TODO: Uncomment when add Multipass
    // if let Err(e) =  account.update_identity(IdentityUpdate::set_graphics_picture(image)) {
    //     println!("{}", e);
    // }
    // let identity = account.get_own_identity().unwrap();
    // let image = identity.graphics().profile_picture();
    image_state.set(image);
}