use std::vec;

use common::icons::outline::Shape;
use common::language::get_local_text;
use dioxus::prelude::*;
use kit::elements::radio_list::RadioList;
use kit::elements::range::Range;
use kit::elements::select::Select;
use kit::elements::switch::Switch;
use warp::logging::tracing::log;

use crate::components::settings::{SettingSection, SettingSectionSimple};
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
                section_label: get_local_text("settings-audio.input-device"),
                section_description: get_local_text("settings-audio.input-device-description"),
                no_border: true,
                Select {
                    initial_value: "Default".into(),
                    options: vec!["Default".into()],
                    onselect: move |_| {}
                },
            },
            SettingSectionSimple {
                Range {
                    initial_value: 100.0,
                    min: 0.0,
                    max: 200.0,
                    icon_left: Shape::Microphone,
                    icon_right: Shape::MicrophoneWave,
                    onchange: move |_| {}
                }
            }
            SettingSection {
                section_label: get_local_text("settings-audio.output-device"),
                section_description: get_local_text("settings-audio.output-device-description"),
                no_border: true,
                Select {
                    initial_value: "Default".into(),
                    options: vec!["Default".into()],
                    onselect: move |_| {}
                },
            },
            SettingSectionSimple {
                Range {
                    initial_value: 100.0,
                    min: 0.0,
                    max: 200.0,
                    icon_left: Shape::Speaker,
                    icon_right: Shape::SpeakerWave,
                    onchange: move |_| {}
                }
            }

            SettingSection {
                section_label: get_local_text("settings-audio.sample-rate"),
                section_description: get_local_text("settings-audio.sample-rate-description"),
                Select {
                    initial_value: "48000 Hz".into(),
                    options: vec!["24000 Hz".into(), "48000 Hz".into(), "96000 Hz".into()],
                    onselect: move |_| {}
                },
            },

            SettingSection {
                section_label: get_local_text("settings-audio.noise-suppression"),
                section_description: get_local_text("settings-audio.noise-suppression-description"),
                no_border: true,
            },
            SettingSectionSimple {
                RadioList {
                    initial_value: "None".into(),
                    values: vec!["None".into(), "Low".into(), "Medium".into(), "High".into()],
                    onchange: move |_| {}
                },
            }

            SettingSection {
                section_label: get_local_text("settings-audio.echo-cancellation"),
                section_description: get_local_text("settings-audio.echo-cancellation-description"),
                no_border: true,
            },
            SettingSectionSimple {
                RadioList {
                    initial_value: "None".into(),
                    values: vec!["None".into(), "Low".into(), "Medium".into(), "High".into()],
                    onchange: move |_| {}
                },
            }

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
