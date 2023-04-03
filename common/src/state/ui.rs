use crate::icons::outline::Shape as Icon;
use dioxus_desktop::{tao::window::WindowId, DesktopContext};
use extensions::UplinkExtension;
use serde::{Deserialize, Serialize};
use std::{
    collections::{hash_map, HashMap, HashSet},
    rc::Weak,
};
use uuid::Uuid;
use wry::webview::WebView;

use super::notifications::Notifications;

#[derive(Debug, Clone, Default, Deserialize, Serialize, Eq, PartialEq)]
pub struct WindowMeta {
    pub focused: bool,
    pub maximized: bool,
    pub minimized: bool,
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
    // false: the media player is anchored in place
    // true: the media player can move around
    #[serde(skip)]
    pub popout_media_player: bool,
    #[serde(skip)]
    pub toast_notifications: HashMap<Uuid, ToastNotification>,
    pub theme: Option<Theme>,
    pub font: Option<Font>,
    #[serde(default = "default_font_scale")]
    font_scale: f32,
    pub enable_overlay: bool,
    pub active_welcome: bool,
    pub sidebar_hidden: bool,
    pub metadata: WindowMeta,
    #[serde(skip)]
    pub current_layout: Layout,
    // overlays or other windows are created via DesktopContext::new_window. they are stored here so they can be closed later.
    #[serde(skip)]
    pub overlays: Vec<Weak<WebView>>,
    #[serde(default)]
    pub extensions: Extensions,
    #[serde(skip)]
    pub file_previews: HashMap<Uuid, WindowId>,
    #[serde(default = "bool_true")]
    pub show_settings_welcome: bool,
    // Cached username used in login page
    pub cached_username: Option<String>,
}

#[derive(Default, Deserialize, Serialize)]
pub struct Extensions {
    #[serde(default)]
    enabled: HashSet<String>,
    #[serde(skip)]
    map: HashMap<String, UplinkExtension>,
}

impl Extensions {
    pub fn enable(&mut self, name: String) {
        self.enabled.insert(name.clone());
        if let Some(ext) = self.map.get_mut(&name) {
            ext.set_enabled(true)
        }
    }

    pub fn disable(&mut self, name: String) {
        self.enabled.remove(&name);
        if let Some(ext) = self.map.get_mut(&name) {
            ext.set_enabled(false)
        }
    }

    pub fn insert(&mut self, name: String, mut extension: UplinkExtension) {
        extension.set_enabled(self.enabled.contains(&name));
        self.map.insert(name, extension);
    }

    pub fn values(&self) -> hash_map::Values<String, UplinkExtension> {
        self.map.values()
    }
}

fn bool_true() -> bool {
    true
}

fn default_font_scale() -> f32 {
    1.0_f32
}

impl Drop for UI {
    fn drop(&mut self) {
        self.clear_overlays();
    }
}

impl UI {
    pub fn font_scale(&self) -> f32 {
        self.font_scale
    }
    pub fn set_font_scale(&mut self, scale: f32) {
        self.font_scale = scale;
    }
    fn take_call_popout_id(&mut self) -> Option<WindowId> {
        self.popout_media_player = false;
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

    pub fn get_meta(&self) -> WindowMeta {
        self.metadata.clone()
    }

    pub fn is_minimal_view(&self) -> bool {
        self.metadata.minimal_view
    }

    pub fn clear_call_popout(&mut self, desktop_context: &DesktopContext) {
        if let Some(id) = self.take_call_popout_id() {
            desktop_context.close_window(id);
        };
    }
    pub fn set_call_popout(&mut self, id: WindowId) {
        self.current_call = Some(Call::new(Some(id)));
        self.popout_media_player = true;
    }
    pub fn set_debug_logger(&mut self, id: WindowId) {
        self.current_debug_logger = Some(DebugLogger::new(Some(id)));
    }
    pub fn clear_debug_logger(&mut self, desktop_context: &DesktopContext) {
        if let Some(id) = self.take_debug_logger_id() {
            desktop_context.close_window(id);
        };
    }
    pub fn settings_welcome(&mut self) {
        self.active_welcome = true;
    }
    pub fn add_file_preview(&mut self, key: Uuid, window_id: WindowId) {
        self.file_previews.insert(key, window_id);
    }
    pub fn clear_file_previews(&mut self, desktop_context: &DesktopContext) {
        for (_, id) in self.file_previews.iter() {
            desktop_context.close_window(*id);
        }
    }

    pub fn clear_all_popout_windows(&mut self, desktop_context: &DesktopContext) {
        self.clear_file_previews(desktop_context);
        self.clear_debug_logger(desktop_context);
        self.clear_call_popout(desktop_context);
        self.clear_overlays();
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

#[derive(PartialEq, Clone, Debug, Default, Deserialize, Serialize)]
pub struct Font {
    pub name: String,
    pub path: String,
}
