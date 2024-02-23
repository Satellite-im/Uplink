use common::icons::outline::Shape as Icon;
use dioxus::prelude::*;
use extensions::*;
use kit::elements::button::Button;
use once_cell::sync::Lazy;

// These two lines are all you need to use your Extension implementation as a shared library
static EXTENSION: Lazy<ExampleExtension> = Lazy::new(ExampleExtension::new);
export_extension!(EXTENSION);

struct ExampleExtension {}
impl ExampleExtension {
    fn new() -> Self {
        Self {}
    }
}

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
        include_str!("./style.css").into()
    }

    fn render<'a>(&self, cx: &'a ScopeState) -> Element {
        let styles = self.stylesheet();

        rsx! {
            style { "{styles}" },
            Button {
                icon: Icon::Truck
            }
        })
    }
}
