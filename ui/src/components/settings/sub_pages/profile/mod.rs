use dioxus::prelude::*;
use kit::{
    elements::{button::Button, select::Select, switch::Switch},
    icons::Icon, components::{user_image::UserImage, indicator::{Status, Platform}},
};

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
                        src: "https://external-content.duckduckgo.com/iu/?u=https%3A%2F%2Fi.pinimg.com%2F736x%2F23%2Ffd%2Fbc%2F23fdbc96c0bdae69856c384d9f9f7328.jpg&f=1&nofb=1&ipt=4329959aa2081717ab982055642109e7712d944070af26ecbbf914fb227213b5&ipo=images",
                        height: "100",
                        width: "100",
                    },
                }
            },
        }
    ))
}
