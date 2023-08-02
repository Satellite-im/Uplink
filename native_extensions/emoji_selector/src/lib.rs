use common::warp_runner::{RayGunCmd, WarpCmd};
use common::{
    icons::outline::Shape as Icon,
    state::{scope_ids::ScopeIds, ui::EmojiDestination, Action, State},
};
use dioxus::prelude::*;
use dioxus_desktop::use_eval;
use emojis::Group;
use extensions::{export_extension, Details, Extension, Location, Meta, Type};
use futures::StreamExt;
use kit::{
    components::nav::{Nav, Route},
    elements::{button::Button, label::Label},
};
use once_cell::sync::Lazy;
use uuid::Uuid;
use warp::{logging::tracing::log, raygun::ReactionState};

// These two lines are all you need to use your Extension implementation as a shared library
static EXTENSION: Lazy<EmojiSelector> = Lazy::new(|| EmojiSelector {});
export_extension!(EXTENSION);

pub struct EmojiSelector;

fn group_to_str(group: emojis::Group) -> String {
    match group {
        Group::SmileysAndEmotion => "Smileys & Emotion".into(),
        Group::PeopleAndBody => "People & Body".into(),
        Group::AnimalsAndNature => "Animals & Nature".into(),
        Group::FoodAndDrink => "Food & Drink".into(),
        Group::TravelAndPlaces => "Travel & Places".into(),
        Group::Activities => "Activities".into(),
        Group::Objects => "Objects".into(),
        Group::Symbols => "Symbols".into(),
        Group::Flags => "Flags".into(),
    }
}

#[inline_props]
fn build_nav(cx: Scope) -> Element<'a> {
    let routes = vec![
        Route {
            to: "Smileys & Emotion",
            name: group_to_str(Group::SmileysAndEmotion),
            icon: Icon::FaceSmile,
            with_badge: None,
            loading: None,
        },
        Route {
            to: "People & Body",
            name: group_to_str(Group::PeopleAndBody),
            icon: Icon::Users,
            with_badge: None,
            loading: None,
        },
        Route {
            to: "Animals & Nature",
            name: group_to_str(Group::AnimalsAndNature),
            icon: Icon::Leaf,
            with_badge: None,
            loading: None,
        },
        Route {
            to: "Travel & Places",
            name: group_to_str(Group::TravelAndPlaces),
            icon: Icon::BuildingStorefront,
            with_badge: None,
            loading: None,
        },
        Route {
            to: "Activities",
            name: group_to_str(Group::Activities),
            icon: Icon::Basketball,
            with_badge: None,
            loading: None,
        },
        Route {
            to: "Objects",
            name: group_to_str(Group::Objects),
            icon: Icon::Cake,
            with_badge: None,
            loading: None,
        },
        Route {
            to: "Symbols",
            name: group_to_str(Group::Symbols),
            icon: Icon::CpuChip,
            with_badge: None,
            loading: None,
        },
        Route {
            to: "Flags",
            name: group_to_str(Group::Flags),
            icon: Icon::Flag,
            with_badge: None,
            loading: None,
        },
    ];

    let scroll_script = r#"
        var emoji_scrolling_element = document.getElementById('scrolling');
        const emoji_group_element = document.getElementById('$EMOJI_CONTAINER');
        emoji_group_element.scrollIntoView({ behavior: 'smooth', block: 'start' });
    "#;
    let eval = use_eval(cx);

    cx.render(rsx!(Nav {
        routes: routes.clone(),
        active: routes[0].clone(),
        onnavigate: move |r| {
            let scroll_script = scroll_script.to_string().replace("$EMOJI_CONTAINER", r);
            eval(scroll_script);
        }
    }))
}

#[derive(Debug)]
enum Command {
    React(Uuid, Uuid, String),
}

