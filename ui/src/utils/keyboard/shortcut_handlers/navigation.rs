use dioxus_core::ScopeState;
use dioxus_desktop::use_window;

pub fn set_app_visible() {
    let window = use_window(cx);

    if !window.is_focused() && !window.is_minimized() {
        window.set_focus();
    } else if !window.is_visible() || window.is_minimized() {
        window.set_minimized(false);
        window.set_visible(true);
        window.set_focus();
    } else if window.is_visible() || !window.is_minimized() {
        window.set_minimized(true);
        window.set_visible(false);
    }
}
