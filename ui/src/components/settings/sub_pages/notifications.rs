use common::language::get_local_text;
use dioxus::prelude::*;
use kit::elements::{button::Button, switch::Switch};

use common::icons::outline::Shape as Icon;
use common::sounds;
use common::state::{action::ConfigAction, Action, State};

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn NotificationSettings(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;

    cx.render(rsx!(
        div {
            id: "settings-notifications",
            aria_label: "settings-notifications",
            SettingSection {
                section_label: get_local_text("settings-notifications.grant-permissions"),
                section_description: get_local_text("settings-notifications.grant-permissions-description"),
                Button {
                    aria_label: "grant-permissions-button".into(),
                    text: get_local_text("settings-notifications.grant-permissions"),
                    icon: Icon::Shield,
                    onpress: move |_| {
                        // TODO: Grant permissions this should prompt the user to grant permissions for their system
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings-notifications.enabled"),
                section_description: get_local_text("settings-notifications.enabled-description"),
                Switch {
                    active: state.read().configuration.notifications.enabled,
                    onflipped: move |e| {
                        if state.read().configuration.audiovideo.interface_sounds {
                            sounds::Play(sounds::Sounds::Flip);
                        }
                        state.write().mutate(Action::Config(ConfigAction::SetNotificationsEnabled(e)));
                    }
                }
            },
            div {
                class: format_args!("{}", if state.read().configuration.notifications.enabled { "enabled" } else { "disabled" }),
                SettingSection {
                    section_label: get_local_text("friends"),
                    section_description: get_local_text("settings-notifications.friends-description"),
                    Switch {
                        active: state.read().configuration.notifications.enabled && state.read().configuration.notifications.friends_notifications,
                        disabled: !state.read().configuration.notifications.enabled,
                        onflipped: move |e| {
                            if state.read().configuration.audiovideo.interface_sounds {
                               sounds::Play(sounds::Sounds::Flip);
                            }
                            state.write().mutate(Action::Config(ConfigAction::SetFriendsNotificationsEnabled(e)));
                        }
                    }
                },
                SettingSection {
                    section_label: get_local_text("messages"),
                    section_description: get_local_text("settings-notifications.messages-description"),
                    Switch {
                        active: state.read().configuration.notifications.enabled && state.read().configuration.notifications.messages_notifications,
                        disabled: !state.read().configuration.notifications.enabled,
                        onflipped: move |e| {
                            if state.read().configuration.audiovideo.interface_sounds {
                                sounds::Play(sounds::Sounds::Flip);
                            }
                            state.write().mutate(Action::Config(ConfigAction::SetMessagesNotificationsEnabled(e)));
                        }
                    }
                },
                SettingSection {
                    section_label: get_local_text("settings"),
                    section_description: get_local_text("settings-notifications.settings-description"),
                    Switch {
                        active: state.read().configuration.notifications.enabled && state.read().configuration.notifications.settings_notifications,
                        disabled: !state.read().configuration.notifications.enabled,
                        onflipped: move |e| {
                            if state.read().configuration.audiovideo.interface_sounds {
                                sounds::Play(sounds::Sounds::Flip);
                            }
                            state.write().mutate(Action::Config(ConfigAction::SetSettingsNotificationsEnabled(e)));
                        }
                    }
                },
            }
        }
    ))
}
