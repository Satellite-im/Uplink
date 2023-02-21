pub mod account;
pub mod action;
pub mod chats;
pub mod configuration;
pub mod friends;
pub mod identity;
pub mod notifications;
pub mod route;
pub mod settings;
pub mod storage;
pub mod ui;

// export specific structs which the UI expects. these structs used to be in src/state.rs, before state.rs was turned into the `state` folder
use crate::language::get_local_text;
pub use account::Account;
pub use action::Action;
pub use chats::{Chat, Chats};
use dioxus_desktop::tao::window::WindowId;
pub use friends::Friends;
pub use identity::Identity;
pub use route::Route;
pub use settings::Settings;
use std::path::{Path, PathBuf};
pub use ui::{Theme, ToastNotification, UI};

use crate::STATIC_ARGS;

use crate::{
    testing::mock::generate_mock,
    warp_runner::{
        ui_adapter::{MessageEvent, MultiPassEvent, RayGunEvent},
        WarpEvent,
    },
};
use either::Either;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    fmt, fs,
    time::{Duration, Instant},
};
use uuid::Uuid;
use warp::{
    crypto::DID,
    logging::tracing::log,
    multipass::identity::IdentityStatus,
    raygun::{self, Message, Reaction},
};

use self::{action::ActionHook, chats::Direction, configuration::Configuration, ui::Call};

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
    #[serde(skip)]
    pub storage: storage::Storage,
    #[serde(default)]
    pub settings: settings::Settings,
    #[serde(default)]
    pub ui: ui::UI,
    #[serde(default)]
    pub configuration: configuration::Configuration,
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
            storage: self.storage.clone(),
            hooks: Default::default(),
            settings: Default::default(),
            ui: Default::default(),
            configuration: Configuration::new(),
        }
    }
}

// This code defines a number of methods for the State struct, which are used to mutate the state in a controlled manner.
// For example, the set_active_chat method sets the active chat in the State struct, and the toggle_favorite method adds or removes a chat from the user's favorites.
//  These methods are used to update the relevant fields within the State struct in response to user actions or other events within the application.
impl State {
    /// Constructs a new `State` instance with default values.
    /// use state::load() instead
    #[deprecated]
    pub fn new() -> Self {
        State::default()
    }

