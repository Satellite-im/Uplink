use std::path::PathBuf;

use common::warp_runner::{OtherCmd, WarpCmd};
use common::WARP_CMD_CH;
use dioxus::prelude::*;

use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::{
    notifications::push_notification,
    sounds::{self, Sounds},
    state::{action::ConfigAction, notifications::NotificationKind, Action, State},
    STATIC_ARGS,
};
use futures::channel::oneshot;
use futures::StreamExt;
use kit::elements::{button::Button, switch::Switch, Appearance};
use rfd::FileDialog;
use warp::logging::tracing::log;

use crate::{components::settings::SettingSection, logger};

#[allow(non_snake_case)]
pub fn DeveloperSettings(cx: Scope) -> Element {
    log::trace!("Developer settings page rendered.");
    let state = use_shared_state::<State>(cx)?;

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<PathBuf>| {
        //to_owned![];
        async move {
            while let Some(cmd) = rx.next().await {
                let dest = cmd.join("uplink.zip");
                let warp_cmd_tx = WARP_CMD_CH.tx.clone();
                let (tx, rx) = oneshot::channel::<Result<(), warp::error::Error>>();
                let compress_cmd = OtherCmd::CompressFolder {
                    src: STATIC_ARGS.uplink_path.clone(),
                    dest,
                    rsp: tx,
                };

                if let Err(e) = warp_cmd_tx.send(WarpCmd::Other(compress_cmd)) {
                    log::error!("failed to send warp command: {}", e);
                    continue;
                }

                let res = rx.await.expect("command canceled");
                match res {
                    Ok(_) => {
                        log::debug!("cache export complete");
                    }
                    Err(e) => {
                        log::error!("failed to download cache: {e}");
                    }
                };
            }
        }
    });

    cx.render(rsx!(
        div {
            id: "settings-developer",
            aria_label: "settings-developer",
            SettingSection {
                section_label: get_local_text("settings-developer.developer-mode"),
                section_description: get_local_text("settings-developer.developer-mode-description"),
                Switch {
                    active: state.read().configuration.developer.developer_mode,
                    onflipped: move |value| {
                        if state.read().configuration.audiovideo.interface_sounds {
                            sounds::Play(sounds::Sounds::Flip);
                        }

                        state.write().mutate(Action::Config(ConfigAction::SetDevModeEnabled(value)));
                    },
                }
            },
            SettingSection {
                section_label: "Test Notification".into(),
                section_description: "Sends a test notification.".into(),
                Button {
                    text: "Test Notifications".into(),
                    aria_label: "test-notification-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::BellAlert,
                    onpress: move |_| {
                        push_notification(
                            "Test".to_string(),
                            "Test".to_string(),
                            Some(Sounds::General),
                            notify_rust::Timeout::Milliseconds(4),
                        );
                        state
                            .write()
                            .mutate(Action::AddNotification(NotificationKind::Settings, 1));
                        }
                    }
            },
            SettingSection {
                section_label: get_local_text("settings-developer.open-cache"),
                section_description: get_local_text("settings-developer.open-cache-description"),
                Button {
                    text: get_local_text("settings-developer.open-cache-folder"),
                    aria_label: "open-cache-folder-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::FolderOpen,
                    onpress: |_| {
                        let _ = opener::open(&STATIC_ARGS.uplink_path);
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-developer.compress-download-cache"),
                section_description: get_local_text("settings-developer.compress-download-cache-description"),
                Button {
                    text: get_local_text("settings-developer.compress"),
                    aria_label: "compress-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::ArchiveBoxArrowDown,
                    onpress: |_| {
                        if let Some(path) =  FileDialog::new().set_directory(dirs::home_dir().unwrap_or(".".into())).pick_folder() {
                            ch.send(path);
                        };
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-developer.print-state"),
                section_description: get_local_text("settings-developer.print-state-description"),
                Button {
                    text: get_local_text("settings-developer.print-state"),
                    aria_label: "print-state-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::DocumentChartBar,
                    onpress: move |_| {
                        log::debug!("{:#?}", state.read());
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-developer.clear-cache"),
                section_description: get_local_text("settings-developer.clear-cache-description"),
                Button {
                    text: get_local_text("settings-developer.clear"),
                    aria_label: "clear-button".into(),
                    appearance: Appearance::Danger,
                    icon: Icon::Trash,
                    onpress: move |_| {
                        state.write().clear();
                    }
                }
            }
            SettingSection {
                section_label: get_local_text("settings-developer.save-logs-to-file"),
                section_description: get_local_text("settings-developer.save-logs-to-file-description"),
                Switch {
                    active: logger::get_save_to_file(),
                    onflipped: move |value| {
                        if state.read().configuration.audiovideo.interface_sounds {
                            sounds::Play(sounds::Sounds::Flip);
                        }
                        logger::set_save_to_file(value);
                    },
                }
            }
        }
    ))
}
