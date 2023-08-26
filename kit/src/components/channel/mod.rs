use dioxus::prelude::*;

use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;

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
    Feed,
    Robot,
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
    cx.render(rsx!(
        div {
            class: "channel",
            onclick: |_| {
                cx.props.onpress.call(cx.props.channel.clone());
            },
            match &cx.props.channel.kind {
                ChannelType::Text => rsx!(IconElement {
                    icon: Icon::ChatBubbleBottomCenterText
                }),
                ChannelType::Robot => rsx!(IconElement {
                    icon: Icon::CommandLine
                }),
                ChannelType::Feed => rsx!(IconElement {
                    icon: Icon::Rss
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

            },
        }
    ))
}
