use common::language::{change_language, get_available_languages, get_local_text};
use common::state::{action::ConfigAction, Action, State};
use dioxus::prelude::*;
use kit::components::slide_selector::SlideSelector;
use kit::elements::{select::Select, switch::Switch};
use warp::logging::tracing::log;

use crate::utils::get_available_fonts;
use crate::{components::settings::SettingSection, utils::get_available_themes};

#[allow(non_snake_case)]
pub fn GeneralSettings(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let initial_lang_value = state.read().settings.language.clone();
    let themes = get_available_themes();
    let fonts = get_available_fonts();

    log::trace!("General settings page rendered.");

    cx.render(rsx!(
        div {
            id: "settings-general",
            aria_label: "settings-general",
            SettingSection {
                section_label: get_local_text("settings-general.overlay"),
                section_description: get_local_text("settings-general.overlay-description"),
                Switch {
                    active: state.read().configuration.general.enable_overlay,
                    onflipped: move |e| {
                        state.write().mutate(Action::Config(ConfigAction::SetOverlayEnabled(e)));
                        state.write().mutate(Action::SetOverlay(e));
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-general.theme"),
                section_description: get_local_text("settings-general.theme-description"),
                Select {
                    initial_value: if let Some(theme) = &state.read().ui.theme {
                        theme.name.clone()
                    } else {
                        "Default".into()
                    },
                    options: themes.iter().map(|t| t.name.clone()).collect(),
                    onselect: move |value| {
                        themes.iter().for_each(|t| {
                            if t.name == value {
                                state.write().mutate(Action::SetTheme(Some(t.clone())));
                            }
                        })
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-general.font"),
                section_description: get_local_text("settings-general.font-description"),
                Select {
                    initial_value: if let Some(font) = &state.read().ui.font {
                        font.name.clone()
                    } else {
                        "Default".into()
                    },
                    options: fonts.iter().map(|font| font.name.clone()).collect(),
                    onselect: move |value| {
                        fonts.iter().for_each(|font| {
                            if font.name.clone() == value {
                                state.write().mutate(Action::SetFont(Some(font.to_owned())));
                            }
                        })
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-general.font-scaling"),
                section_description: get_local_text("settings-general.font-scaling-description"),
                SlideSelector {
                    values: vec![0.5, 0.75, 1.0, 1.25, 1.5, 1.75],
                    inital_index: 2, // represents 1.0 in the possible values.
                    onset: move |value| {
                        state.write().mutate(Action::SetFontScale( value ));
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
