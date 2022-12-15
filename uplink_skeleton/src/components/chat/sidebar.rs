use dioxus::prelude::*;
use ui_kit::{User as UserInfo, elements::{input::{Input, Options}, label::Label}, icons::Icon, components::{nav::Nav, context_menu::{ContextMenu, ContextItem}, user::User, user_image::UserImage, indicator::{Platform, Status}, user_image_group::UserImageGroup}, layout::sidebar::Sidebar as ReusableSidebar};
use warp::{multipass::identity::Identity, raygun::Message};

use crate::{components::chat::RouteInfo, state::{State, Action, Chat}};

#[derive(PartialEq, Props)]
pub struct Props {
    route_info: RouteInfo,
}

pub fn build_participants(identities: &Vec<Identity>) -> Vec<UserInfo> {
    // Create a vector of UserInfo objects to store the results
    let mut user_info: Vec<UserInfo> = vec![];

    // Iterate over the identities vector
    for identity in identities {
        // For each identity, create a new UserInfo object and set its fields
        // to the corresponding values from the identity object
        user_info.push(UserInfo {
            platform: Platform::Mobile,
            status: Status::Online,
            username: identity.username(),
            photo: identity.graphics().profile_picture(),
        })
    }

    // Return the resulting user_info vector
    user_info
}

pub fn build_participants_names(identities: &Vec<Identity>) -> String {
    let mut participants_name = String::from("");

    // Iterate over the identities vector
    for identity in identities {
        // Create a string with the username of the current identity and a comma
        let name = format!("{}, ", identity.username());
        // Append the name string to the participants_name string
        participants_name.push_str(&name);
    }

    // Remove the last two characters from the participants_name string (the trailing comma and space)
    participants_name.pop();
    participants_name.pop();

    // Return the resulting participants_name string
    participants_name
}


#[allow(non_snake_case)]
pub fn Sidebar(cx: Scope<Props>) -> Element {
    let state: UseSharedState<State> = use_context::<State>(&cx)?;

    let search_placeholder = String::from("Search...");

    let sidebar_chats = state.read().chats.in_sidebar.clone();

    let favorites = state.read().chats.favorites.clone();

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
                    active: cx.props.route_info.active.clone(),
                    onnavigate: move |r| {
                        use_router(&cx).replace_route(r, None, None);
                    }
                },
            )),
            // Only display favorites if we have some.
            (favorites.len() > 0).then(|| rsx!(
                div {
                    id: "favorites",
                    Label {
                        text: "Favorites".into()
                    },
                    div {
                        class: "vertically-scrollable",
                        favorites.iter().cloned().map(|chat_id| {
                            let chat = state.read().chats.all.get(&chat_id).unwrap().clone();
                            let favorites_chat = chat.clone();
                            let remove_favorite = chat.clone();
                            let without_me = state.read().get_without_me(chat.participants.clone());
                            let participants_name = build_participants_names(&without_me);
                            rsx! (
                                ContextMenu {
                                    key: "{chat_id}-favorite",
                                    id: chat_id.to_string(),
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            icon: Icon::Heart,
                                            text: String::from("Remove Favorite"),
                                            onpress: move |_| {
                                                state.write().mutate(Action::ToggleFavorite(remove_favorite.clone()));
                                            }
                                        },
                                        ContextItem {
                                            icon: Icon::ChatBubbleBottomCenterText,
                                            text: String::from("Chat"),
                                            onpress: move |_| {
                                                state.write().mutate(Action::ChatWith(favorites_chat.clone()));
                                                if cx.props.route_info.active.to != "/" {
                                                    use_router(&cx).replace_route("/", None, None);
                                                }
                                            }
                                        }
                                    )),
                                    UserImageGroup {
                                        key: "{chat_id}-favorite",
                                        participants: build_participants(&chat.participants.clone()),
                                        with_username: participants_name,
                                        onpress: move |_| {
                                            state.write().mutate(Action::ChatWith(chat.clone()));
                                            if cx.props.route_info.active.to != "/" {
                                                use_router(&cx).replace_route("/", None, None);
                                            }
                                        }
                                    }
                                }
                            )
                        })
                    }
                }
            )),
            (!sidebar_chats.is_empty()).then(|| rsx!(
                Label {
                    text: "Chats".into()
                }
            )),
            div {
                id: "chats",
                sidebar_chats.iter().cloned().map(|chat_id| {
                    let chat = state.read().chats.all.get(&chat_id).unwrap().clone();
                    let without_me = state.read().get_without_me(chat.participants.clone());
                    let user = without_me.first();
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

                    let active = state.read().get_active_chat().unwrap_or_default().id == chat.id;
                    let chat_with = chat.clone();
                    let clear_unreads = chat.clone();

                    let participants = without_me.clone();
                    let participants_name = if participants.len() > 2 { build_participants_names(&participants) } else { parsed_user.username() };

                    rsx!(
                        ContextMenu {
                            key: "{key}-chat",
                            id: format!("{}-chat", key.to_string()),
                            items: cx.render(rsx!(
                                ContextItem {
                                    icon: Icon::EyeSlash,
                                    text: String::from("Clear Unreads"),
                                    onpress: move |_| {
                                        state.write().mutate(Action::ClearUnreads(clear_unreads.clone()));
                                    }
                                },
                                hr{ },
                                ContextItem {
                                    text: String::from("Call"),
                                },
                                hr{ }
                                ContextItem {
                                    icon: Icon::XMark,
                                    text: String::from("Hide Chat"),
                                    onpress: move |_| {
                                        state.write().mutate(Action::RemoveFromSidebar(chat.clone()));
                                    }
                                },
                                ContextItem {
                                    danger: true,
                                    icon: Icon::NoSymbol,
                                    text: String::from("Block User"),
                                },
                            )),
                            User {
                                username: participants_name,
                                subtext: val.join("\n"),
                                timestamp: timestamp,
                                active: active,
                                user_image: cx.render(rsx!(
                                    if participants.len() <= 2 {rsx! (
                                        UserImage {
                                            platform: Platform::Mobile,
                                            status: Status::Online
                                            image: parsed_user.graphics().profile_picture(),
                                        }
                                    )} else {rsx! (
                                        UserImageGroup {
                                            participants: build_participants(&participants)
                                        }
                                    )}
                                )),
                                with_badge: badge,
                                onpress: move |_| {
                                    state.write().mutate(Action::ChatWith(chat_with.clone()));
                                    if cx.props.route_info.active.to != "/" {
                                        use_router(&cx).replace_route("/", None, None);
                                    }
                                }
                            }
                        }
                    )}
                )
            }
        }
    ))
}
