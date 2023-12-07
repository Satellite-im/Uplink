#[allow(unused_imports)]
use common::icons::outline::Shape as Icon;
use common::language::get_local_text;
use common::sounds;
use common::state::{action::ConfigAction, Action, State};
use dioxus::prelude::*;
#[allow(unused_imports)]
use kit::elements::{button::Button, switch::Switch};

use crate::components::settings::SettingSection;

#[allow(non_snake_case)]
pub fn KeybindSettings(cx: Scope) -> Element {
    let state = use_shared_state::<State>(cx)?;

    cx.render(rsx!(
        div {
            id: "settings-keybinds",
            aria_label: "settings-keybinds",
            SettingSection {
                section_label: get_local_text("settings-notifications.enabled"),
                section_description: get_local_text("settings-notifications.enabled-description"),
                Switch {
                    active: state.read().configuration.notifications.enabled,
                    onflipped: move |e| {
                        if state.read().configuration.audiovideo.interface_sounds {
                            sounds::Play(sounds::Sounds::Flip);
                        }
                        state.write().mutate(Action::Config(ConfigAction::SetNotificationsEnabled(e)));
                    }
                }
            }
        }
    ))
}
