use dioxus::prelude::*;
use ui_kit::{UiButton::{Button, Appearance}, UiTooltip::{Tooltip, ArrowPosition}};


fn main() {
    dioxus::desktop::launch(app);
}

fn app(cx: Scope) -> Element {
    cx.render(rsx! (
        Button {
            text: String::from("Translated Text"),
            tooltip: cx.render(rsx!(
                Tooltip { 
                    arrow_position: ArrowPosition::Left, 
                    text: String::from("Don't be lazy!")
                }
            )),
            icon: ui_kit::Icon::Language,
        },
        Button {
            text: String::from("Translated Text"),
            appearance: Appearance::Danger,
            tooltip: cx.render(rsx!(
                Tooltip { 
                    arrow_position: ArrowPosition::Top, 
                    text: String::from("Don't be lazy!")
                }
            )),
            icon: ui_kit::Icon::Language,
        }
    ))
}