use crate::elements::{button::Button, Appearance};
use common::{icons::outline::Shape as Icon, state::State};
use dioxus::prelude::*;
use dioxus_desktop::{use_window, LogicalSize};

#[allow(non_snake_case)]
pub fn TopbarControls() -> Element {
    let state = use_signal( State::load);
    let desktop = use_window();
    let first_resize = use_signal( || true);
    if cfg!(not(target_os = "macos")) {
        rsx!(
            div {
                class: "controls",
                Button {
                    aria_label: "minimize-button".into(),
                    icon: Icon::Minus,
                    appearance: Appearance::Transparent,
                    onpress: move |_| {
                        desktop.set_minimized(true);
                    }
                },
                Button {
                    aria_label: "square-button".into(),
                    icon: Icon::Square2Stack,
                    appearance: Appearance::Transparent,
                    onpress: move |_| {
                        desktop.set_maximized(!desktop.is_maximized());
                        if state.read().ui.window_maximized
                            && *first_resize.read()
                            && cfg!(target_os = "windows")
                        {
                            desktop.set_inner_size(LogicalSize::new(950.0, 600.0));
                            *first_resize.write_silent() = false;
                        }
                    }
                },
                Button {
                    aria_label: "close-button".into(),
                    icon: Icon::XMark,
                    appearance: Appearance::Transparent,
                    onpress: move |_| {
                        desktop.close();
                    }
                },
            }
        ))
    } else {
        rsx!({}))
    }
}
