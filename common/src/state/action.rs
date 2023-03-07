use std::{collections::HashMap, rc::Weak};

use derive_more::Display;

use dioxus_desktop::{tao::window::WindowId, DesktopContext};
use either::Either;
use extensions::ExtensionProxy;
use uuid::Uuid;
use warp::raygun::Message;
use wry::webview::WebView;

use super::{
    chats::Chat,
    identity::Identity,
    notifications::NotificationKind,
    route::To,
    ui::{Theme, ToastNotification, WindowMeta},
    State,
};

pub type Callback = Box<dyn Fn(&State, &Action)>;

// Define a new struct to represent a hook that listens for a specific action type.
pub struct ActionHook {
    pub action_type: Either<Action, Vec<Action>>,
    pub callback: Callback,
}

/// used exclusively by State::mutate
#[derive(Display)]
pub enum Action {
    // Extensions
    #[display(fmt = "RegisterExtensions")]
    RegisterExtensions(HashMap<String, ExtensionProxy>),
    // UI
    #[display(fmt = "WindowMeta")]
    SetMeta(WindowMeta),
    // hang up for the active media stream
    #[display(fmt = "DisableMedia")]
    DisableMedia,
    #[display(fmt = "ToggleSilence")]
    ToggleSilence,
    #[display(fmt = "ToggleMute")]
    ToggleMute,
    #[display(fmt = "SidebarHidden: {_0}")]
    SidebarHidden(bool),
    #[display(fmt = "SetOverlay")]
    SetOverlay(bool),
    #[display(fmt = "AddToastNotification")]
    AddToastNotification(ToastNotification),
    #[display(fmt = "SetTheme")]
    SetTheme(Theme),
    #[display(fmt = "ClearTheme")]
    ClearTheme,
    // RemoveToastNotification,
    /// sets the active media to the corresponding conversation uuid
    #[display(fmt = "SetActiveMedia")]
    SetActiveMedia(Uuid),
    // Account
    /// Sets the ID for the user.
    #[display(fmt = "SetId")]
    SetId(Identity),
    /// adds an overlay. currently only used for demonstration purposes
    #[display(fmt = "AddOverlay")]
    AddOverlay(Weak<WebView>),
    /// used for the popout player or media player
    #[display(fmt = "SetPopout")]
    SetPopout(WindowId),
    #[display(fmt = "ClearPopout")]
    ClearPopout(DesktopContext),
    #[display(fmt = "SetDebugLogger")]
    SetDebugLogger(WindowId),
    #[display(fmt = "ClearDebugLogger")]
    ClearDebugLogger(DesktopContext),

    // Notifications
    #[display(fmt = "AddNotification")]
    AddNotification(NotificationKind, u32),
    #[display(fmt = "RemoveNotification")]
    RemoveNotification(NotificationKind, u32),
    #[display(fmt = "ClearNotification")]
    ClearNotification(NotificationKind),
    #[display(fmt = "ClearAllNotifications")]
    ClearAllNotifications,
    // Settings
    /// Sets the selected language.
    #[display(fmt = "SetLanguage")]
    SetLanguage(String),

    // Routes
    /// Set the active route
    #[display(fmt = "Navigate")]
    Navigate(To),
    // Requests
    /// Send a new friend request
    #[display(fmt = "SendRequest")]
    SendRequest(Identity),
    /// To be fired when a friend request you sent is accepted
    #[display(fmt = "RequestAccepted")]
    RequestAccepted(Identity),
    /// Cancel an outgoing request
    #[display(fmt = "CancelRequest")]
    CancelRequest(Identity),

    /// Handle a new incoming friend request
    // #[display(fmt = "IncomingRequest")]
    // IncomingRequest(Identity),
    /// Accept an incoming friend request
    #[display(fmt = "AcceptRequest")]
    AcceptRequest(Identity),
    /// Deny a incoming friend request
    #[display(fmt = "DenyRequest")]
    DenyRequest(Identity),

