use common::state::{action::ConfigAction, Action, State};
use dioxus::prelude::*;
use dioxus_desktop::use_window;

pub fn open_close_dev_tools(cx: &ScopeState) {
    let window = use_window(cx);
    if window.webview.is_devtools_open() {
        window.webview.close_devtools();
    } else {
        window.webview.open_devtools();
    }
}
pub fn toggle_devmode(state: UseSharedState<State>) {
    let devmode = state.read().configuration.developer.developer_mode;
    state
        .write()
        .mutate(Action::Config(ConfigAction::SetDevModeEnabled(!devmode)));
}
