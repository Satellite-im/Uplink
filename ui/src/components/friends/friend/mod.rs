use dioxus::prelude::*;
use kit::{
    elements::{
        button::Button,
        label::Label,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    icons::Icon,
};

use crate::{
    utils::language::get_local_text,
};

#[derive(Debug, Clone)]
pub struct Relationship {
    pub friends: bool,
    pub received_friend_request: bool,
    pub sent_friend_request: bool,
    pub blocked: bool,
}

#[derive(Props)]
pub struct Props<'a> {
    // The username of the friend request sender
    username: String,
    // A suffix to the username, typically a unique identifier
    suffix: String,
    // Users relationship 
    relationship: Relationship,
    // Status message from friend
    status_message: String,
    // The user image element to display
    user_image: Element<'a>,
    // An optional event handler for the "onchat" event
    #[props(optional)]
    onchat: Option<EventHandler<'a>>,
    // An optional event handler for the "onremove" event
    #[props(optional)]
    onremove: Option<EventHandler<'a>>,
    #[props(optional)]
    onaccept: Option<EventHandler<'a>>,
    // An optional event handler for the "onblock" event
    #[props(optional)]
    onblock: Option<EventHandler<'a>>,
 
}

#[allow(non_snake_case)]
pub fn Friend<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let relationship = cx.props.relationship.clone();
    let status_message = cx.props.status_message.clone();

    cx.render(rsx!(
        div {
            class: "friend",
            &cx.props.user_image,
            div {
                class: "request-info",
                p {
                    "{cx.props.username}",
                    span {
                        "#{cx.props.suffix}"
                    }
                },
                if relationship.friends || relationship.blocked {
                   rsx!(Label {
                        // TODO: this is stubbed for now, wire up to the actual request time
                        // TODO: Do this translate later 
                        text: status_message,
                    })
                } else if relationship.sent_friend_request {
                    rsx!(Label {
                        // TODO: this is stubbed for now, wire up to the actual request time
                        // TODO: Do this translate later 
                        text: "Sent 4 days ago.".into()
                    })
                } else {
                    rsx!(Label {
                        // TODO: this is stubbed for now, wire up to the actual request time
                        // TODO: Do this translate later 
                        text: "Requested 4 days ago.".into()
                    })
                }
            },
            div {
                class: "request-controls",
                cx.props.onaccept.is_some().then(|| rsx!(
                    Button {
                        icon: Icon::Check,
                        text: get_local_text("friends.accept"),
                        onpress: move |_| match &cx.props.onaccept {
                            Some(f) => f.call(()),
                            None    => {},
                        }
                    }
                )),
                cx.props.onchat.is_some().then(|| rsx! (
                    Button {
                        icon: Icon::ChatBubbleBottomCenterText,
                        text: get_local_text("uplink.chat"),
                        onpress: move |_| match &cx.props.onchat {
                            Some(f) => f.call(()),
                            None    => {},
                        }
                    }
                )),
                Button {
                    icon: Icon::UserMinus,
                    appearance: Appearance::Secondary,
                    onpress: move |_| match &cx.props.onremove {
                        Some(f) => f.call(()),
                        None    => {},
                    }
                    tooltip: cx.render(rsx!(
                        Tooltip {
                            arrow_position: ArrowPosition::Right,
                            text: if cx.props.onaccept.is_none() { get_local_text("friends.remove") } else { get_local_text("friends.deny") }
                        }
                    )),
                },
                cx.props.onchat.is_some().then(|| rsx!(
                    Button {
                        icon: Icon::NoSymbol,
                        appearance: Appearance::Secondary,
                        onpress: move |_| match &cx.props.onblock {
                            Some(f) => f.call(()),
                            None    => {},
                        }
                        tooltip: cx.render(rsx!(
                            Tooltip {
                                arrow_position: ArrowPosition::Right,
                                text: get_local_text("friends.block"),
                            }
                        )),
                    }
                ))
            }
        }
    ))
}