    // Friends
    #[display(fmt = "RemoveFriend")]
    RemoveFriend(Identity),
    #[display(fmt = "Block")]
    Block(Identity),
    #[display(fmt = "Unblock")]
    Unblock(Identity),
    /// Handles the display of "favorite" chats
    #[display(fmt = "Favorite")]
    Favorite(Chat),
    #[display(fmt = "UnFavorite")]
    UnFavorite(Uuid),
    /// Sets the active chat to a given chat
    #[display(fmt = "ChatWith")]
    ChatWith(Chat),
    /// Adds a chat to the sidebar
    #[display(fmt = "AddToSidebar")]
    AddToSidebar(Chat),
    /// Removes a chat from the sidebar, also removes the active chat if the chat being removed matches
    #[display(fmt = "RemoveFromSidebar")]
    RemoveFromSidebar(Uuid),
    /// Adds or removes a chat from the favorites page
    #[display(fmt = "ToggleFavorite")]
    ToggleFavorite(Chat),

    // Messaging
    /// Records a new message and plays associated notifications
    #[display(fmt = "NewMessage")]
    NewMessage(Chat, Message),
    /// React to a given message by ID
    /// conversation id, message id, reaction
    #[display(fmt = "AddReaction")]
    AddReaction(Uuid, Uuid, String),
    /// conversation id, message id, reaction
    #[display(fmt = "RemoveReaction")]
    RemoveReaction(Uuid, Uuid, String),
    /// Reply to a given message by ID
    #[display(fmt = "Reply")]
    Reply(Chat, Message),
    /// Prep the UI for a message reply.
    #[display(fmt = "StartReplying")]
    StartReplying(Chat, Message),
    /// Clears the reply for a given chat
    #[display(fmt = "CancelReply")]
    CancelReply(Uuid),
    /// fakes sending a message to the specified chat
    /// for normal operation, warp sends a message, Uplink receives an event when that message was sent, and state is updated accordingly.
    /// for mock data, warp is not used and this is needed to fake sending a message
    /// (Conversation Id, message)
    #[display(fmt = "MockSend")]
    MockSend(Uuid, Vec<String>),
    #[display(fmt = "ClearUnreads")]
    ClearUnreads(Chat),
    #[display(fmt = "ClearActiveUnreads")]
    ClearActiveUnreads,
    #[display(fmt = "Config {_0}")]
    Config(ConfigAction),
}

#[derive(Display)]
pub enum ConfigAction {
    #[display(fmt = "SetNotificationsEnabled {_0}")]
    SetNotificationsEnabled(bool),
    #[display(fmt = "SetTheme {_0}")]
    SetTheme(String),
    #[display(fmt = "SetOverlayEnabled {_0}")]
    SetOverlayEnabled(bool),
    #[display(fmt = "SetDevModeEnabled {_0}")]
    SetDevModeEnabled(bool),
    #[display(fmt = "SetInterfaceSoundsEnabled {_0}")]
    SetInterfaceSoundsEnabled(bool),
    #[display(fmt = "SetMediaSoundsEnabled {_0}")]
    SetMediaSoundsEnabled(bool),
    #[display(fmt = "SetMessageSoundsEnabled {_0}")]
    SetMessageSoundsEnabled(bool),
    #[display(fmt = "SetFriendsNotificationsEnabled {_0}")]
    SetFriendsNotificationsEnabled(bool),
    #[display(fmt = "SetMessagesNotificationsEnabled {_0}")]
    SetMessagesNotificationsEnabled(bool),
    #[display(fmt = "SetSettingsNotificationsEnabled {_0}")]
    SetSettingsNotificationsEnabled(bool),
    #[display(fmt = "SetAutoEnableExtensions {_0}")]
    SetAutoEnableExtensions(bool),
}

impl Action {
    pub fn compare_discriminant(&self, other: &Action) -> bool {
        std::mem::discriminant(self) == std::mem::discriminant(other)
    }
}
