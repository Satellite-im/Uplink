use dioxus::prelude::*;
use extensions::*;
use kit::{elements::button::Button, icons::Icon};

// Exports the plugin using the registrar
// You don't need to really worry about this but it is required.
// Just change emoji's to the name of your extension in alpha-numeric snake case.
export_extension!(register);
extern "C" fn register(registrar: &mut dyn ExtensionRegistrar) {
    registrar.register("emojis", Box::new(ExampleExtension));
}

#[derive(Debug, Clone, PartialEq)]
pub struct ExampleExtension;

impl Extension for ExampleExtension {
    fn get(&self) -> Details {
        Details {
            location: Location::Chatbar,
            ext_type: Type::IconLaunched,
            meta: Meta::default(),
        }
    }

    fn stylesheet(&self) -> String {
        "
        #example {
            background: green;
        }
        "
        .into()
    }

    fn render(&self, cx: Scope) -> dioxus::prelude::Element {
        let styles = self.stylesheet();

        cx.render(rsx! {
            style { "{styles}" },
            Button {
                icon: Icon::CursorArrowRipple
            }
        })
    }
}
