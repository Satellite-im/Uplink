use chrono::{DateTime, Utc};
use either::Either;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs,
    hash::Hash,
};

use uuid::Uuid;
use warp::{
    constellation::item::Item,
    crypto::DID,
    multipass::identity::{Identity as WarpIdentity, IdentityStatus, Platform},
    raygun::{Message, Reaction},
};

use kit::icons::Icon;

#[derive(Eq, PartialEq)]
pub struct MessageDivider {
    pub timestamp: Option<DateTime<Utc>>,
}

impl Ord for MessageDivider {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.timestamp.cmp(&other.timestamp)
    }
}

impl PartialOrd for MessageDivider {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

pub enum Direction {
    Incoming,
    Outgoing,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct ToastNotification {
    pub title: String,
    pub content: String,
    #[serde(skip_serializing, skip_deserializing)]
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

// Define a struct to represent a group of messages from the same sender.
pub struct MessageGroup {
    pub sender: DID,
    pub remote: bool,
    pub messages: Vec<GroupedMessage>,
}

// Define a struct to represent a message that has been placed into a group.
pub struct GroupedMessage {
    pub message: Message,
    pub is_first: bool,
    pub is_last: bool,
}

pub type Callback = Box<dyn Fn(&State, &Action)>;

// Define a new struct to represent a hook that listens for a specific action type.
pub struct ActionHook {
    action_type: Either<Action, Vec<Action>>,
    callback: Callback,
}

/// Alias for the type representing a route.
pub type To = String;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Account {
    #[serde(default)]
    pub identity: Identity,
    // pub settings: Option<CustomSettings>,
    // pub profile: Option<Profile>,
}

#[derive(Serialize, Deserialize, Debug, Clone, Eq)]
pub struct Identity {
    identity: WarpIdentity,
    status: IdentityStatus,
    platform: Platform,
}

impl Hash for Identity {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.identity.hash(state)
    }
}

impl PartialEq for Identity {
    fn eq(&self, other: &Self) -> bool {
        self.identity.eq(&other.identity)
            && self.status.eq(&other.status)
            && self.platform.eq(&other.platform)
    }
}

impl Default for Identity {
    fn default() -> Self {
        Self::from(WarpIdentity::default())
    }
}

impl From<WarpIdentity> for Identity {
    fn from(identity: WarpIdentity) -> Self {
        Identity {
            identity,
            status: IdentityStatus::Offline,
            platform: Default::default(),
        }
    }
}

impl core::ops::Deref for Identity {
    type Target = WarpIdentity;
    fn deref(&self) -> &Self::Target {
        &self.identity
    }
}

impl core::ops::DerefMut for Identity {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.identity
    }
}

impl Identity {
    pub fn identity_status(&self) -> IdentityStatus {
        self.status
    }

    pub fn platform(&self) -> Platform {
        self.platform
    }
}

impl Identity {
    pub fn set_identity_status(&mut self, status: IdentityStatus) {
        self.status = status;
    }

