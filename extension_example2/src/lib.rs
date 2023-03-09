use std::ffi::CString;

use common::icons::outline::Shape as Icon;
use dioxus::prelude::*;
use extensions2::*;
use kit::elements::button::Button;
use once_cell::sync::Lazy;

// These two lines are all you need to use your Extension implementation as a shared library
static EXTENSION: Lazy<ExampleExtension> = Lazy::new(|| ExampleExtension::new());
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

        cx.render(rsx! {
            style { "{styles}" },
            Button {
                icon: Icon::Truck
            }
        })
    }
}
