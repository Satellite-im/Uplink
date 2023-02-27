use chrono::{DateTime, Utc};

use dioxus::{
    core::Event,
    events::{MouseData, MouseEvent},
    prelude::*,
};

use crate::components::{
    indicator::{Platform, Status},
    user_image::UserImage,
};

#[derive(Props)]
pub struct Props<'a> {
    username: String,
    user_image: Element<'a>,
    subtext: String,
    timestamp: Option<DateTime<Utc>>,
    #[props(optional)]
    loading: Option<bool>,
    #[props(optional)]
    with_badge: Option<String>,
    #[props(optional)]
    active: Option<bool>,
    #[props(optional)]
    onpress: Option<EventHandler<'a, MouseEvent>>,
}

pub fn get_time_ago(cx: &Scope<Props>) -> String {
    let f = timeago::Formatter::new();
    let current_time = Utc::now();
    let c: chrono::Duration = current_time - cx.props.timestamp.unwrap_or(current_time);
    let duration: std::time::Duration = match c.to_std() {
        // for the sidebar, don't want the timestamp to increment a few seconds every time the typing indicator comes over.
        // prevent this by rounding down and giving a duration in minutes only.
        Ok(d) => std::time::Duration::from_secs(d.as_secs() / 60),
        Err(_e) => std::time::Duration::ZERO,
    };

    f.convert(duration)
}

/// Generates the optional badge for the user.
/// If there is no badge provided, we'll return an empty string.
pub fn get_badge(cx: &Scope<Props>) -> String {
    cx.props.with_badge.clone().unwrap_or_default()
}

/// Tells the parent the user was interacted with.
pub fn emit(cx: &Scope<Props>, e: Event<MouseData>) {
    if let Some(f) = cx.props.onpress.as_ref() {
        f.call(e)
    }
}

#[allow(non_snake_case)]
pub fn User<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    let time_ago = get_time_ago(&cx);
    let badge = get_badge(&cx);
    let active = cx.props.active.unwrap_or_default();
    let loading = cx.props.loading.unwrap_or_default();

    cx.render(rsx! (
        if loading {
            rsx!(
                UserLoading {
                }
            )
        } else {
            rsx!(
                div {
                    class: {
                        format_args!("user {} noselect defaultcursor", if active { "active" } else { "" })
                    },
                    onclick: move |e| emit(&cx, e),
                    aria_label: "User",
                    (!badge.is_empty()).then(|| rsx!(
                        span {
                            class: "badge",
                            aria_label: "User Badge",
                            span {
                                class: "badge-prefix",
                                "{time_ago}"
                            }
                            span {
                                class: "badge-count",
                                "{badge}"
                            }
                        }
                    )),
                    &cx.props.user_image,
                    div {
                        class: "info",
                        aria_label: "User Info",
                        p {
                            class: "username",
                            aria_label: "Username",
                            "{cx.props.username}"
                        },
                        p {
                            class: "subtext",
                            aria_label: "User Status",
                            "{cx.props.subtext}"
                        }
                    }
                }
            )
        }
    ))
}

#[allow(non_snake_case)]
fn UserLoading(cx: Scope) -> Element {
    cx.render(rsx!(
        div {
            class: "skeletal-user",
            aria_label: "skeletal-user",
            UserImage {
                loading: true,
                status: Status::Offline,
                platform: Platform::Desktop,
            },
            div {
                class: "skeletal-bars",
                div {
                    class: "skeletal-inline",
                    div {
                        class: "skeletal skeletal-bar seventy-five",
                    },
                    div {
                        class: "skeletal skeletal-bar flex",
                    }
                },
                div {
                    class: "skeletal skeletal-bar thick",
                }
            }
        }
    ))
}
