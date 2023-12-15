use common::state::settings::GlobalShortcut;
use common::state::State;
use dioxus::prelude::*;
use dioxus_desktop::use_global_shortcut;
use dioxus_desktop::wry::application::keyboard::ModifiersState;

pub mod shortcut_handlers;

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

    cx.render(rsx! {
        for (global_shortcut, shortcut) in keybinds {
                rsx!{
                    RenderGlobalShortCuts {
                        keys: shortcut.keys,
                        modifiers: shortcut.modifiers,
                        on_global_shortcut: move |global_shortcut| {
                            // If global shortcuts are paused (for example, on the keybinds settings page) don't callback
                            if !state.read().settings.pause_global_keybinds {
                                cx.props.on_global_shortcut.call(global_shortcut);
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
            command_pressed.with_mut(|i| *i = true);
        }
    });

    None
}
