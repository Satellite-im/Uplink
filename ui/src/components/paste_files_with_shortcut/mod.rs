use std::{
    path::PathBuf,
    sync::Mutex,
    time::{Duration, Instant},
};

use dioxus::prelude::{KeyCode, Props};
use dioxus_core::prelude::*;
use dioxus_desktop::use_global_shortcut;
use dioxus_desktop::wry::application::keyboard::ModifiersState;
use dioxus_hooks::{to_owned, use_future, use_ref};
use once_cell::sync::Lazy;
use tokio::time::sleep;

use crate::utils::clipboard::clipboard_data::get_files_path_from_clipboard;

static LAST_CALLED: Lazy<Mutex<Instant>> =
    Lazy::new(|| Mutex::new(Instant::now() - Duration::from_secs(2)));

fn debounced_callback<F: FnOnce()>(callback: F, debounce_duration: Duration) {
    let mut last_called = LAST_CALLED.lock().unwrap();
    let now = Instant::now();

    if now.duration_since(*last_called) > debounce_duration {
        callback();
        *last_called = now;
    }
}

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
    let command_pressed = use_ref(cx, || false);
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

    use_future(cx, (), |_| {
        to_owned![command_pressed, files_local_path_to_upload];
        async move {
            loop {
                if command_pressed.with(|i| *i) {
                    *command_pressed.write_silent() = false;
                    let files_local_path = get_files_path_from_clipboard().unwrap_or_default();
                    if !files_local_path.is_empty() {
                        files_local_path_to_upload.with_mut(|i| *i = files_local_path);
                    }
                };
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        }
    });

    use_global_shortcut(cx, (key, modifiers), {
        to_owned![files_local_path_to_upload, command_pressed];
        move || {
            let files_local_path = get_files_path_from_clipboard().unwrap_or_default();
            if files_local_path.iter().any(|path| {
                path.file_name()
                    .map_or(false, |f| f == "img_from_clipboard.png")
            }) {
                command_pressed.with_mut(|i| *i = true);
                // debounced_callback(
                //     || command_pressed.with_mut(|i| *i = true),
                //     Duration::from_secs(1),
                // );
            } else if !files_local_path.is_empty() {
                files_local_path_to_upload.with_mut(|i| *i = files_local_path);
            }
        }
    });
    None
}
