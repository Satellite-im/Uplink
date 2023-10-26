use std::vec;

use common::icons::outline::Shape;
use common::language::get_local_text;
use common::warp_runner::{BlinkCmd, WarpCmd};
use dioxus::prelude::*;
use futures::{channel::oneshot, StreamExt};
use kit::elements::radio_list::RadioList;
use kit::elements::range::Range;
use kit::elements::select::Select;
use kit::elements::switch::Switch;
use warp::logging::tracing::log;

use crate::components::settings::{SettingSection, SettingSectionSimple};
use common::state::{action::ConfigAction, Action, State};
use common::{sounds, WARP_CMD_CH};

pub const VOL_MIN: f32 = 0.0;
pub const VOL_MAX: f32 = 200.0;

enum AudioCmd {
    FetchOutputDevices,
    SetOutputDevice(String),
    FetchInputDevices,
    SetInputDevice(String),
}

#[allow(non_snake_case)]
pub fn AudioSettings(cx: Scope) -> Element {
    log::trace!("Audio settings page rendered.");
    let state = use_shared_state::<State>(cx)?;
    let input_devices = use_ref(cx, Vec::new);
    let output_devices = use_ref(cx, Vec::new);

    let ch = use_coroutine(cx, |mut rx| {
        to_owned![state, input_devices, output_devices];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    AudioCmd::FetchInputDevices => {
                        let (tx, rx) = oneshot::channel();
                        if let Err(_e) = warp_cmd_tx
                            .send(WarpCmd::Blink(BlinkCmd::GetAllMicrophones { rsp: tx }))
                        {
                            log::error!("failed to send blink command");
                            continue;
                        }

                        let res = rx.await.expect("warp runner failed to get input devices");
                        match res {
                            Ok(res) => {
                                state.write_silent().settings.input_device = res.selected;
                                *input_devices.write() = res.available_devices;
                            }
                            Err(e) => {
                                log::error!("could not get input devices: {e}");
                            }
                        }
                    }
                    AudioCmd::FetchOutputDevices => {
                        let (tx, rx) = oneshot::channel();
                        if let Err(_e) =
                            warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::GetAllSpeakers { rsp: tx }))
                        {
                            log::error!("failed to send blink command");
                            continue;
                        }

                        let res = rx.await.expect("warp runner failed to get output devices");
                        match res {
                            Ok(res) => {
                                state.write_silent().settings.output_device = res.selected;
                                *output_devices.write() = res.available_devices;
                            }
                            Err(e) => {
                                log::error!("could not get output devices: {e}");
                            }
                        }
                    }
                    AudioCmd::SetInputDevice(device_name) => {
                        let device = device_name.clone();
                        let (tx, rx) = oneshot::channel();
                        if let Err(_e) = warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::SetMicrophone {
                            device_name,
                            rsp: tx,
                        })) {
                            log::error!("failed to send blink command");
                            continue;
                        }

                        match rx.await {
                            Ok(_) => {
                                state.write_silent().settings.input_device = Some(device);
                            }
                            Err(e) => {
                                log::error!("warp_runner failed to set input device: {e}");
                            }
                        }
                    }
                    AudioCmd::SetOutputDevice(device_name) => {
                        let device = device_name.clone();
                        let (tx, rx) = oneshot::channel();
                        if let Err(_e) = warp_cmd_tx.send(WarpCmd::Blink(BlinkCmd::SetSpeaker {
                            device_name,
                            rsp: tx,
                        })) {
                            log::error!("failed to send blink command");
                            continue;
                        }

                        match rx.await {
                            Ok(_) => {
                                state.write_silent().settings.output_device = Some(device);
                            }
                            Err(e) => {
                                log::error!("warp_runner failed to set output device: {e}");
                            }
                        }
                    }
                }
            }
        }
    });

    use_future(cx, (), |_| {
        to_owned![ch];
        async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                ch.send(AudioCmd::FetchInputDevices);
                ch.send(AudioCmd::FetchOutputDevices);
            }
        }
    });

    cx.render(rsx!(
        div {
            id: "settings-audio",
            aria_label: "settings-audio",
            SettingSection {
                section_label: get_local_text("settings-audio.input-device"),
                section_description: get_local_text("settings-audio.input-device-description"),
                no_border: true,
                Select {
                    initial_value: state.read().settings.input_device.as_ref().cloned().unwrap_or("default".into()),
                    options: input_devices.read().clone(),
                    onselect: move |device| {
                        ch.send(AudioCmd::SetInputDevice(device))
                    }
                },
            },
            SettingSectionSimple {
                Range {
                    aria_label: "range-input-device".into(),
                    initial_value: 100.0,
                    min: VOL_MIN,
                    max: VOL_MAX,
                    icon_left: Shape::Microphone,
                    icon_right: Shape::MicrophoneWave,
                    disabled: true,
                    onchange: move |_| {}
                }
            }
            SettingSection {
                section_label: get_local_text("settings-audio.output-device"),
                section_description: get_local_text("settings-audio.output-device-description"),
                no_border: true,
                Select {
                    initial_value: state.read().settings.output_device.as_ref().cloned().unwrap_or("default".into()),
                    options: output_devices.read().clone(),
                    onselect: move |device| {
                        ch.send(AudioCmd::SetOutputDevice(device))
                    }
                },
            },
            SettingSectionSimple {
                Range {
                    aria_label: "range-output-device".into(),
                    initial_value: 100.0,
                    min: VOL_MIN,
                    max: VOL_MAX,
                    icon_left: Shape::Speaker,
                    icon_right: Shape::SpeakerWave,
                    disabled: true,
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
