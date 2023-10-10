use dioxus::prelude::*;

use common::icons::Icon as IconElement;
use common::{icons::outline::Shape as Icon, state::State};

use crate::components::context_menu::{ContextItem, ContextMenu};

#[derive(Clone)]
pub struct VoiceChannelUser {
    pub talking: bool,
    pub muted: bool,
    pub deafened: bool,
    pub name: String,
    pub avatar: String,
}

#[derive(Clone)]
pub enum ChannelType {
    Text,
    Announcements,
    Robot,
    SharedFolder,
    Voice(Vec<VoiceChannelUser>),
}

#[derive(Clone)]
pub struct Channel {
    pub id: String,
    pub name: String,
    pub kind: ChannelType,
}

#[derive(Props)]
pub struct Props<'a> {
    channel: Channel,
    onpress: EventHandler<'a, Channel>,
}

#[allow(non_snake_case)]
pub fn ChannelElement<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;

    cx.render(rsx!(
        ContextMenu {
            id: format!("{}-channel", cx.props.channel.id),
            key: "{cx.props.channel.id}-channel",
            devmode: state.read().configuration.developer.developer_mode,
            items: cx.render(rsx!(
                ContextItem {
                    icon: Icon::PencilSquare,
                    text: "Rename".into(),
                    onpress: move |_| {}
                },
                ContextItem {
                    icon: Icon::ShieldCheck,
                    text: "Permissions".into(),
                    onpress: move |_| {}
                },
                ContextItem {
                    danger: true,
                    icon: Icon::XMark,
                    text: "Delete".into(),
                    onpress: move |_| {}
                },
            )),
            div {
                class: "channel",
                onclick: |_| {
                    cx.props.onpress.call(cx.props.channel.clone());
                },
                match &cx.props.channel.kind {
                    ChannelType::Text => rsx!(IconElement {
                        icon: Icon::ChatBubbleBottomCenterText
                    }),
                    ChannelType::SharedFolder => rsx!(IconElement {
                        icon: Icon::Folder
                    }),
                    ChannelType::Robot => rsx!(IconElement {
                        icon: Icon::CommandLine
                    }),
                    ChannelType::Announcements => rsx!(IconElement {
                        icon: Icon::InformationCircle
                    }),
                    ChannelType::Voice(_) => rsx!(IconElement {
                        icon: Icon::Speaker
                    }),
                },
                div {
                    class: "channel-info",
                    match &cx.props.channel.kind {
                        ChannelType::Voice(_) => rsx!(
                            div {
                                class: "channel-type-voice",
                                p {
                                    class: "channel-name",
                                    cx.props.channel.name.clone()
                                }
                            }
                        ),
                        _ => rsx!(
                            div {
                                class: "channel-type-text",
                                p {
                                    class: "channel-name",
                                    cx.props.channel.name.clone()
                                }
                            }
                        ),
                    }
                }
            }
        }
    ))
}