    pub fn mutate(&mut self, action: Action) {
        log::debug!("state::mutate: {}", action);
        self.call_hooks(&action);

        match action {
            Action::RegisterExtensions(extensions) => self.ui.extensions = extensions,
            // ===== Notifications =====
            Action::AddNotification(kind, count) => self.ui.notifications.increment(kind, count),
            Action::RemoveNotification(kind, count) => self.ui.notifications.decrement(kind, count),
            Action::ClearNotification(kind) => self.ui.notifications.clear_kind(kind),
            Action::ClearAllNotifications => self.ui.notifications.clear_all(),
            Action::AddToastNotification(notification) => {
                self.ui
                    .toast_notifications
                    .insert(Uuid::new_v4(), notification);
            }
            // ===== Friends =====
            Action::SendRequest(identity) => self.new_outgoing_request(&identity),
            Action::RequestAccepted(identity) => {
                self.complete_request(Direction::Outgoing, &identity)
            }
            Action::CancelRequest(identity) => self.cancel_request(Direction::Outgoing, &identity),
            Action::IncomingRequest(identity) => self.new_incoming_request(&identity),
            Action::AcceptRequest(identity) => {
                self.complete_request(Direction::Incoming, &identity)
            }
            Action::DenyRequest(identity) => self.cancel_request(Direction::Incoming, &identity),
            Action::RemoveFriend(friend) => self.remove_friend(&friend.did_key()),
            Action::Block(identity) => self.block(&identity),
            Action::Unblock(identity) => self.unblock(&identity),

            // ===== UI =====
            // Favorites
            Action::Favorite(chat) => self.favorite(&chat),
            Action::ToggleFavorite(chat) => self.toggle_favorite(&chat),
            Action::UnFavorite(chat_id) => self.unfavorite(chat_id),
            // Language
            Action::SetLanguage(language) => self.set_language(&language),
            // Overlay
            Action::AddOverlay(window) => self.ui.overlays.push(window),
            Action::SetOverlay(enabled) => self.toggle_overlay(enabled),
            // Sidebar
            Action::RemoveFromSidebar(chat_id) => self.remove_sidebar_chat(chat_id),
            Action::AddToSidebar(chat) => {
                self.add_chat_to_sidebar(chat.clone());
                self.chats.all.entry(chat.id).or_insert(chat);
            }
            Action::SidebarHidden(hidden) => self.ui.sidebar_hidden = hidden,
            // Navigation
            Action::Navigate(to) => self.set_active_route(to),
            // Generic UI
            Action::SetMeta(metadata) => self.ui.metadata = metadata,
            Action::ClearPopout(window) => self.ui.clear_popout(window),
            Action::SetPopout(webview) => self.ui.set_popout(webview),
            // Development
            Action::SetDebugLogger(webview) => self.ui.set_debug_logger(webview),
            Action::ClearDebugLogger(window) => self.ui.clear_debug_logger(window),
            // Themes
            Action::SetTheme(theme) => self.set_theme(Some(theme)),
            Action::ClearTheme => self.set_theme(None),

            // ===== Chats =====
            Action::ChatWith(chat) => {
                // warning: ensure that warp is used to get/create the chat which is passed in here
                //todo: check if (for the side which created the conversation) a warp event comes in and consider using that instead
                self.set_active_chat(&chat);
                self.clear_unreads(&chat);
                self.chats.all.entry(chat.id).or_insert(chat);
            }
            Action::NewMessage(_, _) => todo!(),
            Action::StartReplying(chat, message) => self.start_replying(&chat, &message),
            Action::CancelReply(chat) => self.cancel_reply(&chat),
            Action::ClearUnreads(chat) => self.clear_unreads(&chat),
            Action::AddReaction(_, _, _) => todo!(),
            Action::RemoveReaction(_, _, _) => todo!(),
            Action::Reply(_, _) => todo!(),
            Action::MockSend(id, msg) => {
                let sender = self.account.identity.did_key();
                let mut m = raygun::Message::default();
                m.set_conversation_id(id);
                m.set_sender(sender);
                m.set_value(msg);
                self.add_msg_to_chat(id, m);
            }

            // ===== Media =====
            Action::ToggleMute => self.toggle_mute(),
            Action::ToggleSilence => self.toggle_silence(),
            Action::SetId(identity) => self.set_identity(&identity),
            Action::SetActiveMedia(id) => self.set_active_media(id),
            Action::DisableMedia => self.disable_media(),
        }

        let _ = self.save();
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
        if !enabled {
            self.ui.clear_overlays();
        }
    }

    /// Sets the active media to the specified conversation id
    fn set_active_media(&mut self, id: Uuid) {
        self.chats.active_media = Some(id);
        self.ui.current_call = Some(Call::new(None));
    }

