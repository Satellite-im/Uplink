use dioxus::prelude::*;

use crate::elements::{button::Button, Appearance};
use common::{icons::outline::Shape as Icon, language::get_local_text};

#[derive(Props)]
pub struct Props<'a> {
    friends: bool,
    name: String,
    status: String,
    onjoin: EventHandler<'a, ()>,
}

#[allow(non_snake_case)]
pub fn UserCard<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(
        rsx!(
            div {
                class: "user-card",
                div {
                    class: "header",
                    div {
                        class: "icon",
                        img {
                            src: "https://avatars.githubusercontent.com/u/5470909?s=200&v=4",
                            alt: "User icon"
                        }
                    }
                    div {
                        class: "title",
                        h1 { cx.props.name.clone() }
                    }
                    div {
                        class: "subtitle",
                        p { cx.props.status.clone() }
                    }
                }
                div {
                    class: "body",
                    Button {
                        text: if cx.props.friends { get_local_text("uplink.added") } else { format!("{} {}", get_local_text("uplink.add"), cx.props.name) },
                        appearance: if cx.props.friends { Appearance::Secondary } else { Appearance::Primary },
                        icon: if cx.props.friends { Icon::Check } else { Icon::Plus },
                        onpress: |_| {
                            cx.props.onjoin.call(());
                        }
                    }
                }
            }
        )
    )
}
