use common::language::get_local_text;
use dioxus::prelude::*;
use kit::elements::switch::Switch;
use warp::logging::tracing::log;

use crate::components::settings::SettingSection;
use common::sounds;
use common::state::{action::ConfigAction, Action, State};

#[allow(non_snake_case)]
pub fn AudioSettings(cx: Scope) -> Element {
    log::trace!("Audio settings page rendered.");
    let state = use_shared_state::<State>(cx)?;

    cx.render(rsx!(
        div {
            id: "settings-audio",
            aria_label: "settings-audio",
            SettingSection {
                section_label: get_local_text("settings-audio.interface-sounds"),
                section_description: get_local_text("settings-audio.interface-sounds-description"),
                Switch {
                    active: state.read().configuration.audiovideo.interface_sounds,
                    onflipped: move |e| {
                        if state.read().configuration.audiovideo.interface_sounds {
                            sounds::Play(sounds::Sounds::Flip);
                        }
                        state.write().mutate(Action::Config(ConfigAction::SetInterfaceSoundsEnabled(e)));
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-audio.media-sounds"),
                section_description: get_local_text("settings-audio.media-sounds-description"),
                Switch {
                    active: state.read().configuration.audiovideo.media_sounds,
                    onflipped: move |e| {
                        if state.read().configuration.audiovideo.interface_sounds {
                           sounds::Play(sounds::Sounds::Flip);
                        }
                        state.write().mutate(Action::Config(ConfigAction::SetMediaSoundsEnabled(e)));
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-audio.message-sounds"),
                section_description: get_local_text("settings-audio.message-sounds-description"),
                Switch {
                    active: state.read().configuration.audiovideo.message_sounds,
                    onflipped: move |e| {
                        if state.read().configuration.audiovideo.interface_sounds {
                            sounds::Play(sounds::Sounds::Flip);
                        }
                        state.write().mutate(Action::Config(ConfigAction::SetMessageSoundsEnabled(e)));
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-audio.call-timer"),
                section_description: get_local_text("settings-audio.call-timer-description"),
                Switch {}
            }
        }
    ))
}
