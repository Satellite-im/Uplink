use dioxus::prelude::*;
use kit::components::{
    channel::{Channel, ChannelType},
    channel_group::{ChannelGroup, ChannelGroupElement},
};

#[allow(non_snake_case)]
pub fn SidebarInner() -> Element {
    let mut channel_groups = Vec::new();
    channel_groups.push(ChannelGroup {
        name: "Group One".into(),
        channels: vec![
            Channel {
                id: "1".into(),
                name: "General".into(),
                kind: ChannelType::Text,
            },
            Channel {
                id: "2".into(),
                name: "Robot Vomit".into(),
                kind: ChannelType::Robot,
            },
            Channel {
                id: "3".into(),
                name: "Announcements".into(),
                kind: ChannelType::Announcements,
            },
            Channel {
                id: "8".into(),
                name: "Shared Folder".into(),
                kind: ChannelType::SharedFolder,
            },
            Channel {
                id: "8".into(),
                name: "Wiki / Docs".into(),
                kind: ChannelType::Docs,
            },
        ],
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
                id: "5".into(),
                name: "Off Topic".into(),
                kind: ChannelType::Text,
            },
            Channel {
                id: "6".into(),
                name: "Pic Dump".into(),
                kind: ChannelType::Photo,
            },
        ],
    });

    rsx!(div {
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
