// use common::{icons::outline::Shape as Icon, state::State};
use common::state::ui::EmojiDestination;
use common::state::State;
use common::{icons::outline::Shape as Icon, state::Action};
use dioxus::prelude::*;
use kit::elements::{button::Button, Appearance};

#[derive(Props)]
pub struct Props<'a> {
    onselect: EventHandler<'a, String>,
    apply_to: EmojiDestination,
}

#[allow(non_snake_case)]
pub fn EmojiGroup<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let emojis = state.read().ui.emojis.clone();
    let sorted_list = emojis.get_sorted_vec(Some(4));

    cx.render(rsx!(
        div {
            class: "emoji-group",
            for emoji in sorted_list {
                Button {
                    key: "{emoji.0}",
                    text: emoji.0.clone(),
                    appearance: Appearance::Secondary,
                    onpress: move |_| {
                        cx.props.onselect.call(emoji.0.clone());
                    }
                }
            }
            Button {
                key: "open-picker",
                icon: Icon::Plus,
                appearance: Appearance::Secondary,
                onpress: move |_| {
                    state.write().mutate(Action::SetEmojiDestination(Some(cx.props.apply_to.clone())));
                    state.write().mutate(Action::SetEmojiPickerVisible(true));
                },
            }
        }
    ))
}
