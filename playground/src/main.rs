use std::time::SystemTime;

use dioxus::prelude::*;
use ui_kit::{User as UserInfo, elements::{Appearance, button::Button, tooltip::{Tooltip, ArrowPosition}, switch::Switch, select::Select, input::{Input, Validation, Options}, folder::Folder, file::File}, icons::Icon, components::{nav::{Nav, Route}, indicator::{Indicator, Platform, Status}, user_image::UserImage, message::{Message, Order}, message_group::MessageGroup, message_divider::MessageDivider, user::User, context_menu::{ContextMenu, ContextItem}, message_typing::MessageTyping, user_image_group::UserImageGroup}, layout::topbar::Topbar};

const STYLE: &str = include_str!("./style.css");
use ui_kit::STYLE as UIKIT_STYLES; 

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
        div {
            class: "item",
            div {
                class: "header",
                label {
                    class: "l",
                    "{cx.props.name}"
                },
                p {
                    class: "p",
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
    let home = Route { to: "/fake/home", name: "Home".to_owned(), icon: Icon::HomeModern, ..Route::default() };
    let routes = vec![
        home,
        Route { to: "/fake/chat", name: "Chat".to_owned(), icon: Icon::ChatBubbleBottomCenter, ..Route::default() },
        Route { to: "/fake/friends", name: "Friends".to_owned(), icon: Icon::Users, with_badge: Some("16".into()), loading: None },
        Route { to: "/fake/settings", name: "Settings".to_owned(), icon: Icon::Cog, ..Route::default() },
    ];
    let active = routes[0].clone();

    let validation_options = Validation {
        max_length: Some(6),
        min_length: Some(3),
        alpha_numeric_only: true,
        no_whitespace: true,
    };

    let input_options = Options {
        with_validation: Some(validation_options),
        replace_spaces_underscore: false,
        with_clear_btn: true,
        ..Options::default()
    };

    let some_time_long_ago = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default();

    println!("rendering app");

    let sample_participants_2 = vec![
        UserInfo {
            platform: Platform::Mobile,
            status: Status::Online,
            photo: "".into(),
            username: "Phil".into(),
        },
        UserInfo {
            platform: Platform::Mobile,
            status: Status::Idle,
            photo: "".into(),
            username: "Frank".into(),
        },
    ];

    let sample_participants_3 = vec![
        UserInfo {
            platform: Platform::Mobile,
            status: Status::Online,
            photo: "".into(),
            username: "Phil".into(),
        },
        UserInfo {
            platform: Platform::Mobile,
            status: Status::Idle,
            photo: "".into(),
            username: "Frank".into(),
        },
        UserInfo {
            platform: Platform::Headless,
            status: Status::Offline,
            photo: "".into(),
            username: "Sam".into(),
        }
    ];


    let sample_participants_more = vec![
        UserInfo {
            platform: Platform::Mobile,
            status: Status::Online,
            photo: "".into(),
            username: "Phil".into(),
        },
        UserInfo {
            platform: Platform::Mobile,
            status: Status::Idle,
            photo: "".into(),
            username: "Frank".into(),
        },
        UserInfo {
            platform: Platform::Headless,
            status: Status::Offline,
            photo: "".into(),
            username: "Sam".into(),
        },
        UserInfo {
            platform: Platform::Mobile,
            status: Status::Offline,
            photo: "".into(),
            username: "Valerie".into(),
        }
    ];

    let sample_participants_more_2 = vec![
        UserInfo {
            platform: Platform::Mobile,
            status: Status::Online,
            photo: "".into(),
            username: "Phil".into(),
        },
        UserInfo {
            platform: Platform::Mobile,
            status: Status::Idle,
            photo: "".into(),
            username: "Frank".into(),
        },
        UserInfo {
            platform: Platform::Headless,
            status: Status::Offline,
            photo: "".into(),
            username: "Sam".into(),
        },
        UserInfo {
            platform: Platform::Mobile,
            status: Status::Offline,
            photo: "".into(),
            username: "Valerie".into(),
        }
    ];


    cx.render(rsx! (
        style {
            "{UIKIT_STYLES} {STYLE}"
        },
        Item {
            name: String::from("User Image Group"),
            desc: String::from("Group a bunch of user images into a nice icon that fits in the same space"),
            cx.render(rsx!(
                UserImageGroup {
                    participants: sample_participants_more
                },
                UserImageGroup {
                    participants: sample_participants_3
                },
                UserImageGroup {
                    participants: sample_participants_2
                }
            ))
        },
        Item {
            name: String::from("Typing Indicator"),
            desc: String::from("Inline message typing indicator"),
            MessageTyping {
                user_image: cx.render(rsx!(
                    UserImageGroup {
                        participants: sample_participants_more_2
                    }
                ))
            }
        },
        Item {
            name: String::from("Folder"),
            desc: String::from("A clickable folder"),
            Folder {
                text: "Folder One".into(),
            },
            Folder {
                open: true,
                text: "Open Folder".into(),
            },
            Folder {
                with_rename: true,
                text: "Open Folder".into(),
            },
            Folder {
                disabled: true,
                with_rename: true,
                text: "Open Folder".into(),
            },
        },
        Item {
            name: String::from("FIle"),
            desc: String::from("A clickable file"),
            File {
                text: "Generic File".into(),
            },
            File {
                text: "Generic File".into(),
                disabled: true,
            },
            File {
                with_rename: true,
                text: "Generic File".into(),
            },
        },
        Item {
            name: String::from("Context Menu"),
            desc: String::from("A wrapper component to add a context menu to a component"),
            ContextMenu {
                id: "{mock}".into(),
                items: cx.render(rsx!(
                    ContextItem {
                        icon: Icon::EyeSlash,
                        text: String::from("Mark Seen"),
                    },
                    hr{}
                    ContextItem {
                        text: String::from("Call"),
                    },
                    ContextItem {
                        text: String::from("Share File"),
                    },
                    hr{}
                    ContextItem {
                        icon: Icon::XMark,
                        text: String::from("Hide Chat"),
                    },
                    ContextItem {
                        danger: true,
                        icon: Icon::NoSymbol,
                        text: String::from("Block User"),
                    },
                )),
                User {
                    username: "User With Context".into(),
                    subtext: "Right click me to see my context menu!".into()
                    user_image: cx.render(rsx!(
                        UserImage {
                            platform: Platform::Desktop,
                            status: Status::Idle
                        }
                    )),
                }
            }
        },
        Item {
            name: String::from("User"),
            desc: String::from("A generic user component"),
            User {
                username: "John Doe".into(),
                subtext: "Howdy, John! Wanna grab pizza later?".into()
                user_image: cx.render(rsx!(
                    UserImage {
                        platform: Platform::Desktop,
                        status: Status::Idle
                    }
                )),
            }
        },
        Item {
            name: String::from("User"),
            desc: String::from("A generic user component"),
            User {
                username: "John Doe".into(),
                subtext: "It is for these reasons that I regard the decision last year to shift our efforts in space from low to high gear as among the most important decisions that will be made during my incumbency in the office of the Presidency.".into()
                user_image: cx.render(rsx!(
                    UserImage {
                        platform: Platform::Mobile,
                        status: Status::Online
                    }
                )),
                with_badge: "11".into()
            }
        },
        Item {
            name: String::from("Message Divider"),
            desc: String::from("Divide a group of messages"),
            MessageDivider {
                text: "New messages".into(),
                timestamp: some_time_long_ago,

            }
        },
        Item {
            name: String::from("Message Group"),
            desc: String::from("Group of messages"),
            MessageGroup {
                user_image: cx.render(rsx!(
                    UserImage {
                    platform: Platform::Desktop,
                    status: Status::Idle
                    }
                )),
                with_sender: "John Doe | Satellite.im".into(),
                Message {
                    order: Order::First,
                    with_text: "A Message!".into()
                },
                Message {
                    order: Order::Middle,
                    with_text: "Another one.".into()
                },
                Message {
                    order: Order::Last
                    with_text: "It is for these reasons that I regard the decision last year to shift our efforts in space from low to high gear as among the most important decisions that will be made during my incumbency in the office of the Presidency.".into()
                }
            }
        },
        Item {
            name: String::from("Message Group"),
            desc: String::from("Group of messages"),
            MessageGroup {
                user_image: cx.render(rsx!(
                    UserImage {
                        platform: Platform::Mobile,
                        status: Status::Online
                    }
                )),
                remote: true,
                Message {
                    remote: true,
                    order: Order::First,
                    with_text: "A Message!".into()
                },
                Message {
                    remote: true,
                    order: Order::Middle,
                    with_text: "Another one.".into()
                },
                Message {
                    remote: true,
                    order: Order::Last
                    with_text: "It is for these reasons that I regard the decision last year to shift our efforts in space from low to high gear as among the most important decisions that will be made during my incumbency in the office of the Presidency.".into()
                }
            }
        },
        Item {
            name: String::from("Message"),
            desc: String::from("Local message"),
            Message {
                order: Order::First,
                with_text: "A Message!".into()
            }
        },
        Item {
            name: String::from("Message Remote"),
            desc: String::from("Remote message"),
            Message {
                remote: true,
                order: Order::First,
                with_text: "A Message!".into()
            }
        },
        Item {
            name: String::from("Input"),
            desc: String::from("Validated input."),
            Input {
                placeholder: "Placeholder...".into(),
                options: input_options
            },
        },
        Item {
            name: String::from("Input Disabled"),
            desc: String::from("Validated input."),
            Input {
                placeholder: "Placeholder...".into(),
                options: input_options,
                disabled: true,
            },
        },
        Item {
            name: String::from("Input"),
            desc: String::from("Validated input."),
            Input {
                placeholder: "Placeholder...".into(),
                icon: Icon::MagnifyingGlass,
                options: Options {
                    with_label: "Labels Too!".into(),
                    ..input_options
                }
            },
        },
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
            },
            UserImage {
                platform: Platform::Mobile,
                status: Status::Online,
                typing: true,
            },
            UserImage {
                platform: Platform::Mobile,
                status: Status::Online,
                with_username: "Joe Schmoe".into(),
                typing: true,
            },
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
                status: Status::DoNotDisturb
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
            Button {
                appearance: Appearance::Secondary,
                icon: ui_kit::icons::Icon::UserGroup,
                with_badge: "5".into(),
                tooltip: cx.render(rsx!(
                    Tooltip { 
                        arrow_position: ArrowPosition::Bottom, 
                        text: String::from("Friends")
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
            name: String::from("Switch Disabled"),
            desc: String::from("A disabled on off switch."),
            Switch { disabled: true },
        },
        Item {
            name: String::from("Select Box"),
            desc: String::from("Generic select box"),
            Select {
                initial_value: "Nothing".to_owned(),
                options: vec!["Nothing".into(), "Something".into()],
                
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
                            icon: Icon::PhoneArrowUpRight,
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