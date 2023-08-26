use common::state::State;
use dioxus::prelude::*;
use kit::components::{
    channel::{Channel, ChannelType},
    channel_group::{ChannelGroup, ChannelGroupElement},
};

#[allow(non_snake_case)]
pub fn SidebarInner(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;

    let mut channel_groups = Vec::new();
    channel_groups.push(ChannelGroup {
        name: "Group One".into(),
        channels: vec![Channel {
            id: "1".into(),
            name: "General".into(),
            kind: ChannelType::Text,
        }],
    });

    channel_groups.push(ChannelGroup {
        name: "Group Two".into(),
        channels: vec![
            Channel {
                id: "4".into(),
                name: "General".into(),
                kind: ChannelType::Text,
            },
            Channel {
                id: "2".into(),
                name: "Off Topic".into(),
                kind: ChannelType::Text,
            },
            Channel {
                id: "3".into(),
                name: "Pic Dump".into(),
                kind: ChannelType::Text,
            },
        ],
    });

    cx.render(rsx!(div {
        class: "community-sidebar-innner",
        channel_groups.iter().map(|group| {
            rsx!(ChannelGroupElement {
                group_name: group.name.clone(),
                channels: group.channels.clone(),
                onpress: move |_| {}
            })
        })
    }))
}
