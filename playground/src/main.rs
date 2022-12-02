use dioxus::prelude::*;
use ui_kit::{elements::{button::{Button, Appearance}, tooltip::{Tooltip, ArrowPosition}, switch::Switch}, Icon, IconElement, components::nav::{Nav, Route}};

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
    let mut routes = vec![];
    let home = Route {to:String::from("/fake/home"), name:String::from("Home"), icon: Icon::HomeModern };
    let active = home.clone();

    routes.push(home);
    routes.push(Route {to:String::from("/fake/chat"), name:String::from("Chat"), icon: Icon::ChatBubbleBottomCenter });
    routes.push(Route {to:String::from("/fake/friends"), name:String::from("Friends"), icon: Icon::Users });
    routes.push(Route {to:String::from("/fake/settings"), name:String::from("Settings"), icon: Icon::Cog });

    cx.render(rsx! (
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
                icon: ui_kit::Icon::Language,
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
                icon: ui_kit::Icon::Language,
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
                icon: ui_kit::Icon::Language,
            },
        },
        Item {
            name: String::from("Icon Only Button"),
            desc: String::from("A normal button with just an icon."),
            Button {
                appearance: Appearance::Primary,
                icon: ui_kit::Icon::Keyboard,
            },
        },
        Item {
            name: String::from("Icon Only Button"),
            desc: String::from("A normal button with just an icon, and a tooltip."),
            Button {
                appearance: Appearance::Primary,
                icon: ui_kit::Icon::Cog,
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
            name: String::from("Nav"),
            desc: String::from("Dynamic navbar component"),
            Nav {
                routes: routes,
                active: active
            },
        }
    ))
}