#[inline_props]
fn render_selector<'a>(
    cx: Scope,
    hide: UseState<bool>,
    mouse_over_emoji_button: UseRef<bool>,
    nav: Element<'a>,
) -> Element<'a> {
    //println!("render emoji selector");
    let state = use_shared_state::<State>(cx)?;
    #[cfg(not(target_os = "macos"))]
    let mouse_over_emoji_selector = use_ref(cx, || false);
    #[cfg(not(target_os = "macos"))]
    let eval = use_eval(cx);

    let focus_script = r#"
            var emoji_selector = document.getElementById('emoji_selector');
            emoji_selector.focus();
        "#;

    let ch = use_coroutine(cx, |mut rx: UnboundedReceiver<Command>| {
        to_owned![state];
        async move {
            let warp_cmd_tx = state.read().get_warp_ch();
            while let Some(cmd) = rx.next().await {
                match cmd {
                    Command::React(conversation_id, message_id, emoji) => {
                        let (tx, rx) = futures::channel::oneshot::channel();
                        if let Err(e) = warp_cmd_tx.send(WarpCmd::RayGun(RayGunCmd::React {
                            conversation_id,
                            message_id,
                            reaction_state: ReactionState::Add,
                            emoji,
                            rsp: tx,
                        })) {
                            log::error!("failed to send warp command: {}", e);
                            continue;
                        }

                        let res = rx.await.expect("command canceled");
                        if let Err(e) = res {
                            log::error!("failed to add/remove reaction: {e}");
                        }
                    }
                }
            }
        }
    });

    cx.render(rsx! (
            div {
                onmouseenter: |_| {
                    #[cfg(not(target_os = "macos"))] 
                    {
                        *mouse_over_emoji_selector.write_silent() = true;
                    }
                },
                onmouseleave: |_| {
                    #[cfg(not(target_os = "macos"))] 
                    {
                        *mouse_over_emoji_selector.write_silent() = false;
                        eval(focus_script.to_string());
                    }
                },
                id: "emoji_selector",
                aria_label: "emoji-selector",
                tabindex: "0",
                onblur: |_| {
                    // When leaving default to the chatbar
                    state.write().mutate(Action::SetEmojiDestination(
                        Some(common::state::ui::EmojiDestination::Chatbar),
                    ));
                    #[cfg(target_os = "macos")] 
                    {
                        if !*mouse_over_emoji_button.read() {
                            hide.set(false);
                        }
                    }
                    #[cfg(not(target_os = "macos"))] 
                    {
                        if !*mouse_over_emoji_button.read() && !*mouse_over_emoji_selector.read() {
                            hide.set(false);
                        }
                    }
                },
                div {
                    id: "scrolling",
                    emojis::Group::iter().map(|group| {
                        let name: String = group_to_str(group);
                        rsx!(
                            div {
                                id: "{group_to_str(group)}",
                                Label {
                                    text: name
                                },
                            }
                            div {
                                class: "emojis-container",
                                aria_label: "emojis-container",
                                group.emojis().map(|emoji| {
                                    rsx!(
                                        div {
                                            aria_label: "emoji",
                                            class: "emoji",
                                            onclick: move |_| {
                                                let destination = state.read().ui.emoji_destination.clone().unwrap_or(EmojiDestination::Chatbar);
                                                match destination {
                                                    EmojiDestination::Chatbar => { // If we're on an active chat, append the emoji to the end of the chat message.
                                                        let c =  match state.read().get_active_chat() {
                                                            Some(c) => c,
                                                            None => {
                                                                println!("can't send emoji to chatbar - no active chat");
                                                                return;
                                                            }
                                                        };
                                                        let draft: String = c.draft.unwrap_or_default();
                                                        let new_draft = format!("{draft}{emoji}");
                                                        state.write_silent().mutate(Action::SetChatDraft(c.id, new_draft));
                                                        if let Some(scope_id_usize) = state.read().scope_ids.chatbar {
                                                            cx.needs_update_any(ScopeIds::scope_id_from_usize(scope_id_usize));
                                                        };
                                                    },
                                                    EmojiDestination::Message(conversation_uuid, message_uuid) => {
                                                        ch.send(Command::React(conversation_uuid, message_uuid, emoji.to_string()));
                                                        state.write().mutate(Action::SetEmojiDestination(Some(EmojiDestination::Chatbar)));
                                                    },
                                                }
                                                // Hide the selector when clicking an emoji
                                                hide.set(false);
                                            },
                                            emoji.as_str()
                                        }
                                    )
                                })
                            }
                        )
                    })
                }
                nav
            },
            script { focus_script },
        ))
}

impl Extension for EmojiSelector {
    fn details(&self) -> Details {
        Details {
            location: Location::Chatbar,
            ext_type: Type::IconLaunched,
            meta: Meta {
                name: "emoji_selector",
                pretty_name: "Emoji Selector",
                description:
                    "Browse the standard unicode library of emoji's and send them to friends.",
                author: "Satellite <devs@satellite.im>",
            },
        }
    }

    fn stylesheet(&self) -> String {
        include_str!("./style.css").to_string()
    }

    fn render<'a>(&self, cx: &'a ScopeState) -> Element<'a> {
        //println!("render emoji");
        let styles = self.stylesheet();
        let display_selector = use_state(cx, || false);
        let mouse_over_emoji_button = use_ref(cx, || false);

        cx.render(rsx! (
            style { "{styles}" },
            // If enabled, render the selector popup.
            display_selector.then(|| rsx!(render_selector{hide: display_selector.clone(), mouse_over_emoji_button: mouse_over_emoji_button.clone(), nav: cx.render(rsx!(build_nav{}))})),
            div {
                onmouseenter: |_| {
                    *mouse_over_emoji_button.write_silent() = true;
                },
                onmouseleave: |_| {
                    *mouse_over_emoji_button.write_silent() = false;
                },
                // Render standard (required) button to toggle.
                Button {
                    icon: Icon::FaceSmile,
                    onpress: move |_| {
                        display_selector.set(!display_selector.clone());
                    }
                }
            }
        ))
    }
}
