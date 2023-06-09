use common::{
    icons::outline::Shape as Icon,
    state::{scope_ids::ScopeIds, Action, State},
};
use dioxus::prelude::*;
use dioxus_desktop::use_eval;
use emojis::{Emoji, Group};
use extensions::{export_extension, Details, Extension, Location, Meta, Type};
use kit::{
    components::nav::{Nav, Route},
    elements::{button::Button, label::Label},
};
use once_cell::sync::Lazy;

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
    let routes_ = vec![
        Route {
            to: "Smileys & Emotion",
            name: group_to_str(Group::SmileysAndEmotion),
            icon: Icon::Flag,
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
        routes: routes_.clone(),
        active: routes_[0].clone(),
        onnavigate: move |r| {
            let scroll_script = scroll_script.to_string().replace("$EMOJI_CONTAINER", r);
            eval(scroll_script);
        }
    }))
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

    let emojis_to_display: Vec<(Group, Vec<&Emoji>)> = emojis::Group::iter()
        .map(|group| {
            let filtered_emojis: Vec<&Emoji> = group
                .emojis()
                .filter(|emoji| {
                    !(cfg!(target_os = "windows") && emoji.unicode_version().major() >= 14)
                })
                .collect();
            (group, filtered_emojis)
        })
        .filter(|(_, emojis)| !emojis.is_empty())
        .collect();

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
                    emojis_to_display.iter().cloned().map(|(group, emojis)| {
                        let group_name = group_to_str(group);
                        rsx!(
                            div {
                                id: "{group_name}",
                                Label {
                                    text: group_name.clone()
                                }
                            }
                            div {
                                class: "emojis-container",
                                emojis.iter().cloned().map(|emoji| {
                                    rsx!(
                                        div {
                                            aria_label: "emoji",
                                            class: "emoji",
                                            onclick: move |_| {
                                                println!("{:?}", emoji);
                                                // If we're on an active chat, append the emoji to the end of the chat message.
                                                let c =  match state.read().get_active_chat() {
                                                    Some(c) => c,
                                                    None => return
                                                };
                                                let draft: String = c.draft.unwrap_or_default();
                                                let new_draft = format!("{draft}{emoji}");
                                                state.write_silent().mutate(Action::SetChatDraft(c.id, new_draft));
                                                if let Some(scope_id_usize) = state.read().scope_ids.chatbar {
                                                    cx.needs_update_any(ScopeIds::scope_id_from_usize(scope_id_usize));
                                                };
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
