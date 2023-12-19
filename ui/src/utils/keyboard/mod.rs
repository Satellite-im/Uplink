use common::state::settings::GlobalShortcut;
use common::state::State;
use dioxus::prelude::*;
use dioxus_desktop::use_global_shortcut;
use dioxus_desktop::wry::application::keyboard::ModifiersState;
use once_cell::sync::Lazy;
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

pub mod shortcut_handlers;

// TODO: This fires once on key-down as well as key-up we should fix this in the future.
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

#[derive(Props)]
pub struct Props<'a> {
    on_global_shortcut: EventHandler<'a, GlobalShortcut>,
    // TODO: overrides: Vec<(String, String)> allow for overriding the default bindings
}

#[allow(non_snake_case)]
pub fn KeyboardShortcuts<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    if cfg!(target_os = "linux") {
        return None;
    }

    let state = use_shared_state::<State>(cx)?;
    let keybinds = common::state::default_keybinds::get_default_keybinds();

    let scroll_script_on_keybing_page = r#"
        const settings_keybind = document.getElementById('$SHORTCUT_PRESSED');
        settings_keybind.scrollIntoView({ behavior: 'smooth', block: 'start' });
    "#;
    let eval = use_eval(cx);

    cx.render(rsx! {
        for (global_shortcut, shortcut) in keybinds {
                rsx!{
                    RenderGlobalShortCuts {
                        keys: shortcut.keys,
                        modifiers: shortcut.modifiers,
                        on_global_shortcut: move |global_shortcut: GlobalShortcut| {
                            // If global shortcuts are paused (for example, on the keybinds settings page) don't callback
                            if !state.read().settings.pause_global_keybinds {
                                cx.props.on_global_shortcut.call(global_shortcut);
                            } else {
                                let scroll_script = scroll_script_on_keybing_page.to_string().replace("$SHORTCUT_PRESSED", format!("{:?}", global_shortcut).as_str());
                                let _ = eval(&scroll_script);
                            }
                        },
                        global_shortcut: global_shortcut.clone(),
                    }
                }
        }
    })
}

#[derive(Props)]
struct GlobalShortcutProps<'a> {
    keys: Vec<KeyCode>,
    modifiers: Vec<ModifiersState>,
    on_global_shortcut: EventHandler<'a, GlobalShortcut>,
    global_shortcut: GlobalShortcut,
}

fn RenderGlobalShortCuts<'a>(cx: Scope<'a, GlobalShortcutProps>) -> Element<'a> {
    let command_pressed = use_ref(cx, || false);

    if *command_pressed.read() {
        *command_pressed.write_silent() = false;
        cx.props
            .on_global_shortcut
            .call(cx.props.global_shortcut.clone());
    }

    let key_code_strs: Vec<String> = cx
        .props
        .keys
        .iter()
        .map(|key_code| {
            match key_code {
                KeyCode::V => "v",
                KeyCode::A => "a",
                KeyCode::M => "m",
                KeyCode::D => "d",
                KeyCode::EqualSign => "=",
                KeyCode::Subtract => "-",
                _ => "unknown",
                // ... Add other KeyCodes here
            }
            .to_string()
        })
        .collect();

    let modifier_strs: Vec<String> = cx
        .props
        .modifiers
        .iter()
        .map(|modifier| {
            match modifier.clone() {
                ModifiersState::SUPER => "command",
                ModifiersState::SHIFT => "shift",
                ModifiersState::CONTROL => "control",
                ModifiersState::ALT => "alt",
                _ => "unknown",
                // ... Add other modifiers here
            }
            .to_string()
        })
        .collect();

    let modifiers_and_keys = [modifier_strs.join(" + "), key_code_strs.join(" + ")].join(" + ");

    if modifiers_and_keys.contains("unknown") {
        return None;
    }
    use_global_shortcut(cx, modifiers_and_keys.as_str(), {
        to_owned![command_pressed];
        move || {
            debounced_callback(
                || {
                    command_pressed.with_mut(|i| *i = true);
                },
                Duration::from_millis(500),
            );
        }
    });

    None
}
