use common::state::{action::ConfigAction, Action, State};
use dioxus::prelude::*;
use dioxus_desktop::use_window;

pub fn open_dev_tools(cx: Scope) {
    let window = use_window(cx);
    window.webview.open_devtools();
}
pub fn toggle_devmode(state: UseSharedState<State>) {
    let devmode = state.read().configuration.developer.developer_mode;
    state
        .write()
        .mutate(Action::Config(ConfigAction::SetDevModeEnabled(!devmode)));
}
