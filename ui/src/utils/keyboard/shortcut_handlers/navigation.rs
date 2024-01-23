use dioxus_core::ScopeState;
use dioxus_desktop::use_window;

pub fn set_app_visible(cx: &ScopeState) {
    let window = use_window(cx);
    window.set_minimized(false);
    window.set_visible(true);
    window.set_focus();
}

pub fn set_app_invisible(cx: &ScopeState) {
    let window = use_window(cx);
    window.set_minimized(true);
    window.set_visible(false);
}
