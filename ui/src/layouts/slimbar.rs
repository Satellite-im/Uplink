use crate::{utils::build_participants, UplinkRoute};
use common::icons::outline::Shape as Icon;

use common::{
    language::get_local_text,
    state::{Action, State},
};
use dioxus::prelude::*;
use dioxus_router::prelude::*;
use kit::elements::button::Button;
use kit::elements::tooltip::{ArrowPosition, Tooltip};
use kit::{
    components::{
        context_menu::{ContextItem, ContextMenu},
        user_image_group::UserImageGroup,
    },
    layout::slimbar::Slimbar,
};
use uuid::Uuid;

#[derive(PartialEq, Props)]
pub struct Props {
    pub active: UplinkRoute,
}

#[allow(non_snake_case)]
pub fn SlimbarLayout(cx: Scope<Props>) -> Element {
    let state = use_shared_state::<State>(cx)?;
    let router = use_navigator(cx);

    let favorites = if state.read().initialized {
        state.read().chats_favorites()
    } else {
        vec![]
    };

    let favorites_chats = use_ref(cx, || favorites.clone());

    let chat_to_move = use_ref(cx, || Option::<Uuid>::None);
    let target_chat_to_drop = use_ref(cx, ||Option::<Uuid>::None);
    let change_favorite_chats_order = use_ref(cx, || false);

    if *change_favorite_chats_order.read() {
        let target_index = favorites_chats.read().iter().position(|chat| chat.id == target_chat_to_drop.read().unwrap_or_default());
        let move_index = favorites_chats.read().iter().position(|chat| chat.id == chat_to_move.read().unwrap_or_default());
        println!("target_index: {:?}, move_index: {:?}", target_index, move_index);
        if let (Some(target_index), Some(move_index)) = (target_index, move_index) {
            if move_index < target_index {
                println!("Reordering here?");
                let chat_to_move = favorites_chats.write_silent().remove(move_index);
    
                favorites_chats.write().insert(target_index - 1, chat_to_move);
            }
        }
        state.write().mutate(Action::ReorderFavorites(favorites_chats.read().iter().map(|chat| chat.id).collect()));
        *change_favorite_chats_order.write_silent() = false;
        *chat_to_move.write_silent() = None;
        *target_chat_to_drop.write_silent() = None;
    }

    let eval = use_eval(cx);
    let element_selected_to_drop_script = include_str!("./drag.js");

    cx.render(rsx!(
        Slimbar { // TODO: This should hide when the sidebar is hidden if the view is minimal (mobile).
            with_back_button: !state.read().ui.is_minimal_view() && state.read().ui.sidebar_hidden,
            onback: move |_| {
                let current = state.read().ui.sidebar_hidden;
                state.write().mutate(Action::SidebarHidden(!current));
            },
            top_children: cx.render(rsx!(
                // Only display favorites if we have some.
                (!favorites_chats.read().is_empty()).then(|| rsx!(
                    div {
                        id: "favorites",
                        aria_label: "Favorites",
                        favorites_chats.read().iter().cloned().map(|chat| {
                            let users_typing = chat.typing_indicator.iter().any(|(k, _)| *k != state.read().did_key())
                                && !state.read().chats_sidebar().contains(&chat);
                            let favorites_chat = chat.clone();
                            let remove_favorite = chat.clone();
                            let chat_id = chat.id;
                            let participants = state.read().chat_participants(&chat);
                            let other_participants: Vec<_> = state.read().remove_self(&participants);
                            let participants_name = match chat.conversation_name {
                                Some(name) => name,
                                None => State::join_usernames(&other_participants)
                            };
                            rsx! (div {
                                id: format_args!("{}", chat_id),
                                aria_label: "favorite-chat-item-on-slimbar",
                                draggable: "true",
                               
                                onmouseenter: move |_| {
                                    println!("chat_id mouse enter: {}", chat_id);
                                },
                                
                                ondragend: move |event| {
                                    let script = element_selected_to_drop_script.replace("$OFFSET_X", &event.mouse.client_coordinates().x.to_string()).replace("$OFFSET_Y", &event.mouse.client_coordinates().y.to_string());
                                    eval(&script);
                                    
                                    // cx.spawn({
                                    //     to_owned![eval, script, target_chat_to_drop, change_favorite_chats_order];
                                    //     async move {
                                    //         if let Ok(r) = eval(&script) {
                                    //             if let Ok(val) = r.join().await {
                                    //                 let element_id = val.as_str().unwrap_or_default();
                                    //                 if !element_id.is_empty() {
                                    //                     println!("element_id: {}", element_id);
                                    //                     *target_chat_to_drop.write_silent() = Uuid::parse_str(element_id).ok();
                                    //                     change_favorite_chats_order.set(true);
                                    //                 }
                                    //             }
                                    //     }
                                    // }
                                    // });
                                    
                                },
                                ondragstart: move |_| {
                                    *chat_to_move.write_silent() = Some(chat_id);
                                    println!("chat_id drag start: {}", chat_id);
                                },
                                ContextMenu {
                                    key: "{chat_id}-favorite",
                                    id: chat_id.to_string(),
                                    items: cx.render(rsx!(
                                        ContextItem {
                                            aria_label: "favorites-chat".into(),
                                            icon: Icon::ChatBubbleBottomCenterText,
                                            text: get_local_text("uplink.chat"),
                                            onpress: move |_| {
                                                if state.read().ui.is_minimal_view() {
                                                    state.write().mutate(Action::SidebarHidden(true));
                                                }
                                                state.write().mutate(Action::ChatWith(&favorites_chat.id, false));
                                                router.replace(UplinkRoute::ChatLayout{});
                                            }
                                        },
                                        ContextItem {
                                            aria_label: "favorites-remove".into(),
                                            icon: Icon::HeartSlash,
                                            text: get_local_text("favorites.remove"),
                                            onpress: move |_| {
                                                state.write().mutate(Action::ToggleFavorite(&remove_favorite.id));
                                            }
                                        }
                                    )),
                                    UserImageGroup {
                                        participants: build_participants(&other_participants),
                                        aria_label: participants_name.clone(),
                                        with_username: participants_name,
                                        use_tooltip: true,
                                        typing: users_typing,
                                        onpress: move |_| {
                                            if state.read().ui.is_minimal_view() {
                                                state.write().mutate(Action::SidebarHidden(true));
                                            }
                                            state.write().mutate(Action::ChatWith(&chat.id, false));
                                            router.replace(UplinkRoute::ChatLayout{});
                                        }
                                    }
                                }

                            }
                                
                            )
                        })
                    }
                )),
            )),
            navbar_visible: state.read().ui.sidebar_hidden,
            with_nav: cx.render(rsx!(
                crate::AppNav {
                    active: cx.props.active.clone(),
                    tooltip_direction: ArrowPosition::Left,
                    onnavigate: move |_| {
                        if state.read().configuration.audiovideo.interface_sounds {
                            common::sounds::Play(common::sounds::Sounds::Interaction);
                        }
                        if state.read().ui.is_minimal_view() {
                            state.write().mutate(Action::SidebarHidden(true));
                        }
                    },
                },
            )),
            state.read().configuration.developer.experimental_features.then(|| rsx!(
                Button {
                    icon: Icon::Plus,
                    tooltip: cx.render(rsx!(
                        Tooltip {
                            arrow_position: ArrowPosition::Left,
                            text: "Create Community".into()
                        }
                    )),
                    onpress: move |_| {
                        router.replace(UplinkRoute::CommunityLayout {});
                    }
                }
            ))
        }
    ))
}
