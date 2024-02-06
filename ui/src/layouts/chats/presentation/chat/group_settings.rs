#[allow(unused_imports)]
use std::collections::{BTreeMap, HashMap, HashSet};

use common::warp_runner::{RayGunCmd, WarpCmd};
use common::WARP_CMD_CH;
use dioxus::prelude::*;
use futures::channel::oneshot;
use futures::StreamExt;
use kit::elements::switch::Switch;
use warp::raygun::ConversationSettings;

use crate::components::settings::SettingSectionSimple;
use crate::layouts::chats::data::ChatData;

#[allow(non_snake_case)]
pub fn GroupSettings(cx: Scope) -> Element {
    log::trace!("rendering edit_group");
    let chat_data = use_shared_state::<ChatData>(cx)?;

    let group_settings_changed_channel = use_coroutine(cx, |mut rx: UnboundedReceiver<bool>| {
        to_owned![chat_data];
        async move {
            let warp_cmd_tx = WARP_CMD_CH.tx.clone();
            while let Some(switch_state) = rx.next().await {
                let data = chat_data.read();
                let active = &data.active_chat;
                let mut settings = match active.conversation_settings() {
                    ConversationSettings::Group(settings) => settings,
                    ConversationSettings::Direct(__) => {
                        log::warn!("Group conversation has direct conversation settings.");
                        return;
                    }
                };

                settings.set_members_can_add_participants(switch_state);

                let (tx, rx) = oneshot::channel();
                let cmd = RayGunCmd::UpdateConversationSettings {
                    conv_id: active.id(),
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
    cx.render(rsx!(
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
                        active: match chat_data.read().active_chat.conversation_settings() {
                            ConversationSettings::Group(settings) => {
                                settings
                                    .members_can_add_participants()
                            }
                            ConversationSettings::Direct(_) => {
                                log::warn!("Group conversation has direct conversation settings.");
                                false
                            }
                        },
                        onflipped: |switch_state| group_settings_changed_channel.send(switch_state)
                    }
                },
                SettingSectionSimple {
                    aria_label: "allow-members-to-add-edit-name".into(),
                    p {
                        "Allow anyone to rename group"
                    }
                    Switch {
                        onflipped: |state| {
                            log::info!("switch flipped: {}", state);
                        }
                    }
                },
            }
        }
    ))
}
