use std::process::Command;

use common::language::get_local_text;
use common::state::{Action, ToastNotification};
use common::{icons::outline::Shape as Icon, state::State};
use dioxus::prelude::*;
use dioxus_desktop::use_window;
use futures::StreamExt;
use kit::elements::{button::Button, Appearance};

use warp::logging::tracing::log;

use crate::get_download_modal;
use crate::utils::auto_updater::{DownloadProgress, DownloadState, SoftwareDownloadCmd};
use crate::{
    components::settings::SettingSection,
    utils::{self, auto_updater::GitHubRelease},
};

#[allow(non_snake_case)]
pub fn AboutPage(cx: Scope) -> Element {
    let version = env!("CARGO_PKG_VERSION");
    let app_name = env!("CARGO_PKG_NAME");
    let state = use_shared_state::<State>(cx)?;
    let download_state = use_shared_state::<DownloadState>(cx)?;
    let update_button_loading = use_state(cx, || false);
    let download_available: &UseState<Option<GitHubRelease>> = use_state(cx, || None);
    let desktop = use_window(cx);

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<()>| {
        to_owned![download_available, update_button_loading, state];
        async move {
            while rx.next().await.is_some() {
                match utils::auto_updater::check_for_release().await {
                    Ok(opt) => {
                        if opt.is_none() {
                            state.write().mutate(Action::AddToastNotification(
                                ToastNotification::init(
                                    "".into(),
                                    get_local_text("settings-about.no-update-available"),
                                    None,
                                    2,
                                ),
                            ))
                        }
                        download_available.set(opt);
                    }
                    Err(e) => {
                        let opt_err: Option<&reqwest::Error> = e.downcast_ref();
                        let msg = match opt_err {
                            Some(e) => {
                                // Most common ones. Else display a generic error message
                                if e.is_timeout() {
                                    "settings-about.update-check-error-timeout"
                                } else if e.is_request() {
                                    "settings-about.update-check-error-request"
                                } else {
                                    "settings-about.update-check-error"
                                }
                            }
                            None => "settings-about.update-check-error",
                        };
                        state.write().mutate(Action::AddToastNotification(
                            ToastNotification::init("".into(), get_local_text(msg), None, 4),
                        ));
                        log::error!("failed to check for updates: {e}");
                    }
                }
                update_button_loading.set(false);
            }
        }
    });

    let _download_ch = use_coroutine_handle::<SoftwareDownloadCmd>(cx)?;

    let opt = download_available.get().clone();
    let stage = download_state.read().stage;
    let pending_key = format!("btn-pending{}", download_state.read().progress);

    let about_button = cx.render(rsx!(match opt {
        None if stage == DownloadProgress::Idle => {
            rsx!(Button {
                key: "btn-start",
                text: get_local_text("uplink.check-for-updates"),
                loading: *update_button_loading.current(),
                aria_label: "check-for-updates-button".into(),
                appearance: Appearance::Secondary,
                icon: Icon::ArrowPath,
                onpress: |_| {
                    download_available.set(None);
                    update_button_loading.set(true);
                    ch.send(());
                }
            })
        }
        _ => match stage {
            DownloadProgress::Idle => {
                rsx!(Button {
                    key: "btn-idle",
                    text: get_local_text("uplink.download-update"),
                    loading: *update_button_loading.current(),
                    aria_label: "check-for-updates-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::ArrowDown,
                    onpress: move |_| {
                        download_state.write().stage = DownloadProgress::PickFolder;
                    }
                })
            }
            DownloadProgress::PickFolder => rsx!(get_download_modal {
                on_dismiss: move |_| {
                    download_state.write().stage = DownloadProgress::Idle;
                },
                // is never used
                // on_submit: move |dest: PathBuf| {
                //     download_state.write().stage = DownloadProgress::Pending;
                //     download_state.write().destination = Some(dest.clone());
                //     download_ch.send(SoftwareDownloadCmd(dest));
                // }
            }),
            DownloadProgress::_Pending => {
                rsx!(Button {
                    key: "{pending_key}",
                    text: format!("{}%", download_state.read().progress as u32),
                    loading: true,
                    aria_label: "check-for-updates-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::ArrowDown,
                })
            }
            DownloadProgress::Finished => {
                rsx!(Button {
                    key: "btn-finished",
                    text: get_local_text("uplink.update-menu-install"),
                    loading: *update_button_loading.current(),
                    aria_label: "check-for-updates-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::ArrowDown,
                    onpress: move |_| {
                        // be sure to update this before closing the app
                        state.write().mutate(Action::DismissUpdate);
                        if let Some(dest) = download_state.read().destination.clone() {
                            std::thread::spawn(move || {
                                let cmd = if cfg!(target_os = "windows") {
                                    "explorer"
                                } else if cfg!(target_os = "linux") {
                                    "xdg-open"
                                } else if cfg!(target_os = "macos") {
                                    "open"
                                } else {
                                    eprintln!("unknown OS type. failed to open files browser");
                                    return;
                                };
                                Command::new(cmd).arg(dest).spawn().unwrap();
                            });
                            desktop.close();
                        } else {
                            log::error!("attempted to download update without download location");
                        }
                        download_state.write().destination = None;
                        download_state.write().stage = DownloadProgress::Idle;
                    }
                })
            }
        },
    }));

    cx.render(rsx!(
        div {
            id: "settings-about",
            SettingSection {
                section_label: get_local_text("settings-about.info"),
                section_description: app_name.into(),
            },
            SettingSection {
                section_label:  get_local_text("settings-about.version"),
                section_description: version.into(),
                div {
                    about_button
                }
            },
            SettingSection {
                section_label: get_local_text("settings-about.open-website"),
                section_description: get_local_text("settings-about.open-website-description"),
                Button {
                    text: get_local_text("settings-about.open-website"),
                    aria_label: "open-website-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::GlobeAlt,
                    onpress: |_| {
                        let _ = open::that("https://satellite.im");
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-about.open-codebase"),
                section_description: get_local_text("settings-about.open-codebase-description"),
                Button {
                    text: get_local_text("settings-about.open-codebase"),
                    aria_label: "open-codebase-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::CodeBracketSquare,
                    onpress: |_| {
                        let _ = open::that("https://github.com/Satellite-im/Uplink");
                    }
                }
            },
        }
    ))
}
