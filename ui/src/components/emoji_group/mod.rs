// use common::{icons::outline::Shape as Icon, state::State};
use common::state::ui::EmojiDestination;
use common::state::State;
use common::{icons::outline::Shape as Icon, state::Action};
use dioxus::prelude::*;
use kit::elements::{
    button::Button,
    tooltip::{ArrowPosition, Tooltip},
    Appearance,
};

#[derive(Props)]
pub struct Props<'a> {
    onselect: EventHandler<'a, String>,
    apply_to: EmojiDestination,
}

#[allow(non_snake_case)]
pub fn EmojiGroup<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let state = use_shared_state::<State>(cx)?;
    let emoji_list = state.read().ui.get_emoji_sorted_by_usage(4);

    cx.render(rsx!(
        div {
            class: "emoji-group",
            for emoji in emoji_list {
                Button {
                    key: "{emoji.0}",
                    text: emoji.0.clone(),
                    appearance: Appearance::Secondary,
                    onpress: move |_| {
                        cx.props.onselect.call(emoji.0.clone());
                    },
                    tooltip: cx.render(rsx!(Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: format!("Used {} times.", emoji.1.to_string())
                    }))
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
