use crate::state::{Action, State};
use dioxus::prelude::*;
use dioxus_router::*;
use ui_kit::{
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    icons::{Icon, IconElement},
    layout::topbar::Topbar,
};

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    #[props(optional)]
    larger: Option<bool>,
}

#[allow(non_snake_case)]
pub fn MediaPlayer(cx: Scope<Props>) -> Element {
    let state: UseSharedState<State> = use_shared_state::<State>(&cx)?;
    let active_chat = state.read().get_active_chat().unwrap_or_default();

    let silenced = state.read().ui.silenced;

    let silenced_str = silenced.to_string();

    cx.render(rsx!(div {
        id: "media-player",
        div {
            id: "handle",
            IconElement {
                icon: Icon::ChevronUpDown,
                size: 20,
            },
        },
        Topbar {
            controls: cx.render(
                rsx! (
                    Button {
                        icon: Icon::ArrowsPointingOut,
                        appearance: Appearance::Secondary,
                        tooltip: cx.render(rsx!(
                            Tooltip {
                                arrow_position: ArrowPosition::Top,
                                text: String::from("Fullscreen")
                            }
                        )),
                    },
                )
            )
        },
        div {
            id: "media-renderer",
            div {
                class: "video-wrap",
                Button {
                    icon: Icon::Square2Stack,
                    appearance: Appearance::Transparent,
                    tooltip: cx.render(rsx!(
                        Tooltip {
                            arrow_position: ArrowPosition::Right,
                            text: String::from("Popout Player")
                        }
                    )),
                    onpress: move |_| {
                        state.write().mutate(Action::TogglePopout);
                    }
                },
                state.read().ui.popout_player.then(|| rsx!(
                    span {
                        class: "popped-out",
                        video {}
                    }
                )),
                (!state.read().ui.popout_player).then(|| rsx!(
                    video {
                        src: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4",
                        autoplay: "true",
                        "loop": "true",
                        muted: "{silenced_str}"
                    }
                ))
            }
        },
        div {
            class: "media-controls",
            Button {
                icon: Icon::VideoCamera,
                appearance: Appearance::Secondary,
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: String::from("Enable Camera")
                    }
                )),
            },
            Button {
                icon: Icon::Window,
                appearance: Appearance::Secondary,
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: String::from("Screenshare")
                    }
                )),
                // TODO: https://github.com/quadrupleslap/scrap
            },
            Button {
                icon: Icon::PhoneXMark,
                appearance: Appearance::Danger,
                text: "End".into(),
                onpress: move |_| {
                    let _ = state.write().mutate(Action::ToggleMedia(active_chat.clone()));
                }
            },
            Button {
                icon: Icon::Cog6Tooth,
                appearance: Appearance::Secondary,
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: String::from("Settings")
                    }
                )),
                // TODO: Navigate to media settings
                onpress: move |_| {
                    use_router(&cx).replace_route("/settings", None, None);
                }
            },
        }
    }))
}
