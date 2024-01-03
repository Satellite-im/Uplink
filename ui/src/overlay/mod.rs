use common::icons::outline::Shape as Icon;
use common::icons::Icon as IconElement;
use dioxus::prelude::*;
use dioxus_desktop::{tao::dpi::PhysicalPosition, use_window, LogicalSize, WindowBuilder};
use kit::components::{
    indicator::{Platform, Status},
    user_image::UserImage,
};

use kit::STYLE as UIKIT_STYLES;
pub const APP_STYLE: &str = include_str!("./style.css");

pub fn make_config() -> dioxus_desktop::Config {
    dioxus_desktop::Config::default()
        .with_window(make_window())
        .with_custom_index(
            r#"
        <!doctype html>
        <html>
        <body style="background-color:rgba(0,0,0,0);"><div id="main"></div></body>
        </html>"#
                .to_string(),
        )
}

fn make_window() -> WindowBuilder {
    WindowBuilder::new()
        .with_transparent(true)
        .with_decorations(false)
        .with_resizable(false)
        .with_always_on_top(true)
        .with_position(PhysicalPosition::new(0, 0))
        .with_max_inner_size(LogicalSize::new(220, 220))
        .with_closable(false)
        // .with_content_protection(true)
        .with_minimizable(false)
        .with_maximizable(false)
}

#[allow(non_snake_case)]
pub fn OverlayDom(cx: Scope) -> Element {
    let window = use_window(cx);
    let _ = window.set_ignore_cursor_events(true);

    cx.render(rsx! {
        style { "{UIKIT_STYLES} {APP_STYLE}" },
        div {
            class: "overlay-wrap",
            div {
                class: "overlay-user",
                UserImage {
                    platform: Platform::Desktop,
                    status: Status::Online,
                },
                p {
                    class: "username",
                    "Username"
                },
                span {
                    class: "is-audible-indication",
                    IconElement {
                        icon: Icon::SpeakerWave
                    }
                }
            },
            div {
                class: "overlay-user",
                UserImage {
                    platform: Platform::Desktop,
                    status: Status::Online,
                },
                p {
                    class: "username",
                    "Username"
                },
            },
            div {
                class: "overlay-user",
                UserImage {
                    platform: Platform::Desktop,
                    status: Status::Online,
                },
                p {
                    class: "username",
                    "Username"
                },
                span {
                    class: "is-audible-indication",
                    IconElement {
                        icon: Icon::SpeakerXMark
                    }
                }
            }
        }
    })
}
