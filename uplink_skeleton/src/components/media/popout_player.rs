use dioxus::prelude::*;

pub const SCRIPT: &str = include_str!("./script.js");

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    #[props(optional)]
    larger: Option<bool>,
}

#[allow(non_snake_case)]
pub fn PopoutPlayer(cx: Scope<Props>) -> Element {
    cx.render(rsx! (
        div {
            class: "popout-player",
            video {
                src: "https://www.w3schools.com/html/mov_bbb.mp4",
                autoplay: "true",
                "loop": "true",
                "muted": "true",
            }
        },
        script { "{SCRIPT}" }
    ))
}
