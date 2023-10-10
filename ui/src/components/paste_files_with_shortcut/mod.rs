use std::path::PathBuf;

use dioxus::prelude::{KeyCode, Props};
use dioxus_core::prelude::*;
use dioxus_desktop::use_global_shortcut;
use dioxus_desktop::wry::application::keyboard::ModifiersState;
use dioxus_hooks::{to_owned, use_ref};

use crate::utils::clipboard::clipboard_data::get_files_path_from_clipboard;

#[derive(Props)]
pub struct ShortCutProps<'a> {
    on_paste: EventHandler<'a, Vec<PathBuf>>,
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
    let files_local_path_to_upload = use_ref(cx, Vec::new);
    let key = KeyCode::V;
    let modifiers = if cfg!(target_os = "macos") {
        ModifiersState::SUPER
    } else {
        ModifiersState::CONTROL
    };

    if !files_local_path_to_upload.read().is_empty() {
        cx.props
            .on_paste
            .call(files_local_path_to_upload.read().clone());
        *files_local_path_to_upload.write_silent() = Vec::new();
    }

    use_global_shortcut(cx, (key, modifiers), {
        to_owned![files_local_path_to_upload];
        move || {
            let files_local_path = get_files_path_from_clipboard().unwrap_or_default();
            if !files_local_path.is_empty() {
                files_local_path_to_upload.with_mut(|i| *i = files_local_path);
            }
        }
    });
    None
}
