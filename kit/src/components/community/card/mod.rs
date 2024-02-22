use dioxus::prelude::*;

use crate::elements::{button::Button, Appearance};
use common::icons::outline::Shape as Icon;
use common::language::get_local_text;

#[derive(Props)]
pub struct Props<'a> {
    joined: bool,
    name: String,
    onjoin: EventHandler<()>,
}

#[allow(non_snake_case)]
pub fn CommunityCard<'a>(cx: Scope<'a, Props<'a>>) -> Element {
    cx.render(
        rsx!(
            div {
                class: "community-card",
                div {
                    class: "header",
                    div {
                        class: "icon",
                        img {
                            src: "https://avatars.githubusercontent.com/u/5470909?s=200&v=4",
                            alt: "Community icon"
                        }
                    }
                    div {
                        class: "title",
                        h1 { cx.props.name.clone() }
                    }
                    div {
                        class: "subtitle",
                        p {
                            get_local_text("community.invited")
                        },
                    }
                }
                div {
                    class: "body",
                    Button {
                        text: if cx.props.joined { get_local_text("community.joined") } else { format!("{} {}", get_local_text("community.join"), cx.props.name) },
                        appearance: if cx.props.joined { Appearance::Secondary } else { Appearance::Primary },
                        icon: if cx.props.joined { Icon::Check } else { Icon::ArrowRight },
                        onpress: |_| {
                            cx.props.onjoin.call(());
                        }
                    }
                }
            }
        )
    )
}
