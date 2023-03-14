use crate::icons::outline::Shape as Icon;
use dioxus_desktop::{tao::window::WindowId, DesktopContext};
use extensions::ExtensionProxy;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, rc::Weak};
use uuid::Uuid;
use wry::webview::WebView;

use super::notifications::Notifications;

#[derive(Debug, Clone, Default, Deserialize, Serialize, Eq, PartialEq)]
pub struct WindowMeta {
    pub focused: bool,
    pub maximized: bool,
    pub minimized: bool,
    pub width: u32,
    pub height: u32,
    pub minimal_view: bool, // We can use this to detect mobile or portrait mode
}

#[derive(Clone, Deserialize, Serialize, Eq, PartialEq)]
pub enum Layout {
    Welcome,
    Compose,
    Friends,
    Settings,
    Storage,
}

impl Default for Layout {
    fn default() -> Self {
        Self::Welcome
    }
}

#[derive(Default, Deserialize, Serialize)]
pub struct UI {
    pub notifications: Notifications,
    // stores information related to the current call
    #[serde(skip)]
    pub current_call: Option<Call>,
    #[serde(skip)]
    pub current_debug_logger: Option<DebugLogger>,
    #[serde(skip)]
    pub current_file_preview: Option<FilePreview>,
    // false: the media player is anchored in place
    // true: the media player can move around
    #[serde(skip)]
    pub popout_player: bool,
    pub popout_windows_id: Option<AllPopoutWindowsId>,
    #[serde(skip)]
    pub toast_notifications: HashMap<Uuid, ToastNotification>,
    pub theme: Option<Theme>,
    pub enable_overlay: bool,
    pub sidebar_hidden: bool,
    pub metadata: WindowMeta,
    #[serde(skip)]
    pub current_layout: Layout,
    // overlays or other windows are created via DesktopContext::new_window. they are stored here so they can be closed later.
    #[serde(skip)]
    pub overlays: Vec<Weak<WebView>>,
    #[serde(skip)]
    pub extensions: HashMap<String, ExtensionProxy>,
    #[serde(default = "bool_true")]
    pub show_settings_welcome: bool,
}

fn bool_true() -> bool {
    true
}

impl Drop for UI {
    fn drop(&mut self) {
        self.clear_overlays();
    }
}

impl UI {
    fn take_all_popout_ids(&mut self) -> Vec<Option<WindowId>> {
        match self.popout_windows_id.take() {
            Some(all_popout_windows_id) => {
                let ids = all_popout_windows_id.popout_windows_id.clone();
                self.popout_windows_id = Some(all_popout_windows_id);
                ids
            }
            None => Vec::new(),
        }
    }

    fn take_popout_id(&mut self) -> Option<WindowId> {
        self.popout_player = false;
        match self.current_call.take() {
            Some(mut call) => {
                let id = call.take_window_id();
                self.current_call = Some(call);
                id
            }
            None => None,
        }
    }

    fn take_debug_logger_id(&mut self) -> Option<WindowId> {
        match self.current_debug_logger.take() {
            Some(mut debug_logger) => {
                let id = debug_logger.take_window_id();
                self.current_debug_logger = None;
                id
            }
            None => None,
        }
    }

    fn take_file_preview_id(&mut self) -> Option<WindowId> {
        match self.current_file_preview.take() {
            Some(mut file_preview) => {
                let id = file_preview.take_window_id();
                self.current_file_preview = None;
                id
            }
            None => None,
        }
    }

    pub fn get_meta(&self) -> WindowMeta {
        self.metadata.clone()
    }

    pub fn is_minimal_view(&self) -> bool {
        self.metadata.minimal_view
    }

    pub fn clear_popout(&mut self, desktop_context: DesktopContext) {
        if let Some(id) = self.take_popout_id() {
            desktop_context.close_window(id);
        };
    }
    pub fn set_popout(&mut self, id: WindowId) {
        self.current_call = Some(Call::new(Some(id)));
        self.popout_windows_id = Some(AllPopoutWindowsId::add_one(
            self.popout_windows_id.clone(),
            Some(id),
        ));
        self.popout_player = true;
    }
    pub fn set_debug_logger(&mut self, id: WindowId) {
        self.current_debug_logger = Some(DebugLogger::new(Some(id)));
        self.popout_windows_id = Some(AllPopoutWindowsId::add_one(
            self.popout_windows_id.clone(),
            Some(id),
        ));
    }
    pub fn clear_debug_logger(&mut self, desktop_context: DesktopContext) {
        if let Some(id) = self.take_debug_logger_id() {
            desktop_context.close_window(id);
        };
    }
    pub fn set_file_preview(&mut self, id: WindowId) {
        self.current_file_preview = Some(FilePreview::new(Some(id)));
        self.popout_windows_id = Some(AllPopoutWindowsId::add_one(
            self.popout_windows_id.clone(),
            Some(id),
        ));
    }
    pub fn clear_file_preview(&mut self, desktop_context: DesktopContext) {
        if let Some(id) = self.take_file_preview_id() {
            desktop_context.close_window(id);
        };
    }

