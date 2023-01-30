use dioxus::prelude::*;
use kit::{
    elements::{button::Button, select::Select, switch::Switch},
    icons::Icon,
};
use shared::language::{change_language, get_available_languages, get_local_text};
use warp::logging::tracing::log;

use crate::{
    components::settings::SettingSection,
    config::Configuration,
    state::{Action, State, Theme},
    utils::get_available_themes,
};

#[allow(non_snake_case)]
pub fn GeneralSettings(cx: Scope) -> Element {
    log::trace!("General settings rendered");
    let state = use_shared_state::<State>(cx)?;
    let initial_lang_value = state.read().settings.language.clone();
    let themes = get_available_themes();
    let theme = state
        .read()
        .ui
        .theme
        .as_ref()
        .map(|theme| theme.name.clone())
        .unwrap_or_default();

    let mut config = Configuration::load_or_default();
    if theme.is_empty() {
        state.write().mutate(Action::SetTheme(Theme::default()));
    }

    cx.render(rsx!(
        div {
            id: "settings-general",
            aria_label: "settings-general",
            SettingSection {
                section_label: get_local_text("settings-general.overlay"),
                section_description: get_local_text("settings-general.overlay-description"),
                Switch {
                    active: config.general.enable_overlay,
                    onflipped: move |e| {
                        config.set_overlay(e);
                        state.write().mutate(Action::SetOverlay(e));
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-general.splash-screen"),
                section_description: get_local_text("settings-general.splash-screen-description"),
                Switch {
                }
            },
            SettingSection {
                section_label: get_local_text("settings-general.theme"),
                section_description: get_local_text("settings-general.theme-description"),
                Select {
                    initial_value: state.read().ui.theme.clone().map(|t| t.name).unwrap_or("Default".into()),
                    options: themes.iter().map(|t| t.name.clone()).collect(),
                    onselect: move |value| {
                        themes.iter().for_each(|t| {
                            if t.name == value {
                                state.write().mutate(Action::SetTheme(t.clone()));
                            }
                        })
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-general.theme-reset"),
                section_description: get_local_text("settings-general.theme-reset-description"),
                Button {
                    text: get_local_text("settings-general.theme-reset-cta"),
                    aria_label: "clear-theme-button".into(),
                    icon: Icon::Trash,
                    appearance: kit::elements::Appearance::Secondary,
                    onpress: move |_| {
                        state.write().mutate(Action::ClearTheme);
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-general.app-language"),
                section_description: get_local_text("settings-general.change-language"),
                Select {
                    initial_value: initial_lang_value,
                    options: get_available_languages(),
                    onselect: move |value| {
                        let new_app_lang = change_language(value);
                        state.write().mutate(Action::SetLanguage(new_app_lang));
                    }
                }
            },
        }
    ))
}
