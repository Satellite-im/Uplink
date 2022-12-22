use dioxus::prelude::*;
use kit::{
    elements::{
        button::Button,
        tooltip::{ArrowPosition, Tooltip},
        Appearance,
    },
    icons::{Icon, IconElement},
    layout::topbar::Topbar,
};

use crate::state::{Action, State};

#[derive(Eq, PartialEq, Props)]
pub struct Props {
    #[props(optional)]
    larger: Option<bool>,
    settings_text: String, 
    enable_camera_text: String,
    fullscreen_text: String,
    popout_player_text: String,
    screenshare_text: String,
    end_text: String,
}

#[allow(non_snake_case)]
pub fn MediaPlayer(cx: Scope<Props>) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx).unwrap();
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
                                text: cx.props.fullscreen_text.clone(),
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
                            text: cx.props.popout_player_text.clone(),
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
                        "muted": "{silenced_str}"
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
                        text: cx.props.enable_camera_text.clone(),
                    }
                )),
            },
            Button {
                icon: Icon::Window,
                appearance: Appearance::Secondary,
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: cx.props.screenshare_text.clone(),
                    }
                )),
                // TODO: https://github.com/quadrupleslap/scrap
            },
            Button {
                icon: Icon::PhoneXMark,
                appearance: Appearance::Danger,
                text: cx.props.end_text.clone(),
                onpress: move |_| {
                    state.write().mutate(Action::ToggleMedia(active_chat.clone()));
                }
            },
            Button {
                icon: Icon::Cog6Tooth,
                appearance: Appearance::Secondary,
                tooltip: cx.render(rsx!(
                    Tooltip {
                        arrow_position: ArrowPosition::Bottom,
                        text: cx.props.settings_text.clone(),
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
