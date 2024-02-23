#[allow(unused_imports)]
use std::collections::{BTreeMap, HashMap, HashSet};

use common::warp_runner::{RayGunCmd, WarpCmd};
use common::WARP_CMD_CH;
use dioxus::prelude::*;
use futures::channel::oneshot;
use futures::StreamExt;
use kit::elements::switch::Switch;
use warp::raygun::{ConversationSettings, GroupSettings};

use crate::components::settings::SettingSectionSimple;
use crate::layouts::chats::data::ChatData;

#[allow(non_snake_case)]
pub fn GroupSettings() -> Element {
    log::trace!("rendering edit_group");
    let chat_data = use_shared_state::<ChatData>(cx)?;

    #[derive(Debug)]
    enum GroupSettingsChange {
        MembersCanAddParticipants(bool),
        MembersCanChangeName(bool),
    }

    let group_settings_changed_channel =
        use_coroutine(cx, |mut rx: UnboundedReceiver<GroupSettingsChange>| {
            to_owned![chat_data];
            async move {
                let warp_cmd_tx = WARP_CMD_CH.tx.clone();
                while let Some(change) = rx.next().await {
                    let mut settings = match chat_data.read().active_chat.conversation_settings() {
                        ConversationSettings::Group(settings) => settings,
                        ConversationSettings::Direct(_) => {
                            log::warn!("Group conversation has direct conversation settings.");
                            return;
                        }
                    };

                    match change {
                        GroupSettingsChange::MembersCanAddParticipants(switch_state) => {
                            settings.set_members_can_add_participants(switch_state);
                        }
                        GroupSettingsChange::MembersCanChangeName(switch_state) => {
                            settings.set_members_can_change_name(switch_state);
                        }
                    }

                    let (tx, rx) = oneshot::channel();
                    let cmd = RayGunCmd::UpdateConversationSettings {
                        conv_id: chat_data.read().active_chat.id(),
                        settings: ConversationSettings::Group(settings),
                        rsp: tx,
                    };

                    if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(cmd)) {
                        log::error!("failed to send warp command: {}", e);
                    }
                    let _ = rx.await.expect("command canceled");
                }
            }
        });
    let get_group_settings = || match chat_data.read().active_chat.conversation_settings() {
        ConversationSettings::Group(settings) => settings,
        ConversationSettings::Direct(_) => {
            log::warn!("Group conversation has direct conversation settings.");
            GroupSettings::default()
        }
    };
    rsx!(
        div {
            id: "group-settings",
            aria_label: "group-settings",
            div {
                class: "settings",
                SettingSectionSimple {
                    aria_label: "allow-members-to-add-others".into(),
                    p {
                        "Allow anyone to add members"
                    }
                    Switch {
                        active: get_group_settings().members_can_add_participants(),
                        onflipped: |switch_state| {
                            group_settings_changed_channel.send(GroupSettingsChange::MembersCanAddParticipants(switch_state))
                        }
                    }
                },
                SettingSectionSimple {
                    aria_label: "allow-members-to-add-edit-name".into(),
                    p {
                        "Allow anyone to rename group"
                    }
                    Switch {
                        active: get_group_settings().members_can_change_name(),
                        onflipped: |switch_state| {
                            group_settings_changed_channel.send(GroupSettingsChange::MembersCanChangeName(switch_state))
                        }
                    }
                },
            }
        }
    ))
}
