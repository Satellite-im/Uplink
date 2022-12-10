use dioxus::prelude::*;
use ui_kit::{elements::input::{Input, Options}, icons::Icon, components::{nav::Nav, context_menu::{ContextMenu, ContextItem}, user::User, user_image::UserImage, indicator::{Platform, Status}}, layout::sidebar::Sidebar as ReusableSidebar};
use warp::{multipass::identity::Identity, raygun::Message};

use crate::{layouts::chat::RouteInfo, store::{state::State, actions::Actions}};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

#[allow(non_snake_case)]
pub fn Sidebar(cx: Scope<Props>) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx)?;

    let search_placeholder = String::from("Search...");

    let sidebar_chats = state.read().chats.in_sidebar.clone();

    cx.render(rsx!(
        ReusableSidebar {
            with_search: cx.render(rsx!(
                div {
                    class: "search-input",
                    Input {
                        placeholder: search_placeholder,
                        icon: Icon::MagnifyingGlass,
                        options: Options {
                            with_clear_btn: true,
                            ..Options::default()
                        }
                    }
                }
            ))
            with_nav: cx.render(rsx!(
                Nav {
                    routes: cx.props.route_info.routes.clone(),
                    active: cx.props.route_info.active.clone()
                },
            )),
            sidebar_chats.iter().cloned().map(|chat| {
                // TODO: Make this dynamic for group chats
                let user = chat.participants.get(1);
                let default_message = Message::default();
                let parsed_user = match user {
                    Some(u) => u.clone(),
                    None => Identity::default(),
                };

                let last_message = chat.messages.last();
                let unwrapped_message = match last_message {
                    Some(m) => m,
                    None => &default_message,
                };

                let val = unwrapped_message.value();
                let timestamp = unwrapped_message.date().timestamp_millis() as u64;

                let badge = if chat.unreads > 0 {
                    chat.unreads.to_string()
                } else { "".into() };
                
                let key = chat.id;

                rsx!(
                    ContextMenu {
                        key: "{key}",
                        items: cx.render(rsx!(
                            ContextItem {
                                icon: Icon::EyeSlash,
                                text: String::from("Mark Seen"),
                            },
                            hr{ },
                            ContextItem {
                                text: String::from("Call"),
                            },
                            ContextItem {
                                text: String::from("Share File"),
                            },
                            hr{ }
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
                            username: parsed_user.username(),
                            subtext: val.join("\n"),
                            timestamp: timestamp,
                            user_image: cx.render(rsx!(
                                UserImage {
                                    platform: Platform::Mobile,
                                    status: Status::Online
                                }
                            )),
                            with_badge: badge,
                            onpress: move |_| {
                                state.write().dispatch(Actions::ChatWith(chat.clone()));
                            }
                        }
                    }
                )}
            )
        }
    ))
}
