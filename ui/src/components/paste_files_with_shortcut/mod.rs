use dioxus::prelude::{KeyCode, Props};
use dioxus_core::prelude::*;
use dioxus_desktop::use_global_shortcut;
use dioxus_desktop::wry::application::keyboard::ModifiersState;
use dioxus_hooks::{to_owned, use_ref};

#[derive(Props)]
pub struct ShortCutProps<'a> {
    on_paste: EventHandler<'a, bool>,
}

// HACK: It is not allowed to put hooks inside conditional,
// and global shortcut keeps working after unfocus app,
// then solution was to put it into a fake UI, to be build or dropped
// depending on if app is focused or not.
/// It needs app focus verification to use,
/// because component needs to drop when app lost focus
///
/// It only works for windows and macos
///
/// ### Example:
///
/// ```rust
/// if state.read().ui.metadata.focused {
///    rsx!(PasteFilesShortcut {
///        on_paste: move |files_local_path| {
///            add_files_in_queue_to_upload(&files_in_queue_to_upload, files_local_path, &window);
///            upload_file_controller.files_been_uploaded.with_mut(|i| *i = true);
///        },
///    })
/// }
/// ```
#[allow(non_snake_case)]
pub fn PasteFilesShortcut<'a>(cx: Scope<'a, ShortCutProps>) -> Element<'a> {
    if cfg!(target_os = "linux") {
        return None;
    }

    let key = KeyCode::V;
    let modifiers = if cfg!(target_os = "macos") {
        ModifiersState::SUPER
    } else {
        ModifiersState::CONTROL
    };

    let paste_command_was_pressed = use_ref(cx, || false);

    if *paste_command_was_pressed.read() {
        *paste_command_was_pressed.write_silent() = false;
        cx.props.on_paste.call(true);
    }

    use_global_shortcut(cx, (key, modifiers), {
        to_owned![paste_command_was_pressed];
        move || {
            paste_command_was_pressed.with_mut(|i| *i = true);
        }
    });
    None
}
