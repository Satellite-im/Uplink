use dioxus_core::ScopeState;
use dioxus_desktop::use_window;
use once_cell::sync::Lazy;
use warp::sync::RwLock;

static CALL_COUNT: Lazy<RwLock<u32>> = Lazy::new(|| RwLock::new(0));

pub fn set_app_visible(cx: &ScopeState) {
    let window = use_window(cx);
    *CALL_COUNT.write() += 1;

    if *CALL_COUNT.read() > 1 {
        *CALL_COUNT.write() = 0;
    }

    if *CALL_COUNT.read() == 1 {
        if !window.is_visible() || window.is_minimized() {
            window.set_minimized(false);
            window.set_visible(true);
            window.set_focus();
        } else {
            window.set_minimized(true);
            window.set_visible(false);
        }
    }
}
