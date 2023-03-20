use common::{
    icons::outline::Shape as Icon,
    state::{Action, State},
};
use dioxus::prelude::*;
use extensions::{export_extension, Details, Extension, Location, Meta, Type};
use kit::{
    components::nav::{Nav, Route},
    elements::{button::Button, label::Label},
};
use once_cell::sync::Lazy;

// These two lines are all you need to use your Extension implementation as a shared library
static EXTENSION: Lazy<EmojiSelector> = Lazy::new(|| EmojiSelector {});
export_extension!(EXTENSION);

pub struct ClearAll;

impl Extension for ClearAll {
    fn details(&self) -> Details {
        Details {
            location: Location::Sidebar,
            ext_type: Type::SimpleAction,
            meta: Meta {
                name: "clear_all",
                pretty_name: "Clear All Notifications",
                description: "Clears all notifications with a single click.",
                author: "Satellite <devs@satellite.im>",
            },
        }
    }

    fn stylesheet(&self) -> String {
        "".into()
    }

    fn render<'a>(&self, cx: &'a ScopeState) -> Element<'a> {
        let styles = self.stylesheet();

        cx.render(rsx! (
            style { "{styles}" },
            // Render standard (required) button to fire action.
            Button {
                icon: Icon::BellSlash,
                onpress: move |_| {
                    // TODO: Clear all notifications in state
                }
            }
        ))
    }
}
