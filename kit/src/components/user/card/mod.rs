use dioxus::prelude::*;

use crate::elements::{button::Button, Appearance};
use common::{icons::outline::Shape as Icon, language::get_local_text};

#[derive(Props)]
pub struct Props<'a> {
    friends: bool,
    name: String,
    status: String,
    onjoin: EventHandler<()>,
}

#[allow(non_snake_case)]
pub fn UserCard<'a>(props: Props<'a>) -> Element {
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
                        h1 { props.name.clone() }
                    }
                    div {
                        class: "subtitle",
                        p { props.status.clone() }
                    }
                }
                div {
                    class: "body",
                    Button {
                        text: if props.friends { get_local_text("uplink.added") } else { format!("{} {}", get_local_text("uplink.add"), props.name) },
                        appearance: if props.friends { Appearance::Secondary } else { Appearance::Primary },
                        icon: if props.friends { Icon::Check } else { Icon::Plus },
                        onpress: |_| {
                            props.onjoin.call(());
                        }
                    }
                }
            }
        )
    )
}
