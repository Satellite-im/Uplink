use dioxus::prelude::*;
use extensions::*;
use kit::{elements::button::Button, icons::Icon};

// Exports the plugin using the registrar
// You don't need to really worry about this but it is required.
// Just change "emojis" to the name of your extension in alpha-numeric snake case.
export_extension!(register);
#[allow(improper_ctypes_definitions)]
extern "C" fn register(registrar: &mut dyn ExtensionRegistrar) {
    registrar.register("emojis", Box::new(ExampleExtension));
}

#[derive(Debug, Clone, PartialEq)]
pub struct ExampleExtension;

impl Extension for ExampleExtension {
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
                icon: Icon::Truck
            }
        })
    }
}