    pub fn clear_all_popout_windows(&mut self, desktop_context: DesktopContext) {
        for id in self.take_all_popout_ids() {
            if let Some(id) = id {
                desktop_context.close_window(id);
            };
        }
    }
    pub fn clear_overlays(&mut self) {
        for overlay in &self.overlays {
            if let Some(window) = Weak::upgrade(overlay) {
                window
                    .evaluate_script("close()")
                    .expect("failed to close webview");
            }
        }
        self.overlays.clear();
    }
    pub fn remove_overlay(&mut self, id: WindowId) {
        let to_keep: Vec<Weak<WebView>> = self
            .overlays
            .iter()
            .filter(|x| match Weak::upgrade(x) {
                None => false,
                Some(window) => {
                    if window.window().id() == id {
                        window
                            .evaluate_script("close()")
                            .expect("failed to close webview");
                        false
                    } else {
                        true
                    }
                }
            })
            .cloned()
            .collect();
        self.overlays = to_keep;
    }

    pub fn toggle_muted(&mut self) {
        self.current_call = self.current_call.clone().map(|mut x| {
            x.muted = !x.muted;
            x
        });
    }

    pub fn toggle_silenced(&mut self) {
        self.current_call = self.current_call.clone().map(|mut x| {
            x.silenced = !x.silenced;
            x
        });
    }
}

#[derive(Clone, Default, Deserialize, Serialize)]
pub struct AllPopoutWindowsId {
    #[serde(skip)]
    pub popout_windows_id: Vec<Option<WindowId>>,
}

impl AllPopoutWindowsId {
    pub fn add_one(
        all_popout_windows_id: Option<AllPopoutWindowsId>,
        new_window_id: Option<WindowId>,
    ) -> Self {
        let mut windows_id = Vec::new();
        if let Some(data) = all_popout_windows_id {
            windows_id = data.popout_windows_id;
        }
        windows_id.push(new_window_id);
        Self {
            popout_windows_id: windows_id,
        }
    }
}

#[derive(Clone, Default, Deserialize, Serialize)]
pub struct Call {
    // displays the current  video stream
    // may need changing later to accommodate video streams from multiple participants
    #[serde(skip)]
    pub popout_window_id: Option<WindowId>,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub silenced: bool,
}

impl Call {
    pub fn new(popout_window_id: Option<WindowId>) -> Self {
        Self {
            popout_window_id,
            muted: false,
            silenced: false,
        }
    }

    pub fn take_window_id(&mut self) -> Option<WindowId> {
        self.popout_window_id.take()
    }
}

#[derive(Clone, Default, Deserialize, Serialize)]
pub struct DebugLogger {
    #[serde(skip)]
    pub debug_logger_window_id: Option<WindowId>,
}

impl DebugLogger {
    pub fn new(popout_window_id: Option<WindowId>) -> Self {
        Self {
            debug_logger_window_id: popout_window_id,
        }
    }

    pub fn take_window_id(&mut self) -> Option<WindowId> {
        self.debug_logger_window_id.take()
    }
}

#[derive(Clone, Default, Deserialize, Serialize)]
pub struct FilePreview {
    #[serde(skip)]
    pub file_preview_window_id: Option<WindowId>,
}

impl FilePreview {
    pub fn new(file_preview_window_id: Option<WindowId>) -> Self {
        Self {
            file_preview_window_id,
        }
    }

    pub fn take_window_id(&mut self) -> Option<WindowId> {
        self.file_preview_window_id.take()
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct ToastNotification {
    pub title: String,
    pub content: String,
    initial_time: u32,
    remaining_time: u32,
    #[serde(skip)]
    pub icon: Option<Icon>,
}

impl ToastNotification {
    pub fn init(title: String, content: String, icon: Option<Icon>, timeout: u32) -> Self {
        Self {
            title,
            content,
            icon,
            initial_time: timeout,
            remaining_time: timeout,
        }
    }
    pub fn remaining_time(&self) -> u32 {
        self.remaining_time
    }

    pub fn reset_time(&mut self) {
        self.remaining_time = self.initial_time
    }

    pub fn decrement_time(&mut self) {
        if self.remaining_time > 0 {
            self.remaining_time -= 1;
        }
    }
}

#[derive(PartialEq, Clone, Debug, Default, Deserialize, Serialize)]
pub struct Theme {
    pub filename: String,
    pub name: String,
    pub styles: String,
}
