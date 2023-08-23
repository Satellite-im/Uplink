use crate::icons::outline::Shape as Icon;
use dioxus_desktop::DesktopService;
use dioxus_desktop::{tao::window::WindowId, DesktopContext};
use extensions::UplinkExtension;
use serde::{Deserialize, Serialize};
use std::{
    collections::{hash_map, HashMap, HashSet},
    rc::Weak,
};
use uuid::Uuid;
use warp::logging::tracing::log;

use super::{call, notifications::Notifications};

pub type EmojiList = HashMap<String, u64>;

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

fn bool_true() -> bool {
    true
}

fn default_emojis() -> EmojiList {
    HashMap::from([
        ("👍".to_string(), 1),
        ("👎".to_string(), 1),
        ("❤️".to_string(), 1),
        ("🖖".to_string(), 1),
        ("😂".to_string(), 1),
    ])
}

/// Used to determine where the Emoji should be routed.
#[derive(Debug, Clone, Deserialize, Serialize, Eq, PartialEq)]
pub enum EmojiDestination {
    Chatbar,
    Message(Uuid),
}

impl Default for EmojiDestination {
    fn default() -> Self {
        Self::Chatbar
    }
}

#[derive(Deserialize, Serialize)]
pub struct UI {
    pub notifications: Notifications,
    // stores information related to the current call
    #[serde(skip)]
    pub call_info: call::CallInfo,
    #[serde(skip)]
    pub current_debug_logger: Option<DebugLogger>,
    // false: the media player is anchored in place
    // true: the media player can move around
    #[serde(skip)]
    pub popout_media_player: bool,
    #[serde(skip)]
    pub toast_notifications: HashMap<Uuid, ToastNotification>,
    pub accent_color: Option<(u8, u8, u8)>,
    pub theme: Option<Theme>,
    pub font: Option<Font>,
    pub enable_overlay: bool,
    pub active_welcome: bool,
    pub sidebar_hidden: bool,
    pub window_maximized: bool,
    pub window_width: u32,
    pub window_height: u32,
    pub metadata: WindowMeta,
    #[serde(default = "default_emojis")]
    pub emoji_list: EmojiList,
    pub emoji_destination: EmojiDestination,
    #[serde(skip)]
    pub current_layout: Layout,
    // overlays or other windows are created via DesktopContext::new_window. they are stored here so they can be closed later.
    #[serde(skip)]
    pub overlays: Vec<Weak<DesktopService>>,
    #[serde(default)]
    pub extensions: Extensions,
    #[serde(skip)]
    pub file_previews: HashMap<Uuid, WindowId>,
    #[serde(default = "bool_true")]
    pub show_settings_welcome: bool,
    // Cached username used in login page
    pub cached_username: Option<String>,
    #[serde(skip)]
    pub ignore_focus: bool,
}

impl Default for UI {
    fn default() -> Self {
        Self {
            notifications: Default::default(),
            call_info: Default::default(),
            current_debug_logger: Default::default(),
            popout_media_player: Default::default(),
            toast_notifications: Default::default(),
            accent_color: Default::default(),
            theme: Default::default(),
            font: Default::default(),
            enable_overlay: Default::default(),
            active_welcome: Default::default(),
            sidebar_hidden: Default::default(),
            window_maximized: Default::default(),
            window_width: Default::default(),
            window_height: Default::default(),
            metadata: Default::default(),
            emoji_list: default_emojis(),
            emoji_destination: Default::default(),
            current_layout: Default::default(),
            overlays: Default::default(),
            extensions: Default::default(),
            file_previews: Default::default(),
            show_settings_welcome: true,
            cached_username: Default::default(),
            ignore_focus: Default::default(),
        }
    }
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

impl Drop for UI {
    fn drop(&mut self) {
        self.clear_overlays();
    }
}

impl UI {
    pub fn track_emoji_usage(&mut self, emoji: String) {
        let count = self.emoji_list.entry(emoji).or_insert(0);
        *count += 1;
    }

    pub fn get_emoji_sorted_by_usage(&self) -> EmojiList {
        // let emojis = self.emoji_list.clone();

        // // emojis.sort_by(|a, b| b.1.cmp(&a.1));

        // emojis
        self.emoji_list.clone()
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
        self.call_info.set_popout_window_id(id);
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

    pub fn clear_all_popout_windows(&mut self, desktop_context: &DesktopContext) {
        self.clear_debug_logger(desktop_context);
        self.clear_call_popout(desktop_context);
        self.clear_overlays();
    }

    pub fn clear_overlays(&mut self) {
        for overlay in &self.overlays {
            if let Some(window) = Weak::upgrade(overlay) {
                window
                    .webview
                    .evaluate_script("close()")
                    .expect("failed to close webview");
            }
        }
        self.overlays.clear();
    }

    pub fn remove_overlay(&mut self, id: WindowId) {
        self.overlays.retain(|x| match Weak::upgrade(x) {
                None => false,
                Some(window) => {
                    if window.id() == id {
                        window
                            .webview
                            .evaluate_script("close()")
                            .expect("failed to close webview");
                        false
                    } else {
                        true
                    }
                }
            });
    }

    fn take_call_popout_id(&mut self) -> Option<WindowId> {
        self.popout_media_player = false;
        self.call_info.take_popout_window_id()
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

    pub fn toggle_muted(&mut self) {
        if let Err(e) = match self.call_info.active_call().map(|x| x.call.self_muted) {
            Some(true) => self.call_info.unmute_self(),
            Some(false) => self.call_info.mute_self(),
            _ => Ok(()),
        } {
            log::error!("failed to toggle_muted: {e}");
        }
    }

    pub fn toggle_silenced(&mut self) {
        if let Err(e) = match self.call_info.active_call().map(|x| x.call.call_silenced) {
            Some(true) => self.call_info.unsilence_call(),
            Some(false) => self.call_info.silence_call(),
            _ => Ok(()),
        } {
            log::error!("failed to toggle_silenced: {e}");
        }
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

#[derive(Eq, Clone, Debug, Default, Deserialize, Serialize)]
pub struct Theme {
    pub filename: String,
    pub name: String,
    pub styles: String,
}

impl PartialEq for Theme {
    fn eq(&self, other: &Self) -> bool {
        self.name.eq(&other.name)
    }
}

#[derive(PartialEq, Clone, Debug, Default, Deserialize, Serialize)]
pub struct Font {
    pub name: String,
    pub path: String,
}