    /// Analogous to Hang Up
    fn disable_media(&mut self) {
        self.chats.active_media = None;
        self.ui.popout_player = false;
        self.ui.current_call = None;
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
    fn unfavorite(&mut self, chat_id: Uuid) {
        self.chats.favorites.retain(|uid| *uid != chat_id);
    }

    /// Toggles the specified chat as a favorite in the `State` struct. If the chat
    /// is already a favorite, it is removed from the favorites list. Otherwise, it
    /// is added to the list.
    fn toggle_favorite(&mut self, chat: &Chat) {
        let faves = &mut self.chats.favorites;
        if let Some(index) = faves.iter().position(|uid| *uid == chat.id) {
            faves.remove(index);
        } else {
            faves.push(chat.id);
        }
    }

    /// Begins replying to a message in the specified chat in the `State` struct.
    fn start_replying(&mut self, chat: &Chat, message: &Message) {
        if let Some(mut c) = self.chats.all.get_mut(&chat.id) {
            c.replying_to = Some(message.to_owned());
        }
    }

    /// Cancels a reply within a given chat on `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to stop replying to.
    fn cancel_reply(&mut self, chat: &Chat) {
        if let Some(mut c) = self.chats.all.get_mut(&chat.id) {
            c.replying_to = None;
        }
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
    fn remove_sidebar_chat(&mut self, chat_id: Uuid) {
        self.chats.in_sidebar.retain(|id| *id != chat_id);

        if let Some(id) = self.chats.active {
            if id == chat_id {
                self.clear_active_chat();
            }
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
                self.friends.outgoing_requests.remove(identity);
            }
            Direction::Incoming => {
                self.friends.incoming_requests.remove(identity);
            }
        }
    }

    fn complete_request(&mut self, direction: Direction, identity: &Identity) {
        match direction {
            Direction::Outgoing => {
                self.friends.outgoing_requests.remove(identity);
                self.friends
                    .all
                    .insert(identity.did_key(), identity.clone());
            }
            Direction::Incoming => {
                self.friends.incoming_requests.remove(identity);
                self.friends
                    .all
                    .insert(identity.did_key(), identity.clone());
            }
        }
    }

    fn new_incoming_request(&mut self, identity: &Identity) {
        self.friends.incoming_requests.insert(identity.clone());
    }

    fn new_outgoing_request(&mut self, identity: &Identity) {
        self.friends.outgoing_requests.insert(identity.clone());
    }

    fn block(&mut self, identity: &Identity) {
        // If the identity is not already blocked, add it to the blocked list
        self.friends.blocked.insert(identity.clone());

        // Remove the identity from the outgoing requests list if they are present
        self.friends.outgoing_requests.remove(identity);

        self.friends.incoming_requests.remove(identity);

        // Remove the identity from the friends list if they are present
        self.remove_friend(&identity.did_key());
    }

    fn unblock(&mut self, identity: &Identity) {
        self.friends.blocked.remove(identity);
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

        // if no direct chat was found then return
        let direct_chat = match direct_chat {
            Some(c) => c,
            None => return,
        };

        self.remove_sidebar_chat(direct_chat.id);

        // If the friend's direct chat is currently the active chat, clear the active chat
        if let Some(id) = self.chats.active {
            if id == direct_chat.id {
                self.clear_active_chat();
            }
        }

        // Remove chat from favorites if it exists
        self.unfavorite(direct_chat.id);
    }

    fn toggle_mute(&mut self) {
        self.ui.toggle_muted();
    }

    fn toggle_silence(&mut self) {
        self.ui.toggle_silenced();
    }

    fn add_msg_to_chat(&mut self, conversation_id: Uuid, message: raygun::Message) {
        if let Some(chat) = self.chats.all.get_mut(&conversation_id) {
            chat.typing_indicator.remove(&message.sender());
            chat.messages.push_back(message);
        }
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
        self.chats
            .active
            .and_then(|uuid| self.chats.all.get(&uuid).cloned())
    }

    pub fn get_active_media_chat(&self) -> Option<&Chat> {
        self.chats
            .active_media
            .and_then(|uuid| self.chats.all.get(&uuid))
    }

    pub fn get_chat_with_friend(&self, friend: &Identity) -> Option<Chat> {
        self.chats
            .all
            .values()
            .find(|chat| chat.participants.len() == 2 && chat.participants.contains(friend))
            .cloned()
    }

    pub fn get_without_me(&self, identities: &[Identity]) -> Vec<Identity> {
        identities
            .iter()
            .filter(|identity| identity.did_key() != self.account.identity.did_key())
            .cloned()
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
        if chat.messages.is_empty() {
            return vec![];
        }
        let mut message_groups = Vec::new();
        let current_sender = chat.messages[0].sender();
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
                .expect("all friends should have a username")
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
        self.ui.remove_overlay(id);
    }

    pub fn clear_typing_indicator(&mut self, instant: Instant) -> bool {
        let mut needs_update = false;
        for conv_id in self.chats.in_sidebar.iter() {
            let chat = match self.chats.all.get_mut(conv_id) {
                Some(c) => c,
                None => {
                    log::warn!("conv {} found in sidebar but not in HashMap", conv_id);
                    continue;
                }
            };
            let old_len = chat.typing_indicator.len();
            chat.typing_indicator
                .retain(|_id, time| instant - *time < Duration::from_secs(5));
            let new_len = chat.typing_indicator.len();

            if old_len != new_len {
                needs_update = true;
            }
        }

        needs_update
    }

    pub fn add_message_reaction(&mut self, chat_id: Uuid, message_id: Uuid, emoji: String) {
        let user = self.account.identity.did_key();
        let conv = match self.chats.all.get_mut(&chat_id) {
            Some(c) => c,
            None => {
                log::warn!("attempted to add reaction to nonexistent conversation");
                return;
            }
        };

        for msg in &mut conv.messages {
            if msg.id() != message_id {
                continue;
            }

            let mut has_emoji = false;
            for reaction in msg.reactions_mut() {
                if !reaction.emoji().eq(&emoji) {
                    continue;
                }
                if !reaction.users().contains(&user) {
                    reaction.users_mut().push(user.clone());
                    has_emoji = true;
                }
            }

            if !has_emoji {
                let mut r = Reaction::default();
                r.set_emoji(&emoji);
                r.set_users(vec![user.clone()]);
                msg.reactions_mut().push(r);
            }
        }
    }

    pub fn remove_message_reaction(&mut self, chat_id: Uuid, message_id: Uuid, emoji: String) {
        let user = self.account.identity.did_key();
        let conv = match self.chats.all.get_mut(&chat_id) {
            Some(c) => c,
            None => {
                log::warn!("attempted to remove reaction to nonexistent conversation");
                return;
            }
        };

        for msg in &mut conv.messages {
            if msg.id() != message_id {
                continue;
            }

            for reaction in msg.reactions_mut() {
                if !reaction.emoji().eq(&emoji) {
                    continue;
                }
                let mut users = reaction.users();
                users.retain(|id| id != &user);
                reaction.set_users(users);
            }
            msg.reactions_mut().retain(|r| !r.users().is_empty());
        }
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
        let serialized = serde_json::to_string_pretty(self)?;
        let path = if STATIC_ARGS.use_mock {
            &STATIC_ARGS.mock_cache_path
        } else {
            &STATIC_ARGS.cache_path
        };
        fs::write(path, serialized)?;
        Ok(())
    }

    /// Loads the state from a file on disk, if it exists.
    pub fn load() -> Self {
        if STATIC_ARGS.use_mock {
            return State::load_mock();
        };

        let contents = match fs::read_to_string(&STATIC_ARGS.cache_path) {
            Ok(r) => r,
            Err(_) => {
                return State::default();
            }
        };
        serde_json::from_str(&contents).unwrap_or_default()
    }

    fn load_mock() -> Self {
        let contents = match fs::read_to_string(&STATIC_ARGS.mock_cache_path) {
            Ok(r) => r,
            Err(_) => {
                return generate_mock();
            }
        };
        serde_json::from_str(&contents).unwrap_or_else(|_| generate_mock())
    }

    pub fn process_warp_event(&mut self, event: WarpEvent) {
        // handle any number of events and then save
        match event {
            WarpEvent::MultiPass(evt) => self.process_multipass_event(evt),
            WarpEvent::RayGun(evt) => self.process_raygun_event(evt),
            WarpEvent::Message(evt) => self.process_message_event(evt),
        };

        let _ = self.save();
    }

    fn process_multipass_event(&mut self, event: MultiPassEvent) {
        match event {
            MultiPassEvent::None => {}
            MultiPassEvent::FriendRequestReceived(identity) => {
                self.friends.incoming_requests.insert(identity.clone());

                self.mutate(Action::AddNotification(
                    notifications::NotificationKind::FriendRequest,
                    1,
                ));

                // TODO: Get state available in this scope.
                // Dispatch notifications only when we're not already focused on the application.
                let notifications_enabled = self
                    .configuration
                    .config
                    .notifications
                    .friends_notifications;

                if !self.ui.metadata.focused && notifications_enabled {
                    crate::utils::notifications::push_notification(
                        get_local_text("friends.new-request"),
                        format!("{} sent a request.", identity.username()),
                        Some(crate::utils::sounds::Sounds::Notification),
                        notify_rust::Timeout::Milliseconds(4),
                    );
                }
            }
            MultiPassEvent::FriendRequestSent(identity) => {
                self.friends.outgoing_requests.insert(identity);
            }
            MultiPassEvent::FriendAdded(identity) => {
                self.friends.incoming_requests.remove(&identity);
                self.friends.outgoing_requests.remove(&identity);
                self.friends.all.insert(identity.did_key(), identity);
            }
            MultiPassEvent::FriendRemoved(identity) => {
                self.friends.all.remove(&identity.did_key());
            }
            MultiPassEvent::FriendRequestCancelled(identity) => {
                self.friends.incoming_requests.remove(&identity);
                self.friends.outgoing_requests.remove(&identity);
            }
            MultiPassEvent::FriendOnline(identity) => {
                if let Some(ident) = self.friends.all.get_mut(&identity.did_key()) {
                    ident.set_identity_status(IdentityStatus::Online);
                }
            }
            MultiPassEvent::FriendOffline(identity) => {
                if let Some(ident) = self.friends.all.get_mut(&identity.did_key()) {
                    ident.set_identity_status(IdentityStatus::Offline);
                }
            }
            MultiPassEvent::Blocked(identity) => {
                self.block(&identity);
            }
            MultiPassEvent::Unblocked(identity) => {
                self.unblock(&identity);
            }
        }
    }

    fn process_raygun_event(&mut self, event: RayGunEvent) {
        match event {
            RayGunEvent::ConversationCreated(chat) => {
                if !self.chats.in_sidebar.contains(&chat.id) {
                    self.chats.in_sidebar.insert(0, chat.id);
                }
                self.chats.all.insert(chat.id, chat);
            }
            RayGunEvent::ConversationDeleted(id) => {
                self.chats.in_sidebar.retain(|x| *x != id);
                self.chats.all.remove(&id);
                if self.chats.active == Some(id) {
                    self.chats.active = None;
                }
            }
        }
    }

    fn process_message_event(&mut self, event: MessageEvent) {
        match event {
            MessageEvent::Received {
                conversation_id,
                message,
            } => {
                // todo: don't load all the messages by default. if the user scrolled up, for example, this incoming message may not need to be fetched yet.
                self.add_msg_to_chat(conversation_id, message);

                self.mutate(Action::AddNotification(
                    notifications::NotificationKind::Message,
                    1,
                ));

                // TODO: Get state available in this scope.
                // Dispatch notifications only when we're not already focused on the application.
                let notifications_enabled = self
                    .configuration
                    .config
                    .notifications
                    .messages_notifications;
                let should_play_sound = self.chats.active != Some(conversation_id)
                    && self.configuration.config.audiovideo.message_sounds;
                let should_dispatch_notification =
                    notifications_enabled && !self.ui.metadata.focused;

                // This should be called if we have notifications enabled for new messages
                if should_dispatch_notification {
                    let sound = if self.configuration.config.audiovideo.message_sounds {
                        Some(crate::utils::sounds::Sounds::Notification)
                    } else {
                        None
                    };
                    crate::utils::notifications::push_notification(
                        get_local_text("friends.new-request"),
                        format!("{} sent a request.", "NOT YET IMPL"),
                        sound,
                        notify_rust::Timeout::Milliseconds(4),
                    );
                // If we don't have notifications enabled, but we still have sounds enabled, we should play the sound as long as we're not already actively focused on the convo where the message came from.
                } else if should_play_sound {
                    crate::utils::sounds::Play(crate::utils::sounds::Sounds::Notification);
                }
            }
            MessageEvent::Sent {
                conversation_id,
                message,
            } => {
                // todo: don't load all the messages by default. if the user scrolled up, for example, this incoming message may not need to be fetched yet.
                if let Some(chat) = self.chats.all.get_mut(&conversation_id) {
                    chat.messages.push_back(message);
                }
            }
            MessageEvent::MessageReactionAdded {
                conversation_id,
                message_id,
                reaction,
            } => {
                self.add_message_reaction(conversation_id, message_id, reaction);
            }
            MessageEvent::MessageReactionRemoved {
                conversation_id,
                message_id,
                reaction,
            } => {
                self.remove_message_reaction(conversation_id, message_id, reaction);
            }
            MessageEvent::TypingIndicator {
                conversation_id,
                participant,
            } => {
                if !self.chats.in_sidebar.contains(&conversation_id) {
                    return;
                }
                match self.chats.all.get_mut(&conversation_id) {
                    Some(chat) => {
                        chat.typing_indicator.insert(participant, Instant::now());
                    }
                    None => {
                        log::warn!(
                            "attempted to update typing indicator for nonexistent conversation: {}",
                            conversation_id
                        );
                    }
                }
            }
        }
    }
}

// Define a struct to represent a group of messages from the same sender.
#[derive(Clone)]
pub struct MessageGroup {
    pub sender: DID,
    pub remote: bool,
    pub messages: Vec<GroupedMessage>,
}

// Define a struct to represent a message that has been placed into a group.
#[derive(Clone)]
pub struct GroupedMessage {
    pub message: Message,
    pub is_first: bool,
    pub is_last: bool,
}
