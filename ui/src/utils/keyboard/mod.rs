use common::state::settings::{key_code_to_str, modifier_state_to_string, GlobalShortcut};
use common::state::State;
use dioxus::prelude::*;
use dioxus_desktop::use_global_shortcut;
use dioxus_desktop::wry::application::keyboard::ModifiersState;
use once_cell::sync::Lazy;

use parking_lot::RwLock;

pub mod shortcut_handlers;

static CALL_COUNT: Lazy<RwLock<u32>> = Lazy::new(|| RwLock::new(0));

const NAVIGATE_AND_HIGHLIGHT_KEYBINDS: &str = include_str!("./navigate_and_highlight_keybinds.js");

#[derive(Props)]
pub struct Props<'a> {
    is_on_auth_pages: Option<bool>,
    on_global_shortcut: EventHandler<'a, GlobalShortcut>,
    // TODO: overrides: Vec<(String, String)> allow for overriding the default bindings
}

#[allow(non_snake_case)]
pub fn KeyboardShortcuts<'a>(cx: Scope<'a, Props>) -> Element<'a> {
    if cfg!(target_os = "linux") {
        return None;
    }

    if cx.props.is_on_auth_pages.unwrap_or(false) {
        let state = use_ref(cx, State::load);
        let keybinds = state.read().settings.keybinds.clone();
        return cx.render(rsx! {
            for (global_shortcut, shortcut) in keybinds {
                rsx!{
                    RenderGlobalShortCuts {
                        keys: shortcut.keys,
                        modifiers: shortcut.modifiers,
                        on_global_shortcut: move |global_shortcut: GlobalShortcut| {
                            // If global shortcuts are paused (for example, on the keybinds settings page) don't callback
                            cx.props.on_global_shortcut.call(global_shortcut);
                        },
                        global_shortcut: global_shortcut.clone(),
                    }
                }
            }
        });
    }

    let state = use_shared_state::<State>(cx)?;
    let eval = use_eval(cx);

    if !state.read().settings.pause_global_keybinds {
        let keybinds = state.read().settings.keybinds.clone();
        return cx.render(rsx! {
            for (global_shortcut, shortcut) in keybinds {
                rsx!{
                    RenderGlobalShortCuts {
                        keys: shortcut.keys,
                        modifiers: shortcut.modifiers,
                        on_global_shortcut: move |global_shortcut: GlobalShortcut| {
                            // If global shortcuts are paused (for example, on the keybinds settings page) don't callback
                            cx.props.on_global_shortcut.call(global_shortcut);
                        },
                        global_shortcut: global_shortcut.clone(),
                    }
                }
            }
        });
    } else if !state.read().settings.is_recording_new_keybind {
        let keybinds = state.read().settings.keybinds.clone();
        return cx.render(rsx! {
            for (global_shortcut, shortcut) in keybinds {
                rsx!{
                    RenderGlobalShortCuts {
                        keys: shortcut.keys,
                        modifiers: shortcut.modifiers,
                        on_global_shortcut: move |global_shortcut: GlobalShortcut| {
                                let scroll_script = NAVIGATE_AND_HIGHLIGHT_KEYBINDS.to_string().replace("$SHORTCUT_PRESSED", format!("{:?}", global_shortcut).as_str());
                                let _ = eval(&scroll_script);
                        },
                        global_shortcut: global_shortcut.clone(),
                    }
                }
            }
        });
    } else {
        println!("rendering keyboard shortcuts - 3");

        None
    }
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
        .map(|key_code| key_code_to_str(key_code).to_string())
        .collect();

    let modifier_strs: Vec<String> = cx
        .props
        .modifiers
        .iter()
        .map(|modifier| modifier_state_to_string(*modifier))
        .collect();

    let modifiers_and_keys = [modifier_strs.join(" + "), key_code_strs.join(" + ")].join(" + ");

    if modifiers_and_keys.contains("unknown") {
        return None;
    }

    use_global_shortcut(cx, modifiers_and_keys.as_str(), {
        to_owned![command_pressed];
        move || {
            *CALL_COUNT.write() += 1;

            if *CALL_COUNT.read() == 1 {
                command_pressed.with_mut(|i| *i = true);
            }

            if *CALL_COUNT.read() == 2 {
                *CALL_COUNT.write() = 0;
            }
        }
    });

    None
}
