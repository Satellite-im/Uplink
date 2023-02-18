use dioxus::prelude::*;
use extensions::*;
use kit::{elements::button::Button, icons::Icon};

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
                "emoji selector"
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
