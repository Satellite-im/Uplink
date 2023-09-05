use dioxus::prelude::*;

use crate::components::channel::ChannelElement;

use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;

use super::channel::Channel;

pub struct ChannelGroup {
    pub name: String,
    pub channels: Vec<Channel>,
}

#[derive(Props)]
pub struct Props<'a> {
    group_name: String,
    channels: Vec<Channel>,
    onpress: EventHandler<'a, &'a Channel>,
}

#[allow(non_snake_case)]
pub fn ChannelGroupElement<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(
        div {
            class: "channel-group",
            div {
                class: "channel-group-header",
                cx.props.group_name.clone(),
                div {
                    class: "controls",
                    IconElement {
                        icon: Icon::Plus
                    },
                    IconElement {
                        icon: Icon::ChevronDown
                    }
                }
            },
            div {
                class: "channel-group-body",
                cx.props.channels.iter().map(|channel| {
                    rsx!(
                        ChannelElement {
                            channel: channel.clone(),
                            onpress: move |_| {
                                cx.props.onpress.call(channel);
                            }
                        }
                    )
                })
            }
        }
    ))
}
