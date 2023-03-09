use std::ffi::CString;

use common::{
    icons::outline::Shape as Icon,
    state::{Action, State},
};
use dioxus::prelude::*;
use dioxus_desktop::use_eval;
use emojis::Group;
use extensions2::{export_extension, Details, Extension, Location, Meta, Type};
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

impl EmojiSelector {
    fn build_nav<'a>(&self, cx: &'a ScopeState) -> Element<'a> {
        let mut routes_ = vec![];
        routes_.push(Route {
            to: "Smileys Emotion",
            name: group_to_str(Group::SmileysAndEmotion),
            icon: Icon::Flag,
            with_badge: None,
            loading: None,
        });
        routes_.push(Route {
            to: "People Body",
            name: group_to_str(Group::PeopleAndBody),
            icon: Icon::Users,
            with_badge: None,
            loading: None,
        });
        routes_.push(Route {
            to: "Animals Nature",
            name: group_to_str(Group::AnimalsAndNature),
            icon: Icon::Leaf,
            with_badge: None,
            loading: None,
        });
        routes_.push(Route {
            to: "Travel Places",
            name: group_to_str(Group::TravelAndPlaces),
            icon: Icon::BuildingStorefront,
            with_badge: None,
            loading: None,
        });
        routes_.push(Route {
            to: "Activities",
            name: group_to_str(Group::Activities),
            icon: Icon::Basketball,
            with_badge: None,
            loading: None,
        });
        routes_.push(Route {
            to: "Objects",
            name: group_to_str(Group::Objects),
            icon: Icon::Cake,
            with_badge: None,
            loading: None,
        });
        routes_.push(Route {
            to: "Symbols",
            name: group_to_str(Group::Symbols),
            icon: Icon::CpuChip,
            with_badge: None,
            loading: None,
        });
        routes_.push(Route {
            to: "Flags",
            name: group_to_str(Group::Flags),
            icon: Icon::Flag,
            with_badge: None,
            loading: None,
        });
        cx.render(rsx!(Nav {
            routes: routes_,
            onnavigate: move |r| {
                let eval = use_eval(cx);
                eval(format!("scrolltoId({})", r));
            }
        }))
    }

    fn render_selector<'a>(&self, cx: &'a ScopeState) -> Element<'a> {
        let state = use_shared_state::<State>(cx)?;

        let scroll_script = r#"
            function scrolltoId(id){
                var group = document.getElementById(id);
                var emoji_scroller = document.getElementById("scrolling");

                emoji_scroller.scrollTo({
                    top: group.scrollTop,
                    left: group.scrollLeft
                });
            }
        "#;

        cx.render(rsx! (
            div {
                id: "emoji_selector",
                div {
                    id: "scrolling",
                    emojis::Group::iter().map(|group| {
                        let name: String = group_to_str(group);
                        rsx!(
                            Label {
                                text: name
                            },
                            div {
                                class: "emojis-container",
                                id: "{group_to_str(group)}",
                                group.emojis().map(|emoji| {
                                    rsx!(
                                        div {
                                            class: "emoji",
                                            onclick: move |_| {
                                                // If we're on an active chat, append the emoji to the end of the chat message.
                                                if let Some(c) = state.write().get_active_chat() {
                                                    if let Some(draft) = c.draft {
                                                        let new_draft = draft + emoji.as_ref();
                                                        state.write().mutate(Action::SetChatDraft(c.id, new_draft));
                                                    }
                                                }
                                            },
                                            emoji.as_str()
                                        }
                                    )
                                })
                            }
                        )
                    })
                }
                self.build_nav(cx),
            },
            script {
                "{scroll_script}"
            },
        ))
    }
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

    fn stylesheet(&self) -> CString {
        let s = include_str!("./style.css");
        match CString::new(s) {
            Ok(r) => r,
            Err(_e) => {
                CString::from_vec_with_nul("/*error encoding stylesheet*/\0".into()).unwrap()
            }
        }
    }

    fn render<'a>(&self, cx: &'a ScopeState) -> Element<'a> {
        let styles = self.stylesheet().to_string_lossy().to_string();
        let display_selector = use_state(cx, || false);

        cx.render(rsx! (
            style { "{styles}" },
            // If enabled, render the selector popup.
            display_selector.then(|| self.render_selector(cx)),
            // Render standard (required) button to toggle.
            Button {
                icon: Icon::FaceSmile,
                onpress: move |_| {
                    display_selector.set(!display_selector.clone());
                }
            }
        ))
    }
}