    pub fn set_platform(&mut self, platform: Platform) {
        self.platform = platform;
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Route {
    // String representation of the current active route.
    #[serde(default)]
    pub active: To,
}

#[derive(Clone, Debug, PartialEq, Eq, Default, Deserialize, Serialize)]
pub struct Chat {
    // Warp generated UUID of the chat
    // TODO: This should be wired up to warp conversation id's
    #[serde(default)]
    pub id: Uuid,
    // Warp generated UUID of the chat
    #[serde(default)]
    pub active_media: bool, // TODO: in the future, this should probably be a vec of media streams or something
    // Includes the list of participants within a given chat.
    #[serde(default)]
    pub participants: Vec<Identity>,
    // Messages should only contain messages we want to render. Do not include the entire message history.
    #[serde(default)]
    pub messages: Vec<Message>,
    // Unread count for this chat, should be cleared when we view the chat.
    #[serde(default)]
    pub unreads: u32,
    // If a value exists, we will render the message we're replying to above the chatbar
    #[serde(default)]
    pub replying_to: Option<Message>,
}

// TODO: Properly wrap data which is expected to persist remotely in options, so we can know if we're still figuring out what exists "remotely", i.e. loading.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Chats {
    // All active chats from warp.
    #[serde(default)]
    pub all: HashMap<Uuid, Chat>,
    // Chat to display / interact with currently.
    #[serde(default)]
    pub active: Option<Uuid>,
    // Chats to show in the sidebar
    #[serde(default)]
    pub in_sidebar: Vec<Uuid>,
    // Favorite Chats
    #[serde(default)]
    pub favorites: Vec<Uuid>,
}

// TODO: Properly wrap data which is expected to persist remotely in options, so we can know if we're still figuring out what exists "remotely", i.e. loading.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Friends {
    // All active friends.
    #[serde(default)]
    pub all: HashMap<DID, Identity>,
    // List of friends the user has blocked
    #[serde(default)]
    pub blocked: Vec<Identity>,
    // Friend requests, incoming and outgoing.
    #[serde(default)]
    pub incoming_requests: Vec<Identity>,
    #[serde(default)]
    pub outgoing_requests: Vec<Identity>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Files {
    // All files
    #[serde(default)]
    pub all: Vec<Item>,
    // Optional, active folder.
    #[serde(default)]
    pub active_folder: Option<Item>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Settings {
    // Selected Language
    #[serde(default)]
    pub language: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct UI {
    // Should the active video play in popout?
    #[serde(default)]
    pub popout_player: bool,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub silenced: bool,
    #[serde(skip_serializing, skip_deserializing)]
    pub toast_notifications: HashMap<Uuid, ToastNotification>,
    #[serde(default)]
    pub theme: Option<Theme>,
    #[serde(default)]
    pub enable_overlay: bool,
}

use std::fmt;

use crate::testing::mock::generate_mock;

#[derive(Default, Deserialize, Serialize)]
pub struct State {
    #[serde(default)]
    pub account: Account,
    #[serde(default)]
    pub route: Route,
    #[serde(default)]
    pub chats: Chats,
    #[serde(default)]
    pub friends: Friends,
    #[serde(default)]
    pub settings: Settings,
    #[serde(default)]
    pub ui: UI,
    #[serde(skip_serializing, skip_deserializing)]
    pub(crate) hooks: Vec<ActionHook>,
}

impl fmt::Debug for State {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("State")
            .field("account", &self.account)
            .field("route", &self.route)
            .field("chats", &self.chats)
            .field("friends", &self.friends)
            .field("hooks count", &self.hooks.len())
            .finish()
    }
}

impl Clone for State {
    fn clone(&self) -> Self {
        State {
            account: self.account.clone(),
            route: self.route.clone(),
            chats: self.chats.clone(),
            friends: self.friends.clone(),
            hooks: Default::default(),
            settings: Default::default(),
            ui: Default::default(),
        }
    }
}

// This code defines a number of methods for the State struct, which are used to mutate the state in a controlled manner.
// For example, the set_active_chat method sets the active chat in the State struct, and the toggle_favorite method adds or removes a chat from the user's favorites.
//  These methods are used to update the relevant fields within the State struct in response to user actions or other events within the application.
impl State {
    /// Constructs a new `State` instance with default values.
    pub fn new() -> Self {
        State::default()
    }

    pub fn set_theme(&mut self, theme: Option<Theme>) {
        self.ui.theme = theme;
    }

    /// Sets the active chat in the `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to set as the active chat.
    fn set_active_chat(&mut self, chat: &Chat) {
        self.chats.active = Some(chat.id);
        if !self.chats.in_sidebar.contains(&chat.id) {
            self.chats.in_sidebar.push(chat.id);
        }
    }

    /// Clears the active chat in the `State` struct.
    fn clear_active_chat(&mut self) {
        self.chats.active = None;
    }

    /// Updates the display of the overlay
    fn toggle_overlay(&mut self, enabled: bool) {
        self.ui.enable_overlay = enabled;
    }

    /// Toggles the display of media on the provided chat in the `State` struct.
    fn toggle_media(&mut self, chat: &Chat) {
        if let Some(c) = self.chats.all.get_mut(&chat.id) {
            c.active_media = !c.active_media;
            // When we "close" active media, we should hide the popout player.
            if !c.active_media {
                self.ui.popout_player = false;
            }
        }
    }

    fn disable_all_active_media(&mut self) {
        for (_, chat) in self.chats.all.iter_mut() {
            chat.active_media = false;
        }
        self.ui.popout_player = false;
    }

    /// Adds a chat to the sidebar in the `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to add to the sidebar.
    fn add_chat_to_sidebar(&mut self, chat: Chat) {
        if !self.chats.in_sidebar.contains(&chat.id) {
            self.chats.in_sidebar.push(chat.id);
        }
    }

    /// Sets the active route in the `State` struct.
    ///
    /// # Arguments
    ///
    /// * `to` - The route to set as the active route.
    fn set_active_route(&mut self, to: String) {
        self.route.active = to;
    }

    /// Adds the given chat to the user's favorites.
    fn favorite(&mut self, chat: &Chat) {
        if !self.chats.favorites.contains(&chat.id) {
            self.chats.favorites.push(chat.id);
        }
    }

    /// Removes the given chat from the user's favorites.
    fn unfavorite(&mut self, chat: &Chat) {
        if let Some(index) = self.chats.favorites.iter().position(|uid| *uid == chat.id) {
            self.chats.favorites.remove(index);
        }
    }

    /// Toggles the specified chat as a favorite in the `State` struct. If the chat
    /// is already a favorite, it is removed from the favorites list. Otherwise, it
    /// is added to the list.
    fn toggle_favorite(&mut self, chat: &Chat) {
        let faves = &mut self.chats.favorites;

        if faves.contains(&chat.id) {
            if let Some(index) = faves.iter().position(|uid| *uid == chat.id) {
                faves.remove(index);
            }
        } else {
            faves.push(chat.id);
        }
    }

    /// Begins replying to a message in the specified chat in the `State` struct.
    fn start_replying(&mut self, chat: &Chat, message: &Message) {
        let mut c = match self.chats.all.get_mut(&chat.id) {
            Some(chat) => chat.clone(),
            None => return,
        };
        c.replying_to = Some(message.to_owned());

        *self.chats.all.get_mut(&chat.id).unwrap() = c;
    }

    /// Cancels a reply within a given chat on `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to stop replying to.
    fn cancel_reply(&mut self, chat: &Chat) {
        let mut c = match self.chats.all.get_mut(&chat.id) {
            Some(chat) => chat.clone(),
            None => return,
        };
        c.replying_to = None;

        *self.chats.all.get_mut(&chat.id).unwrap() = c;
    }

    /// Clear unreads  within a given chat on `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to clear unreads on.
    ///
    fn clear_unreads(&mut self, chat: &Chat) {
        if let Some(chat) = self.chats.all.get_mut(&chat.id) {
            chat.unreads = 0;
        }
    }

    /// Remove a chat from the sidebar on `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to remove.
    fn remove_sidebar_chat(&mut self, chat: &Chat) {
        if self.chats.in_sidebar.contains(&chat.id) {
            let index = self
                .chats
                .in_sidebar
                .iter()
                .position(|x| *x == chat.id)
                .unwrap();
            self.chats.in_sidebar.remove(index);
        }

        if self.chats.active.is_some() && self.get_active_chat().unwrap_or_default().id == chat.id {
            self.clear_active_chat();
        }
    }

    /// Sets the user's identity.
    fn set_identity(&mut self, identity: &Identity) {
        self.account.identity = identity.clone();
    }

    /// Sets the user's language.
    fn set_language(&mut self, string: &str) {
        self.settings.language = string.to_string();
    }

    fn cancel_request(&mut self, direction: Direction, identity: &Identity) {
        match direction {
            Direction::Outgoing => {
                self.friends
                    .outgoing_requests
                    .retain(|friend| friend.did_key() != identity.did_key());
            }
            Direction::Incoming => {
                self.friends
                    .incoming_requests
                    .retain(|friend| friend.did_key() != identity.did_key());
            }
        }
    }

    fn complete_request(&mut self, direction: Direction, identity: &Identity) {
        match direction {
            Direction::Outgoing => {
                self.friends
                    .outgoing_requests
                    .retain(|friend| friend.did_key() != identity.did_key());
                self.friends
                    .all
                    .insert(identity.did_key(), identity.clone());
            }
            Direction::Incoming => {
                self.friends
                    .incoming_requests
                    .retain(|friend| friend.did_key() != identity.did_key());
                self.friends
                    .all
                    .insert(identity.did_key(), identity.clone());
            }
        }
    }

    fn new_incoming_request(&mut self, identity: &Identity) {
        self.friends.incoming_requests.push(identity.clone());
    }

    fn toggle_popout(&mut self) {
        self.ui.popout_player = !self.ui.popout_player;
    }

    fn new_outgoing_request(&mut self, identity: &Identity) {
        self.friends.outgoing_requests.push(identity.clone());
    }

    fn block(&mut self, identity: &Identity) {
        // If the identity is not already blocked, add it to the blocked list
        if !self.friends.blocked.contains(identity) {
            self.friends.blocked.push(identity.clone());
        }

        // Remove the identity from the outgoing requests list if they are present
        self.friends
            .outgoing_requests
            .retain(|friend| friend.did_key() != identity.did_key());

        // Remove the identity from the friends list if they are present
        self.remove_friend(&identity.did_key());
    }

    fn unblock(&mut self, identity: &Identity) {
        // Find the index of the identity in the blocked list
        let index = self.friends.blocked.iter().position(|x| *x == *identity);
        // If the identity is in the blocked list, remove it
        if let Some(i) = index {
            self.friends.blocked.remove(i);
        }
    }

    fn remove_friend(&mut self, did: &DID) {
        // Remove the friend from the all field of the friends struct
        self.friends.all.remove(did);

        let all_chats = self.chats.all.clone();

        // Check if there is a direct chat with the friend being removed
        let direct_chat = all_chats.values().find(|chat| {
            chat.participants.len() == 2
                && chat
                    .participants
                    .iter()
                    .any(|participant| participant.did_key() == *did)
        });

        // Remove the chat from the sidebar
        if let Some(chat) = direct_chat {
            self.remove_sidebar_chat(chat);
        }

        // If the friend's direct chat is currently the active chat, clear the active chat
        // TODO: Use `if let` statements
        if self.chats.active.is_some()
            && self.get_active_chat().unwrap_or_default().id == direct_chat.unwrap().id
        {
            self.clear_active_chat();
        }

        // Remove chat from favorites if it exists
        if let Some(direct_chat) = direct_chat {
            if self.chats.favorites.contains(&direct_chat.id) {
                self.unfavorite(direct_chat);
            }
        }
    }

    fn toggle_mute(&mut self) {
        self.ui.muted = !self.ui.muted;
    }

    fn toggle_silence(&mut self) {
        self.ui.silenced = !self.ui.silenced;
    }

    /// Getters
    /// Getters are the only public facing methods besides dispatch.
    /// Getters help retrieve data from state in common ways preventing reused code.

    pub fn is_me(&self, identity: &Identity) -> bool {
        identity.did_key().to_string() == self.account.identity.did_key().to_string()
    }

    /// Check if given chat is favorite on `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to check.
    pub fn is_favorite(&self, chat: &Chat) -> bool {
        self.chats.favorites.contains(&chat.id)
    }

    /// Get the active chat on `State` struct.
    pub fn get_active_chat(&self) -> Option<Chat> {
        match self.chats.active {
            Some(uuid) => self.chats.all.get(&uuid).cloned(),
            None => None,
        }
    }

    pub fn get_active_media_chat(&self) -> Option<&Chat> {
        self.chats.all.values().find(|&chat| chat.active_media)
    }

    pub fn get_chat_with_friend(&self, friend: &Identity) -> Chat {
        let chat = self
            .chats
            .all
            .values()
            .find(|chat| chat.participants.len() == 2 && chat.participants.contains(friend));

        chat.unwrap_or(&Chat::default()).clone()
    }

    pub fn get_without_me(&self, identities: Vec<Identity>) -> Vec<Identity> {
        let mut set = HashSet::new();
        set.insert(&self.account.identity);

        identities
            .into_iter()
            .filter(|identity| !set.contains(identity))
            .collect()
    }

    pub fn has_friend_with_did(&self, did: &DID) -> bool {
        self.friends
            .all
            .values()
            .any(|identity| identity.did_key() == *did)
    }

    // Define a method for sorting a vector of messages.
    pub fn get_sort_messages(&self, chat: &Chat) -> Vec<MessageGroup> {
        let mut message_groups = Vec::new();
        let current_sender = chat.messages[0].sender(); // TODO: This could error in runtime
        let mut current_group = MessageGroup {
            remote: self.has_friend_with_did(&current_sender),
            sender: current_sender,
            messages: Vec::new(),
        };

        for message in chat.messages.clone() {
            if message.sender() != current_group.sender {
                message_groups.push(current_group);
                current_group = MessageGroup {
                    remote: self.has_friend_with_did(&message.sender()),
                    sender: message.sender(),
                    messages: Vec::new(),
                };
            }

            current_group.messages.push(GroupedMessage {
                message,
                is_first: current_group.messages.is_empty(),
                is_last: false,
            });
        }

        if !current_group.messages.is_empty() {
            current_group.messages.last_mut().unwrap().is_last = true;
            message_groups.push(current_group);
        }

        message_groups
    }

    pub fn get_friend_identity(&self, did: &DID) -> Identity {
        self.friends.all.get(did).cloned().unwrap_or_default()
    }

    pub fn get_friends_by_first_letter(
        friends: HashMap<DID, Identity>,
    ) -> BTreeMap<char, Vec<Identity>> {
        let mut friends_by_first_letter: BTreeMap<char, Vec<Identity>> = BTreeMap::new();

        // Iterate over the friends and add each one to the appropriate Vec in the
        // friends_by_first_letter HashMap
        for (_, friend) in friends {
            let first_letter = friend
                .username()
                .chars()
                .next()
                .unwrap()
                .to_ascii_lowercase();

            friends_by_first_letter
                .entry(first_letter)
                .or_insert_with(Vec::new)
                .push(friend.clone());
        }

        for (_, list) in friends_by_first_letter.iter_mut() {
            list.sort_by_key(|a| a.username())
        }

        friends_by_first_letter
    }

    pub fn clear(&mut self) {
        self.chats = Chats::default();
        self.friends = Friends::default();
        self.account = Account::default();
        self.settings = Settings::default();
    }

    pub fn has_toasts(&self) -> bool {
        !self.ui.toast_notifications.is_empty()
    }
    // returns true if toasts were removed
    pub fn decrement_toasts(&mut self) -> bool {
        let mut remaining: HashMap<Uuid, ToastNotification> = HashMap::new();
        for (id, toast) in self.ui.toast_notifications.iter_mut() {
            toast.decrement_time();
            if toast.remaining_time() > 0 {
                remaining.insert(*id, toast.clone());
            }
        }

        if remaining.len() != self.ui.toast_notifications.len() {
            self.ui.toast_notifications = remaining;
            true
        } else {
            false
        }
    }

    pub fn reset_toast_timer(&mut self, id: &Uuid) {
        if let Some(toast) = self.ui.toast_notifications.get_mut(id) {
            toast.reset_time();
        }
    }

    pub fn remove_toast(&mut self, id: &Uuid) {
        let _ = self.ui.toast_notifications.remove(id);
    }
}

impl State {
    pub fn mutate(&mut self, action: Action) {
        self.call_hooks(&action);

        match action {
            Action::SetOverlay(enabled) => self.toggle_overlay(enabled),
            // Action::Call(_) => todo!(),
            // Action::Hangup(_) => todo!(),
            Action::AddToastNotification(notification) => {
                self.ui
                    .toast_notifications
                    .insert(Uuid::new_v4(), notification);
            }
            // Action::RemoveToastNotification => {
            //     self.ui.toast_notifications.pop_front();
            // }
            Action::ToggleMute => self.toggle_mute(),
            Action::ToggleSilence => self.toggle_silence(),
            Action::SetId(identity) => self.set_identity(&identity),
            Action::ToggleMedia(chat) => self.toggle_media(&chat),
            Action::EndAll => self.disable_all_active_media(),
            Action::SetLanguage(language) => self.set_language(&language),
            Action::SendRequest(identity) => self.new_outgoing_request(&identity),
            Action::RequestAccepted(identity) => {
                self.complete_request(Direction::Outgoing, &identity);
            }
            Action::CancelRequest(identity) => {
                self.cancel_request(Direction::Outgoing, &identity);
            }
            Action::IncomingRequest(identity) => self.new_incoming_request(&identity),
            Action::AcceptRequest(identity) => {
                self.complete_request(Direction::Incoming, &identity);
            }
            Action::DenyRequest(identity) => {
                self.cancel_request(Direction::Incoming, &identity);
            }
            Action::RemoveFriend(friend) => self.remove_friend(&friend.did_key()),
            Action::Block(identity) => self.block(&identity),
            Action::UnBlock(identity) => self.unblock(&identity),
            Action::Favorite(chat) => self.favorite(&chat),
            Action::UnFavorite(chat) => self.unfavorite(&chat),
            Action::ChatWith(chat) => {
                // TODO: this should create a conversation in warp if one doesn't exist
                self.set_active_chat(&chat);
                self.clear_unreads(&chat);
            }
            Action::AddToSidebar(chat) => {
                self.add_chat_to_sidebar(chat);
            }
            Action::RemoveFromSidebar(chat) => {
                self.remove_sidebar_chat(&chat);
            }
            Action::NewMessage(_, _) => todo!(),
            Action::ToggleFavorite(chat) => {
                self.toggle_favorite(&chat);
            }
            Action::StartReplying(chat, message) => {
                self.start_replying(&chat, &message);
            }
            Action::CancelReply(chat) => {
                self.cancel_reply(&chat);
            }
            Action::ClearUnreads(chat) => {
                self.clear_unreads(&chat);
            }
            Action::React(_, _, _) => todo!(),
            Action::Reply(_, _) => todo!(),
            Action::Send(_, _) => todo!(),
            Action::Navigate(to) => {
                self.set_active_route(to);
            }
            // UI
            Action::TogglePopout => {
                self.toggle_popout();
            }
            Action::SetTheme(theme) => self.set_theme(Some(theme)),
            Action::ClearTheme => self.set_theme(None),
        }

        let _ = self.save();
    }

    fn call_hooks(&mut self, action: &Action) {
        for hook in self.hooks.iter() {
            match &hook.action_type {
                Either::Left(a) => {
                    if a.compare_discriminant(action) {
                        (hook.callback)(self, action);
                    }
                }
                Either::Right(actions) => {
                    for a in actions.iter() {
                        if a.compare_discriminant(action) {
                            (hook.callback)(self, action);
                        }
                    }
                }
            }
        }
    }

    // Add a hook to be called on state changes.
    pub fn add_hook(&mut self, hook: ActionHook) {
        self.hooks.push(hook);
    }

    /// Saves the current state to disk.
    fn save(&self) -> Result<(), Box<dyn std::error::Error>> {
        let serialized = serde_json::to_string(self)?;
        let cache_path = dirs::home_dir()
            .unwrap_or_default()
            .join(".uplink/state.json")
            .into_os_string()
            .into_string()
            .unwrap_or_default();

        fs::write(cache_path, serialized)?;
        Ok(())
    }

    /// Loads the state from a file on disk, if it exists.
    pub fn load() -> Result<Self, std::io::Error> {
        let cache_path = dirs::home_dir()
            .unwrap_or_default()
            .join(".uplink/state.json")
            .into_os_string()
            .into_string()
            .unwrap_or_default();
        match fs::read_to_string(cache_path) {
            Ok(contents) => {
                let state: State = serde_json::from_str(&contents)?;
                Ok(state)
            }
            Err(_) => Ok(generate_mock()),
        }
    }

    pub fn mock() -> State {
        generate_mock()
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub enum Action {
    // UI
    TogglePopout,
    EndAll,
    ToggleSilence,
    ToggleMute,
    SetOverlay(bool),
    AddToastNotification(ToastNotification),
    SetTheme(Theme),
    ClearTheme,
    // RemoveToastNotification,
    ToggleMedia(Chat),
    // Account
    /// Sets the ID for the user.
    SetId(Identity),

    // Settings
    /// Sets the selected language.
    SetLanguage(String),

    // Routes
    /// Set the active route
    Navigate(To),
    // Requests
    /// Send a new friend request
    SendRequest(Identity),
    /// To be fired when a friend request you sent is accepted
    RequestAccepted(Identity),
    /// Cancel an outgoing request
    CancelRequest(Identity),

    /// Handle a new incoming friend request
    IncomingRequest(Identity),
    /// Accept an incoming friend request
    AcceptRequest(Identity),
    /// Deny a incoming friend request
    DenyRequest(Identity),

    // Friends
    RemoveFriend(Identity),
    Block(Identity),
    UnBlock(Identity),
    /// Handles the display of "favorite" chats
    Favorite(Chat),
    UnFavorite(Chat),
    /// Sets the active chat to a given chat
    ChatWith(Chat),
    /// Adds a chat to the sidebar
    AddToSidebar(Chat),
    /// Removes a chat from the sidebar, also removes the active chat if the chat being removed matches
    RemoveFromSidebar(Chat),
    /// Adds or removes a chat from the favorites page
    ToggleFavorite(Chat),

    // Messaging
    /// Records a new message and plays associated notifications
    NewMessage(Chat, Message),
    /// React to a given message by ID
    React(Chat, Message, Reaction),
    /// Reply to a given message by ID
    Reply(Chat, Message),
    /// Prep the UI for a message reply.
    StartReplying(Chat, Message),
    /// Clears the reply for a given chat
    CancelReply(Chat),
    /// Sends a message to the given chat
    Send(Chat, Message),
    ClearUnreads(Chat),
}

impl Action {
    fn compare_discriminant(&self, other: &Action) -> bool {
        std::mem::discriminant(self) == std::mem::discriminant(other)
    }
}
