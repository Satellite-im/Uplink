use dioxus::prelude::*;
use ui_kit::{
    components::{
        indicator::{Platform, Status},
        user_image::UserImage,
    },
    elements::{
        button::Button,
        label::Label,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    icons::Icon,
};

#[derive(Props)]
pub struct Props<'a> {
    // The username of the friend request sender
    username: String,
    // A suffix to the username, typically a unique identifier
    suffix: String,
    // The user image element to display
    user_image: Element<'a>,
    // An optional event handler for the "onchat" event
    #[props(optional)]
    onchat: Option<EventHandler<'a>>,
    // An optional event handler for the "onremove" event
    #[props(optional)]
    onremove: Option<EventHandler<'a>>,
    // An optional event handler for the "onblock" event
    #[props(optional)]
    onblock: Option<EventHandler<'a>>,
}

#[allow(non_snake_case)]
pub fn FriendRequest<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(
        div {
            class: "friend-request",
            &cx.props.user_image,
            div {
                class: "request-info",
                p {
                    "{cx.props.username}",
                    span {
                        "#{cx.props.suffix}"
                    }
                },
                Label {
                    text: "Requested 4 days ago.".into()
                }
            },
            div {
                class: "request-controls",
                Button {
                    icon: Icon::ChatBubbleBottomCenterText,
                    text: "Chat".into(),
                    onpress: move |_| match &cx.props.onchat {
                        Some(f) => f.call(()),
                        None    => {},
                    }
                },
                Button {
                    icon: Icon::XMark,
                    appearance: Appearance::Secondary,
                    onpress: move |_| match &cx.props.onremove {
                        Some(f) => f.call(()),
                        None    => {},
                    }
                    tooltip: cx.render(rsx!(
                        Tooltip {
                            arrow_position: ArrowPosition::Bottom,
                            text: String::from("Remove Friend")
                        }
                    )),
                },
                Button {
                    icon: Icon::EllipsisVertical,
                    appearance: Appearance::Secondary,
                    onpress: move |_| {},
                    tooltip: cx.render(rsx!(
                        Tooltip {
                            arrow_position: ArrowPosition::Bottom,
                            text: String::from("Right click for more")
                        }
                    )),
                }
            }
        }
    ))
}

#[allow(non_snake_case)]
pub fn FriendRequests(cx: Scope) -> Element {
    cx.render(rsx! (
        div {
            class: "friend-requests",
            Label {
                text: "Friends".into(),
            },
            FriendRequest {
                username: "text".into(),
                suffix: "1234".into(),
                user_image: cx.render(rsx! (
                    UserImage {
                        platform: Platform::Desktop,
                        status: Status::Online,
                    }
                ))
            }
        }
    ))
}
