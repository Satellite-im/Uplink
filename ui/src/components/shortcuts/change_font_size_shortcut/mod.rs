use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

use common::state::{Action, State};
use dioxus::prelude::KeyCode;
use dioxus_core::prelude::*;
use dioxus_desktop::use_global_shortcut;
use dioxus_desktop::wry::application::keyboard::ModifiersState;
use dioxus_hooks::{to_owned, use_shared_state};
use once_cell::sync::Lazy;

use crate::utils::get_font_sizes::{FONT_SIZE_BIGGEST, FONT_SIZE_SMALLEST};

static LAST_CALLED: Lazy<Mutex<Instant>> =
    Lazy::new(|| Mutex::new(Instant::now() - Duration::from_secs(1)));

fn debounced_callback<F: FnOnce()>(callback: F, debounce_duration: Duration) {
    let mut last_called = LAST_CALLED.lock().unwrap();
    let now = Instant::now();

    if now.duration_since(*last_called) > debounce_duration {
        callback();
        *last_called = now;
    }
}

// HACK: It is not allowed to put hooks inside conditional,
// and global shortcut keeps working after unfocus app,
// then solution was to put it into a fake UI, to be build or dropped
// depending on if app is focused or not.
/// It needs app focus verification to use,
/// because component needs to drop when app lost focus
///
/// ### Example:
///
/// ```rust
/// if state.read().ui.metadata.focused {
///    rsx!(ChangeFontSizeShortCut {})
/// }
/// ```
#[allow(non_snake_case)]
pub fn ChangeFontSizeShortCut(cx: Scope<'_>) -> Element<'_> {
    let state = use_shared_state::<State>(cx)?;

    let keyCodeEqual = KeyCode::EqualSign;
    let keyCodeNumPadAdd = KeyCode::Add;

    let keyCodeAndModifierMinus = if cfg!(target_os = "macos") {
        "command + -"
    } else {
        "control + -"
    };

    let modifiers = if cfg!(target_os = "macos") {
        ModifiersState::SUPER
    } else {
        ModifiersState::CONTROL
    };

    use_global_shortcut(cx, (keyCodeEqual, modifiers), {
        to_owned![state];
        move || {
            debounced_callback(
                || {
                    let value = state.read().settings.font_scale();
                    if value < FONT_SIZE_BIGGEST {
                        state.write().mutate(Action::SetFontScale(value + 0.25));
                    }
                },
                Duration::from_millis(500),
            );
        }
    });

    use_global_shortcut(cx, (keyCodeNumPadAdd, modifiers), {
        to_owned![state];
        move || {
            debounced_callback(
                || {
                    let value = state.read().settings.font_scale();
                    if value < FONT_SIZE_BIGGEST {
                        state.write().mutate(Action::SetFontScale(value + 0.25));
                    }
                },
                Duration::from_millis(500),
            );
        }
    });

    use_global_shortcut(cx, keyCodeAndModifierMinus, {
        to_owned![state];
        move || {
            debounced_callback(
                || {
                    let value = state.read().settings.font_scale();
                    if value > FONT_SIZE_SMALLEST {
                        state.write().mutate(Action::SetFontScale(value - 0.25));
                    }
                },
                Duration::from_millis(500),
            );
        }
    });

    None
}
