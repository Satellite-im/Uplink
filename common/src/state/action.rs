use std::{collections::HashMap, rc::Weak};

use derive_more::Display;

use dioxus_desktop::DesktopService;
use dioxus_desktop::{tao::window::WindowId, DesktopContext};
use extensions::UplinkExtension;
use uuid::Uuid;
use warp::crypto::DID;
use warp::raygun::Location;

use crate::warp_runner::ui_adapter;

use super::{
    call,
    identity::Identity,
    notifications::NotificationKind,
    route::To,
    ui::{EmojiDestination, Font, Theme, ToastNotification, WindowMeta},
};

/// used exclusively by State::mutate
#[derive(Display)]
pub enum Action<'a> {
    // Extensions
    #[display(fmt = "RegisterExtensions")]
    RegisterExtensions(HashMap<String, UplinkExtension>),
    #[display(fmt = "SetExtensionEnabled")]
    SetExtensionEnabled(String, bool),
    // UI
    #[display(fmt = "SetDevSettings {_0}")]
    SetDevSettings(bool),
    #[display(fmt = "SetAccentColor")]
    SetAccentColor((u8, u8, u8)),
    #[display(fmt = "ClearAccentColor")]
    ClearAccentColor,
    #[display(fmt = "WindowMeta")]
    SetMeta(WindowMeta),
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
    SetTheme(Option<Theme>),
    #[display(fmt = "SetFont")]
    SetFont(Option<Font>),
    #[display(fmt = "SetFontScale")]
    SetFontScale(f32),
    #[display(fmt = "TrackEmojiUsage")]
    TrackEmojiUsage(String),
    #[display(fmt = "SetEmojiPickerVisible")]
    SetEmojiPickerVisible(bool),
    #[display(fmt = "SetTransformMarkdownText")]
    SetTransformMarkdownText(bool),
    #[display(fmt = "SetTransformAsciiEmojis")]
    SetTransformAsciiEmojis(bool),
    // RemoveToastNotification,
    /// Sets the active call and active media id
    #[display(fmt = "AnswerCall")]
    AnswerCall(Uuid),
    #[display(fmt = "RejectCall")]
    RejectCall(Uuid),
    /// creates a Call struct and joins the call
    #[display(fmt = "OfferCall")]
    OfferCall(call::Call),
    #[display(fmt = "EndCall")]
    EndCall,
    // Account
    /// Sets the ID for the user.
    #[display(fmt = "SetId")]
    SetId(Identity),
    /// adds an overlay. currently only used for demonstration purposes
    #[display(fmt = "AddOverlay")]
    AddOverlay(Weak<DesktopService>),
    /// used for the popout player or media player
    #[display(fmt = "SetPopout")]
    SetCallPopout(WindowId),
    #[display(fmt = "ClearCallPopout")]
    ClearCallPopout(DesktopContext),
    #[display(fmt = "SetDebugLogger")]
    SetDebugLogger(WindowId),
    #[display(fmt = "ClearDebugLogger")]
    ClearDebugLogger(DesktopContext),
    #[display(fmt = "AddFilePreview")]
    AddFilePreview(Uuid, WindowId),
    #[display(fmt = "ForgetFilePreview")]
    ForgetFilePreview(Uuid),
    #[display(fmt = "ClearAllPopoutWindows")]
    ClearAllPopoutWindows(DesktopContext),
    // Notifications
    #[display(fmt = "AddNotification")]
    AddNotification(NotificationKind, u32),
    #[display(fmt = "RemoveNotification")]
    RemoveNotification(NotificationKind, u32),
    #[display(fmt = "ClearNotification")]
    ClearNotification(NotificationKind),
    #[display(fmt = "ClearAllNotifications")]
    ClearAllNotifications,
    #[display(fmt = "DismissUpdate")]
    DismissUpdate,
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
    CancelRequest(&'a DID),

    /// Accept an incoming friend request
    #[display(fmt = "AcceptRequest")]
    AcceptRequest(&'a Identity),
    /// Deny a incoming friend request
    #[display(fmt = "DenyRequest")]
    DenyRequest(&'a DID),

    // Friends
    #[display(fmt = "RemoveFriend")]
    RemoveFriend(&'a DID),
    #[display(fmt = "Block")]
    Block(&'a DID),
    #[display(fmt = "Unblock")]
    Unblock(&'a DID),
    /// Handles the display of "favorite" chats
    #[display(fmt = "Favorite")]
    Favorite(Uuid),
    #[display(fmt = "UnFavorite")]
    UnFavorite(Uuid),
    /// Sets the active chat to a given chat
    /// chat, should_move_to_top
    #[display(fmt = "ChatWith")]
    ChatWith(&'a Uuid, bool),
    /// Removes the active chat
    #[display(fmt = "ClearActiveChat")]
    ClearActiveChat,
    /// Removes a chat from the sidebar, also removes the active chat if the chat being removed matches
    #[display(fmt = "RemoveFromSidebar")]
    RemoveFromSidebar(Uuid),
    /// Adds or removes a chat from the favorites page
    #[display(fmt = "ToggleFavorite")]
    ToggleFavorite(&'a Uuid),
    // Messaging
    /// React to a given message by ID
    /// conversation id, message id, reaction
    #[display(fmt = "AddReaction")]
    AddReaction(Uuid, Uuid, String),
    /// conversation id, message id, reaction
    #[display(fmt = "RemoveReaction")]
    RemoveReaction(Uuid, Uuid, String),
    /// Sets the destination for emoji's
    #[display(fmt = "SetEmojiDestination")]
    SetEmojiDestination(Option<EmojiDestination>),
    /// chat id, message id
    #[display(fmt = "StartReplying")]
    StartReplying(&'a Uuid, &'a ui_adapter::Message),
    /// Sets a draft message for the chatbar for a given chat.
    #[display(fmt = "SetChatDraft")]
    SetChatDraft(Uuid, String),
    /// Sets a files attached to send
    #[display(fmt = "SetChatAttachments")]
    SetChatAttachments(Uuid, Vec<Location>),
    /// Clear attachments on chat
    #[display(fmt = "ClearChatAttachments")]
    ClearChatAttachments(Uuid),
    /// Clears a drafted message from a given chat.
    #[display(fmt = "ClearChatDraft")]
    ClearChatDraft(Uuid),
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
    ClearUnreads(Uuid),
    #[display(fmt = "ClearActiveUnreads")]
    ClearActiveUnreads,
    #[display(fmt = "Config {_0}")]
    Config(ConfigAction),
}

#[derive(Display)]
pub enum ConfigAction {
    #[display(fmt = "SetDyslexicEnabled {_0}")]
    SetDyslexicEnabled(bool),
    #[display(fmt = "SetNotificationsEnabled {_0}")]
    SetNotificationsEnabled(bool),
    #[display(fmt = "SetTheme {_0}")]
    SetTheme(String),
    #[display(fmt = "SetOverlayEnabled {_0}")]
    SetOverlayEnabled(bool),
    #[display(fmt = "SetDevModeEnabled {_0}")]
    SetDevModeEnabled(bool),
    #[display(fmt = "SetExperimentalFeaturesEnabled {_0}")]
    SetExperimentalFeaturesEnabled(bool),
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
