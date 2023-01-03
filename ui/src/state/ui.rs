use chrono::{DateTime, Utc};
use kit::icons::Icon;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;
use warp::{crypto::DID, raygun::Message};

#[derive(Clone, Default, Deserialize, Serialize)]
pub struct UI {
    // things like the overlay and popout player get created via DesktopContext::new_window. they are stored here so they can be closed later.
    // #[serde(skip)]
    //pub windows: Vec<Weak<WebView>>,
    // Should the active video play in popout?
    #[serde(default)]
    pub popout_player: bool,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub silenced: bool,
    #[serde(skip)]
    pub toast_notifications: HashMap<Uuid, ToastNotification>,
    #[serde(default)]
    pub theme: Option<Theme>,
    #[serde(default)]
    pub enable_overlay: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct ToastNotification {
    pub title: String,
    pub content: String,
    #[serde(skip)]
    pub icon: Option<Icon>,
    initial_time: u32,
    remaining_time: u32,
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
