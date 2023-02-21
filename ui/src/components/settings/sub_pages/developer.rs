use dioxus::prelude::*;

use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::{
    notifications::push_notification,
    sounds::{self, Sounds},
    state::{action::ConfigAction, notifications::NotificationKind, Action, State},
    STATIC_ARGS,
};
use kit::elements::{button::Button, switch::Switch, Appearance};
use warp::logging::tracing::log;

use crate::{
    components::settings::SettingSection,
    logger,
    window_manager::{WindowManagerCmd, WindowManagerCmdTx},
};

#[allow(non_snake_case)]
pub fn DeveloperSettings(cx: Scope) -> Element {
    log::debug!("Developer settings page rendered.");
    let state = use_shared_state::<State>(cx)?;

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
                section_label: get_local_text("settings-developer.open-codebase"),
                section_description: get_local_text("settings-developer.open-codebase-description"),
                Button {
                    text: get_local_text("settings-developer.open-codebase"),
                    aria_label: "open-codebase-button".into(),
                    appearance: Appearance::Secondary,
                    icon: Icon::CodeBracketSquare,
                    onpress: |_| {
                        let _ = open::that("https://github.com/Satellite-im/Uplink");
                    }
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

pub struct WindowDropHandler {
    cmd_tx: WindowManagerCmdTx,
}

impl PartialEq for WindowDropHandler {
    fn eq(&self, _other: &Self) -> bool {
        false
    }
}

impl WindowDropHandler {
    pub fn new(cmd_tx: WindowManagerCmdTx) -> Self {
        Self { cmd_tx }
    }
}

impl Drop for WindowDropHandler {
    fn drop(&mut self) {
        if let Err(e) = self.cmd_tx.send(WindowManagerCmd::CloseDebugLogger) {
            log::warn!("WindowDropHandler failed to send msg: {}", e);
        }
    }
}
