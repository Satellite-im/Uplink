use dioxus::prelude::*;
use kit::{
    elements::{button::Button, switch::Switch},
    icons::Icon,
};
use shared::language::get_local_text;

use crate::{components::settings::SettingSection, config::Configuration};

#[allow(non_snake_case)]
pub fn NotificationSettings(cx: Scope) -> Element {
    let config = Configuration::load_or_default();
    let (
        mut friends_switch_ref, 
        mut messages_switch_ref, 
        mut settings_switch_ref
    ) = (config.clone(), config.clone(), config.clone());

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
                    active: config.notifications.friends_notifications,
                    onflipped: move |e| {
                        friends_switch_ref.set_friends_notifications(e);
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("messages"),
                section_description: get_local_text("settings-notifications.messages-description"),
                Switch { 
                    active: config.notifications.messages_notifications,
                    onflipped: move |e| {
                        messages_switch_ref.set_messages_notifications(e);
                    }
                }
            },
            SettingSection {
                section_label: get_local_text("settings"),
                section_description: get_local_text("settings-notifications.settings-description"),
                Switch { 
                    active: config.notifications.settings_notifications,
                    onflipped: move |e| {
                        settings_switch_ref.set_settings_notifications(e);
                    }
                }
            },
        }
    ))
}
