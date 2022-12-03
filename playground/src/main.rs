use dioxus::prelude::*;
use ui_kit::{elements::{Appearance, button::Button, tooltip::{Tooltip, ArrowPosition}, switch::Switch, select::Select}, icons::Icon, components::{nav::{Nav, Route}, indicator::{Indicator, Platform, Status}, user_image::UserImage, topbar::Topbar}};

const STYLE: &'static str = include_str!("./style.css");

fn main() {
    dioxus::desktop::launch(app);
}

#[derive(Props)]
pub struct Props<'a> {
    name: String,
    desc: String,
    children: Element<'a>
}

#[allow(non_snake_case)]
pub fn Item<'a>(cx: Scope<'a, Props<'a>>) -> Element<'a> {
    cx.render(rsx!(
        style {
            "{STYLE}"
        },
        div {
            class: "item",
            div {
                class: "header",
                label {
                    "{cx.props.name}"
                },
                p {
                    "{cx.props.desc}"
                },
            },
            div {
                class: "body",
                &cx.props.children
            }
        }
    ))
}

fn app(cx: Scope) -> Element {
    let home = Route { to: "/fake/home", name: "Home", icon: Icon::HomeModern };
    let routes = vec![
        home,
        Route { to: "/fake/chat", name: "Chat", icon: Icon::ChatBubbleBottomCenter },
        Route { to: "/fake/friends", name: "Friends", icon: Icon::Users },
        Route { to: "/fake/settings", name: "Settings", icon: Icon::Cog },
    ];
    let active = routes[0].clone();

    cx.render(rsx! (
        Item {
            name: String::from("Profile Photo"),
            desc: String::from("Profile photo, with indicator."),
            UserImage {
                image: String::from("
                    data:image/png;base64,
                    iVBORw0KGgoAAAANSUhEUgAAAAUA
                    AAAFCAYAAACNbyblAAAAHElEQVQI12P4//8/w38GIAXDIBKE0DHxgljNBAAO
                    9TXL0Y4OHwAAAABJRU5ErkJggg==
                "),
                platform: Platform::Mobile,
                status: Status::Online
            },
            UserImage {
                platform: Platform::Desktop,
                status: Status::Idle
            }
        },
        Item {
            name: String::from("Indicator"),
            desc: String::from("Status indicator."),
            Indicator {
                platform: Platform::Mobile,
                status: Status::Online
            },
            Indicator {
                platform: Platform::Mobile,
                status: Status::Offline
            },
            Indicator {
                platform: Platform::Desktop,
                status: Status::Idle
            },
            Indicator {
                platform: Platform::Tv,
                status: Status::Online
            },
            Indicator {
                platform: Platform::Headless,
                status: Status::DoNotDistrub
            }
        },
        Item {
            name: String::from("Button"),
            desc: String::from("Standard button."),
            Button {
                text: String::from("Translated Text"),
                tooltip: cx.render(rsx!(
                    Tooltip { 
                        arrow_position: ArrowPosition::Left, 
                        text: String::from("Don't be lazy!")
                    }
                )),
                icon: ui_kit::icons::Icon::Language,
            },
        },
        Item {
            name: String::from("Button"),
            desc: String::from("Dangerous button."),
            Button {
                text: String::from("Translated Text"),
                appearance: Appearance::Danger,
                tooltip: cx.render(rsx!(
                    Tooltip { 
                        arrow_position: ArrowPosition::Bottom, 
                        text: String::from("Don't be lazy!")
                    }
                )),
                icon: ui_kit::icons::Icon::Language,
            },
        },
        Item {
            name: String::from("Button"),
            desc: String::from("Disabled dangerous button."),
            Button {
                text: String::from("Translated Text"),
                appearance: Appearance::Danger,
                disabled: true,
                tooltip: cx.render(rsx!(
                    Tooltip { 
                        arrow_position: ArrowPosition::TopRight, 
                        text: String::from("Don't be lazy!")
                    }
                )),
                icon: ui_kit::icons::Icon::Language,
            },
        },
        Item {
            name: String::from("Icon Only Button"),
            desc: String::from("A normal button with just an icon."),
            Button {
                appearance: Appearance::Primary,
                icon: ui_kit::icons::Icon::Keyboard,
            },
        },
        Item {
            name: String::from("Icon Only Button"),
            desc: String::from("A normal button with just an icon, and a tooltip."),
            Button {
                appearance: Appearance::Primary,
                icon: ui_kit::icons::Icon::Cog,
                tooltip: cx.render(rsx!(
                    Tooltip { 
                        arrow_position: ArrowPosition::Bottom, 
                        text: String::from("Settings")
                    }
                )),
            },
        },
        Item {
            name: String::from("Switch"),
            desc: String::from("A on off switch."),
            Switch {},
        },
        Item {
            name: String::from("Select Box"),
            desc: String::from("Generic select box"),
            Select {
                options: vec!["Nothing".into(), "Something".into()]
            }
        },
        Item {
            name: String::from("Nav"),
            desc: String::from("Dynamic navbar component"),
            Nav {
                routes: routes,
                active: active
            },
        },
        Item {
            name: String::from("Topbar"),
            desc: String::from("Reusable topbar component"),
            Topbar {
                with_back_button: true,
                controls: cx.render(
                    rsx! (
                        Button {
                            icon: Icon::Phone,
                            appearance: Appearance::Secondary,
                            tooltip: cx.render(rsx!(
                                Tooltip { 
                                    arrow_position: ArrowPosition::Top, 
                                    text: String::from("Audio Call")
                                }
                            )),
                        },
                        Button {
                            icon: Icon::VideoCamera,
                            appearance: Appearance::Secondary,
                            tooltip: cx.render(rsx!(
                                Tooltip { 
                                    arrow_position: ArrowPosition::Top, 
                                    text: String::from("Video Call")
                                }
                            )),
                        },
                        Button {
                            icon: Icon::Bell,
                            appearance: Appearance::Secondary,
                            tooltip: cx.render(rsx!(
                                Tooltip { 
                                    arrow_position: ArrowPosition::Top, 
                                    text: String::from("Notifications")
                                }
                            )),
                        },
                    )
                ),
                cx.render(
                    rsx! (
                        UserImage {
                            platform: Platform::Desktop,
                            status: Status::Online
                        }
                    )
                ),
            }
        },
    ))
}