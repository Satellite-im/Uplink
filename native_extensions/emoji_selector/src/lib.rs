use dioxus::prelude::*;
use emojis::Group;
use extensions::*;
use kit::{
    elements::{button::Button, label::Label},
    icons::Icon,
};

export_extension!(register);
#[allow(improper_ctypes_definitions)]
extern "C" fn register(registrar: &mut dyn ExtensionRegistrar) {
    registrar.register("emoji_selector", Box::new(EmojiSelector));
}

#[derive(Debug, Clone, PartialEq)]
pub struct EmojiSelector;

impl EmojiSelector {
    fn render_selector<'a>(&self, cx: &'a ScopeState) -> Element<'a> {
        cx.render(rsx! {
            div {
                id: "emoji_selector",
                emojis::Group::iter().map(|group| {
                    let name: String = match group {
                        Group::SmileysAndEmotion => "Smileys & Emotion".into(),
                        Group::PeopleAndBody => "People & Body".into(),
                        Group::AnimalsAndNature => "Animals & Nature".into(),
                        Group::FoodAndDrink => "Food & Drink".into(),
                        Group::TravelAndPlaces => "Travel & Places".into(),
                        Group::Activities => "Activities".into(),
                        Group::Objects => "Objects".into(),
                        Group::Symbols => "Symbols".into(),
                        Group::Flags => "Flags".into(),
                    };
                    rsx!(
                        Label {
                            text: name
                        },
                        div {
                            class: "emojis-container",
                            group.emojis().map(|emoji| {
                                rsx!(
                                    div {
                                        class: "emoji",
                                        emoji.as_str()
                                    }
                                )
                            })
                        }
                    )
                })
            }
        })
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

    fn stylesheet(&self) -> String {
        include_str!("./style.css").to_string()
    }

    fn render<'a>(&self, cx: &'a ScopeState) -> Element<'a> {
        let styles = self.stylesheet();
        let display_selector = use_state(cx, || false);

        cx.render(rsx! {
            style { "{styles}" },
            // If enabled, render the selector popup.
            display_selector.then(|| self.render_selector(&cx)),
            // Render standard (required) button to toggle.
            Button {
                icon: Icon::FaceSmile,
                onpress: move |_| {
                    display_selector.set(!display_selector.clone());
                }
            }
        })
    }
}
