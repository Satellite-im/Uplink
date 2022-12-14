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
    username: String,
    suffix: String,
    user_image: Element<'a>,
    #[props(optional)]
    onchat: Option<EventHandler<'a>>,
    #[props(optional)]
    onremove: Option<EventHandler<'a>>,
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
