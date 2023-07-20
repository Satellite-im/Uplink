use common::{icons::outline::Shape as Icon, state::State};
use dioxus::prelude::*;
use kit::elements::{button::Button, Appearance};

#[derive(Props)]
pub struct Props<'a> {
    onselect: EventHandler<'a, String>,
}

#[allow(non_snake_case)]
pub fn EmojiGroup<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let emoji_list = state.read().ui.get_emoji_sorted_by_usage();

    cx.render(rsx!(
        div {
            class: "emoji-group",
            for emoji in emoji_list {
                Button {
                    text: emoji.0.clone(),
                    appearance: Appearance::Secondary,
                    onpress: move |_| {
                        cx.props.onselect.call(emoji.0.clone());

                    },
                }
            }
            Button {
                icon: Icon::Plus,
                appearance: Appearance::Secondary,
            }
        }
    ))
}
