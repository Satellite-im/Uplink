pub mod account;
pub mod action;
pub mod chats;
pub mod friends;
pub mod identity;
pub mod route;
pub mod settings;
pub mod ui;

// export specific structs which the UI expects. these structs used to be in src/state.rs, before state.rs was turned into the `state` folder
pub use account::Account;
pub use action::Action;
pub use chats::{Chat, Chats};
use dioxus_desktop::tao::window::WindowId;
pub use friends::Friends;
pub use identity::Identity;
pub use route::Route;
pub use settings::Settings;
pub use ui::{Theme, ToastNotification, UI};

use crate::testing::mock::generate_mock;
use either::Either;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fmt, fs,
};
use uuid::Uuid;
use warp::{crypto::DID, raygun::Message};

use self::{action::ActionHook, chats::Direction};

// todo: putting the State struct 300 lines into the file makes it hard to find :( state.rs should be turned into its own module and split into multiple files.
#[derive(Default, Deserialize, Serialize)]
pub struct State {
    #[serde(default)]
    pub account: account::Account,
    #[serde(default)]
    pub route: route::Route,
    #[serde(default)]
    pub chats: chats::Chats,
    #[serde(default)]
    pub friends: friends::Friends,
    #[serde(default)]
    pub settings: settings::Settings,
    #[serde(default)]
    pub ui: ui::UI,
    #[serde(skip_serializing, skip_deserializing)]
    pub(crate) hooks: Vec<action::ActionHook>,
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
        todo!()
        /*if let Some(c) = self.chats.all.get_mut(&chat.id) {
            c.active_media = !c.active_media;
            // When we "close" active media, we should hide the popout player.
            if !c.active_media {
                self.ui.popout_player = false;
            }
        }*/
    }

    fn disable_all_active_media(&mut self) {
        todo!()
        /*for (_, chat) in self.chats.all.iter_mut() {
            chat.active_media = false;
        }
        self.ui.popout_player = false;*/
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
        self.ui.toggle_muted();
    }

    fn toggle_silence(&mut self) {
        self.ui.toggle_silenced();
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
        self.chats
            .active_media
            .and_then(|uuid| self.chats.all.get(&uuid))
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
        self.chats = chats::Chats::default();
        self.friends = friends::Friends::default();
        self.account = account::Account::default();
        self.settings = settings::Settings::default();
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

    pub fn remove_window(&mut self, id: WindowId) {
        self.ui.remove_window(id);
    }
}

impl State {
    pub fn mutate(&mut self, action: Action) {
        self.call_hooks(&action);

        match action {
            Action::AddWindow(window) => {
                self.ui.overlays.push(window);
            }
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
