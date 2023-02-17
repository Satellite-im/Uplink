use dioxus::prelude::*;
use extensions::*;
use kit::{elements::button::Button, icons::Icon};

export_extension!(register);
#[allow(improper_ctypes_definitions)]
extern "C" fn register(registrar: &mut dyn ExtensionRegistrar) {
    registrar.register("emoji_picker", Box::new(ExampleExtension));
}

#[derive(Debug, Clone, PartialEq)]
pub struct EmojiPicker;

impl Extension for EmojiPicker {
    fn details(&self) -> Details {
        Details {
            location: Location::Chatbar,
            ext_type: Type::IconLaunched,
            meta: Meta {
                name: "example_extension",
                pretty_name: "Example!",
                description: "Click me to make things a little orange.",
                author: "Big Juice",
            },
        }
    }

    fn stylesheet(&self) -> String {
        include_str!("./style.css").to_string()
    }

    fn render<'a>(&self, cx: &'a ScopeState) -> Element<'a> {
        let styles = self.stylesheet();

        cx.render(rsx! {
            style { "{styles}" },
            Button {
                icon: Icon::FaceSmile
            }
        })
    }
}
