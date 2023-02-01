use dioxus::prelude::*;
use kit::{
    elements::{button::Button, switch::Switch},
    icons::Icon,
};
use shared::language::get_local_text;

use crate::{components::settings::SettingSection, state::State};

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
                    text: get_local_text("settings-notifications.grant-permissions"),
                    icon: Icon::Shield,
                    onpress: move |_| {
                        // TODO: Grant permissions this should prompt the user to grant permissions for their system
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("friends"),
                section_description: get_local_text("settings-notifications.friends-description"),
                Switch { 
                    active: state.read().configuration.config.notifications.friends_notifications,
                    onflipped: move |e| {
                        state.write().configuration.set_friends_notifications(e);
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("messages"),
                section_description: get_local_text("settings-notifications.messages-description"),
                Switch { 
                    active: state.read().configuration.config.notifications.messages_notifications,
                    onflipped: move |e| {
                        state.write().configuration.set_messages_notifications(e);
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings"),
                section_description: get_local_text("settings-notifications.settings-description"),
                Switch { 
                    active: state.read().configuration.config.notifications.settings_notifications,
                    onflipped: move |e| {
                        state.write().configuration.set_settings_notifications(e);
                    }
                }
            },
        }
    ))
}
