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
use crate::{language::get_local_text, warp_runner::ui_adapter};
pub use action::Action;
pub use chats::{Chat, Chats};
use dioxus_desktop::tao::window::WindowId;
pub use friends::Friends;
pub use identity::Identity;
pub use route::Route;
pub use settings::Settings;
pub use ui::{Theme, ToastNotification, UI};
use warp::multipass::identity::Platform;

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
use std::collections::HashSet;
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

use self::storage::Storage;
use self::{action::ActionHook, configuration::Configuration, ui::Call};

// todo: create an Identity cache and only store UUID in state.friends and state.chats
// store the following information in the cache: key: DID, value: { Identity, HashSet<UUID of conversations this identity is participating in> }
// the HashSet would be used to determine when to evict an identity. (they are not participating in any conversations and are not a friend)
#[derive(Default, Deserialize, Serialize)]
pub struct State {
    #[serde(skip)]
    id: DID,
    #[serde(default)]
    pub route: route::Route,
    #[serde(default)]
    chats: chats::Chats,
    #[serde(default)]
    friends: friends::Friends,
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
    #[serde(skip)]
    identities: HashMap<DID, identity::Identity>,
}

impl fmt::Debug for State {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.debug_struct("State")
            .field("id", &self.did_key())
            .field("route", &self.route)
            .field("chats", &self.chats)
            .field("friends", &self.friends)
            .field("hooks count", &self.hooks.len())
            .finish()
    }
}

// todo: why is there clone impl which returns a mutated value?
impl Clone for State {
    fn clone(&self) -> Self {
        State {
            id: self.did_key(),
            route: self.route.clone(),
            chats: self.chats.clone(),
            friends: self.friends.clone(),
            storage: self.storage.clone(),
            hooks: Default::default(),
            settings: Default::default(),
            ui: Default::default(),
            configuration: self.configuration.clone(),
            identities: HashMap::new(),
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
            Action::SetExtensionEnabled(extension, state) => {
                self.set_extension_enabled(extension, state)
            }
            Action::RegisterExtensions(extensions) => self.ui.extensions = extensions,
            // ===== Notifications =====
            Action::AddNotification(kind, count) => {
                self.ui
                    .notifications
                    .increment(&self.configuration, kind, count)
            }
            Action::RemoveNotification(kind, count) => {
                self.ui
                    .notifications
                    .decrement(&self.configuration, kind, count)
            }
            Action::ClearNotification(kind) => {
                self.ui.notifications.clear_kind(&self.configuration, kind)
            }
            Action::ClearAllNotifications => self.ui.notifications.clear_all(&self.configuration),
            Action::AddToastNotification(notification) => {
                self.ui
                    .toast_notifications
                    .insert(Uuid::new_v4(), notification);
            }
            // ===== Friends =====
            Action::SendRequest(identity) => self.new_outgoing_request(&identity),
            Action::RequestAccepted(identity) => self.complete_request(&identity),
            Action::CancelRequest(identity) => self.cancel_request(&identity),
            //Action::IncomingRequest(identity) => self.new_incoming_request(&identity),
            Action::AcceptRequest(identity) => self.complete_request(&identity),
            Action::DenyRequest(identity) => self.cancel_request(&identity),
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
                let chat = self.chats.all.entry(chat.id).or_insert(chat);
                chat.unreads = 0;
            }
            Action::ClearActiveChat => {
                self.clear_active_chat();
            }
            Action::NewMessage(_, _) => todo!(),
            Action::StartReplying(chat, message) => self.start_replying(&chat, &message),
            Action::CancelReply(chat_id) => self.cancel_reply(chat_id),
            Action::ClearUnreads(chat) => self.clear_unreads(chat.id),
            Action::ClearActiveUnreads => {
                if let Some(id) = self.chats.active {
                    self.clear_unreads(id);
                }
            }
            Action::AddReaction(_, _, _) => todo!(),
            Action::RemoveReaction(_, _, _) => todo!(),
            Action::Reply(_, _) => todo!(),
            Action::MockSend(id, msg) => {
                let sender = self.did_key();
                let mut m = raygun::Message::default();
                m.set_conversation_id(id);
                m.set_sender(sender);
                m.set_value(msg);
                let m = ui_adapter::Message {
                    inner: m,
                    in_reply_to: None,
                    key: Uuid::new_v4().to_string(),
                };
                self.add_msg_to_chat(id, m);
            }

            // ===== Media =====
            Action::ToggleMute => self.toggle_mute(),
            Action::ToggleSilence => self.toggle_silence(),
            Action::SetId(identity) => self.set_own_identity(identity),
            Action::SetActiveMedia(id) => self.set_active_media(id),
            Action::DisableMedia => self.disable_media(),

            // ===== Configuration =====
            Action::Config(action) => self.configuration.mutate(action),
        }

        let _ = self.save();
    }

    pub fn clear(&mut self) {
        self.chats = chats::Chats::default();
        self.friends = friends::Friends::default();
        self.settings = settings::Settings::default();
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
                self.new_incoming_request(&identity);

                self.mutate(Action::AddNotification(
                    notifications::NotificationKind::FriendRequest,
                    1,
                ));

                // TODO: Get state available in this scope.
                // Dispatch notifications only when we're not already focused on the application.
                let notifications_enabled = self.configuration.notifications.friends_notifications;

                if !self.ui.metadata.focused && notifications_enabled {
                    crate::notifications::push_notification(
                        get_local_text("friends.new-request"),
                        format!("{} sent a request.", identity.username()),
                        Some(crate::sounds::Sounds::Notification),
                        notify_rust::Timeout::Milliseconds(4),
                    );
                }
            }
            MultiPassEvent::FriendRequestSent(identity) => {
                self.new_outgoing_request(&identity);
            }
            MultiPassEvent::FriendAdded(identity) => {
                self.complete_request(&identity);
            }
            MultiPassEvent::FriendRemoved(identity) => {
                self.friends.all.remove(&identity.did_key());
            }
            MultiPassEvent::FriendRequestCancelled(identity) => {
                self.cancel_request(&identity);
            }
            MultiPassEvent::FriendOnline(identity) => {
                if let Some(ident) = self.identities.get_mut(&identity.did_key()) {
                    ident.set_identity_status(IdentityStatus::Online);
                }
            }
            MultiPassEvent::FriendOffline(identity) => {
                if let Some(ident) = self.identities.get_mut(&identity.did_key()) {
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
                if !self.chats.in_sidebar.contains(&chat.inner.id) {
                    self.chats.in_sidebar.insert(0, chat.inner.id);
                    self.identities.extend(
                        chat.identities
                            .iter()
                            .map(|ident| (ident.did_key(), ident.clone())),
                    );
                }
                self.chats.all.insert(chat.inner.id, chat.inner);
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
                self.update_identity_status_hack(&message.inner.sender());
                let id = self.identities.get(&message.inner.sender()).cloned();
                // todo: don't load all the messages by default. if the user scrolled up, for example, this incoming message may not need to be fetched yet.
                self.add_msg_to_chat(conversation_id, message);

                self.mutate(Action::AddNotification(
                    notifications::NotificationKind::Message,
                    1,
                ));

                // TODO: Get state available in this scope.
                // Dispatch notifications only when we're not already focused on the application.
                let notifications_enabled = self.configuration.notifications.messages_notifications;
                let should_play_sound = self.chats.active != Some(conversation_id)
                    && self.configuration.audiovideo.message_sounds;
                let should_dispatch_notification =
                    notifications_enabled && !self.ui.metadata.focused;

                // This should be called if we have notifications enabled for new messages
                if should_dispatch_notification {
                    let sound = if self.configuration.audiovideo.message_sounds {
                        Some(crate::sounds::Sounds::Notification)
                    } else {
                        None
                    };
                    let text = match id {
                        Some(id) => format!(
                            "{} {}",
                            id.username(),
                            get_local_text("messages.user-sent-message"),
                        ),
                        None => get_local_text("messages.unknown-sent-message"),
                    };
                    crate::notifications::push_notification(
                        get_local_text("friends.new-request"),
                        text,
                        sound,
                        notify_rust::Timeout::Milliseconds(4),
                    );
                // If we don't have notifications enabled, but we still have sounds enabled, we should play the sound as long as we're not already actively focused on the convo where the message came from.
                } else if should_play_sound {
                    crate::sounds::Play(crate::sounds::Sounds::Notification);
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
            MessageEvent::Edited {
                conversation_id,
                message,
            } => {
                self.update_identity_status_hack(&message.inner.sender());
                if let Some(chat) = self.chats.all.get_mut(&conversation_id) {
                    if let Some(msg) = chat
                        .messages
                        .iter_mut()
                        .find(|msg| msg.inner.id() == message.inner.id())
                    {
                        *msg = message;
                    }
                }
            }
            MessageEvent::Deleted {
                conversation_id,
                message_id,
            } => {
                if let Some(chat) = self.chats.all.get_mut(&conversation_id) {
                    chat.messages.retain(|msg| msg.inner.id() != message_id);
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
                self.update_identity_status_hack(&participant);
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

impl State {
    pub fn mock(
        my_id: Identity,
        mut identities: HashMap<DID, Identity>,
        chats: chats::Chats,
        friends: friends::Friends,
        storage: Storage,
    ) -> Self {
        let id = my_id.did_key();
        identities.insert(my_id.did_key(), my_id);
        Self {
            id,
            settings: Settings {
                language: "English (USA)".into(),
            },
            route: Route { active: "/".into() },
            storage,
            chats,
            friends,
            identities,
            ..Default::default()
        }
    }
    /// Saves the current state to disk.
    pub fn save(&self) -> Result<(), Box<dyn std::error::Error>> {
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
                return State {
                    configuration: Configuration::new(),
                    ..State::default()
                };
            }
        };
        let mut state: Self = serde_json::from_str(&contents).unwrap_or_default();
        // not sure how these defaulted to true, but this should serve as additional
        // protection in the future
        state.friends.initialized = false;
        state.chats.initialized = false;
        state
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
}

// for id
impl State {
    pub fn did_key(&self) -> DID {
        self.id.clone()
    }
}

// for route
impl State {
    /// Sets the active route in the `State` struct.
    ///
    /// # Arguments
    ///
    /// * `to` - The route to set as the active route.
    fn set_active_route(&mut self, to: String) {
        self.route.active = to;
    }
}

// for chats
impl State {
    pub fn chats(&self) -> &chats::Chats {
        &self.chats
    }
    pub fn chats_favorites(&self) -> Vec<Chat> {
        self.chats
            .favorites
            .iter()
            .filter_map(|did| self.chats.all.get(did))
            .cloned()
            .collect()
    }
    pub fn chats_sidebar(&self) -> Vec<Chat> {
        self.chats
            .in_sidebar
            .iter()
            .filter_map(|did| self.chats.all.get(did))
            .cloned()
            .collect()
    }
    pub fn chat_participants(&self, chat: &Chat) -> Vec<Identity> {
        chat.participants
            .iter()
            .filter_map(|did| self.identities.get(did))
            .cloned()
            .collect()
    }
    pub fn set_chats(&mut self, chats: HashMap<Uuid, Chat>, identities: HashSet<Identity>) {
        self.chats.all = chats;
        self.chats.initialized = true;
        self.identities
            .extend(identities.iter().map(|x| (x.did_key(), x.clone())));
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
    fn add_msg_to_chat(&mut self, conversation_id: Uuid, message: ui_adapter::Message) {
        if let Some(chat) = self.chats.all.get_mut(&conversation_id) {
            chat.typing_indicator.remove(&message.inner.sender());
            chat.messages.push_back(message);

            if self.ui.current_layout != ui::Layout::Compose
                || self.chats.active != Some(conversation_id)
            {
                chat.unreads += 1;
            }
        }
    }
    pub fn add_message_reaction(&mut self, chat_id: Uuid, message_id: Uuid, emoji: String) {
        let user = self.did_key();
        let conv = match self.chats.all.get_mut(&chat_id) {
            Some(c) => c,
            None => {
                log::warn!("attempted to add reaction to nonexistent conversation");
                return;
            }
        };

        for msg in &mut conv.messages {
            if msg.inner.id() != message_id {
                continue;
            }

            let mut has_emoji = false;
            for reaction in msg.inner.reactions_mut() {
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
                msg.inner.reactions_mut().push(r);
            }
        }
    }
    /// Cancels a reply within a given chat on `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to stop replying to.
    fn cancel_reply(&mut self, chat_id: Uuid) {
        if let Some(mut c) = self.chats.all.get_mut(&chat_id) {
            c.replying_to = None;
        }
    }
    /// Clears the active chat in the `State` struct.
    fn clear_active_chat(&mut self) {
        self.chats.active = None;
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
    /// Clear unreads  within a given chat on `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat_id` - The chat to clear unreads on.
    ///
    fn clear_unreads(&mut self, chat_id: Uuid) {
        if let Some(chat) = self.chats.all.get_mut(&chat_id) {
            chat.unreads = 0;
        }
    }
    /// Adds the given chat to the user's favorites.
    fn favorite(&mut self, chat: &Chat) {
        if !self.chats.favorites.contains(&chat.id) {
            self.chats.favorites.push(chat.id);
        }
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
            .find(|chat| {
                chat.participants.len() == 2 && chat.participants.contains(&friend.did_key())
            })
            .cloned()
    }
    // Define a method for sorting a vector of messages.
    pub fn get_sort_messages(&self, chat: &Chat) -> Vec<MessageGroup> {
        if chat.messages.is_empty() {
            return vec![];
        }
        let mut message_groups = Vec::new();
        let current_sender = chat.messages[0].inner.sender();
        let mut current_group = MessageGroup {
            remote: self.has_friend_with_did(&current_sender),
            sender: current_sender,
            messages: Vec::new(),
        };

        for message in chat.messages.clone() {
            if message.inner.sender() != current_group.sender {
                message_groups.push(current_group);
                current_group = MessageGroup {
                    remote: self.has_friend_with_did(&message.inner.sender()),
                    sender: message.inner.sender(),
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
    /// Check if given chat is favorite on `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to check.
    pub fn is_favorite(&self, chat: &Chat) -> bool {
        self.chats.favorites.contains(&chat.id)
    }

    pub fn remove_message_reaction(&mut self, chat_id: Uuid, message_id: Uuid, emoji: String) {
        let user = self.did_key();
        let conv = match self.chats.all.get_mut(&chat_id) {
            Some(c) => c,
            None => {
                log::warn!("attempted to remove reaction to nonexistent conversation");
                return;
            }
        };

        for msg in &mut conv.messages {
            if msg.inner.id() != message_id {
                continue;
            }

            for reaction in msg.inner.reactions_mut() {
                if !reaction.emoji().eq(&emoji) {
                    continue;
                }
                let mut users = reaction.users();
                users.retain(|id| id != &user);
                reaction.set_users(users);
            }
            msg.inner.reactions_mut().retain(|r| !r.users().is_empty());
        }
    }

    /// Remove a chat from the sidebar on `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat_id` - The chat to remove.
    fn remove_sidebar_chat(&mut self, chat_id: Uuid) {
        self.chats.in_sidebar.retain(|id| *id != chat_id);

        if let Some(id) = self.chats.active {
            if id == chat_id {
                self.clear_active_chat();
            }
        }
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
    /// Begins replying to a message in the specified chat in the `State` struct.
    fn start_replying(&mut self, chat: &Chat, message: &Message) {
        if let Some(mut c) = self.chats.all.get_mut(&chat.id) {
            c.replying_to = Some(message.to_owned());
        }
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
    /// Removes the given chat from the user's favorites.
    fn unfavorite(&mut self, chat_id: Uuid) {
        self.chats.favorites.retain(|uid| *uid != chat_id);
    }
}

// for friends
impl State {
    pub fn friends(&self) -> &friends::Friends {
        &self.friends
    }
    pub fn set_friends(&mut self, friends: friends::Friends, identities: HashSet<Identity>) {
        self.friends = friends;
        self.friends.initialized = true;
        self.identities
            .extend(identities.iter().map(|x| (x.did_key(), x.clone())));
    }

    fn block(&mut self, identity: &Identity) {
        // If the identity is not already blocked, add it to the blocked list
        self.friends.blocked.insert(identity.did_key());

        // Remove the identity from the outgoing requests list if they are present
        self.friends.outgoing_requests.remove(&identity.did_key());
        self.friends.incoming_requests.remove(&identity.did_key());

        // still want the username to appear in the blocked list
        //self.identities.remove(&identity.did_key());

        // Remove the identity from the friends list if they are present
        self.remove_friend(&identity.did_key());
    }
    fn complete_request(&mut self, identity: &Identity) {
        self.friends.outgoing_requests.remove(&identity.did_key());
        self.friends.incoming_requests.remove(&identity.did_key());
        self.friends.all.insert(identity.did_key());
        // should already be in self.identities
        self.identities.insert(identity.did_key(), identity.clone());
    }
    fn cancel_request(&mut self, identity: &Identity) {
        self.friends.outgoing_requests.remove(&identity.did_key());
        self.friends.incoming_requests.remove(&identity.did_key());
    }
    fn new_incoming_request(&mut self, identity: &Identity) {
        self.friends.incoming_requests.insert(identity.did_key());
        self.identities.insert(identity.did_key(), identity.clone());
    }

    fn new_outgoing_request(&mut self, identity: &Identity) {
        self.friends.outgoing_requests.insert(identity.did_key());
        self.identities.insert(identity.did_key(), identity.clone());
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
    pub fn has_friend_with_did(&self, did: &DID) -> bool {
        self.friends.all.contains(did)
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
                    .any(|participant| participant == did)
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
    fn unblock(&mut self, identity: &Identity) {
        self.friends.blocked.remove(&identity.did_key());
    }
}

// for storage
impl State {}

// for settings
impl State {
    /// Sets the user's language.
    fn set_language(&mut self, string: &str) {
        self.settings.language = string.to_string();
    }
}

// for ui
impl State {
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
    /// Analogous to Hang Up
    fn disable_media(&mut self) {
        self.chats.active_media = None;
        self.ui.popout_player = false;
        self.ui.current_call = None;
    }
    pub fn has_toasts(&self) -> bool {
        !self.ui.toast_notifications.is_empty()
    }
    fn toggle_mute(&mut self) {
        self.ui.toggle_muted();
    }

    fn toggle_silence(&mut self) {
        self.ui.toggle_silenced();
    }

    pub fn remove_toast(&mut self, id: &Uuid) {
        let _ = self.ui.toast_notifications.remove(id);
    }
    pub fn remove_window(&mut self, id: WindowId) {
        self.ui.remove_overlay(id);
    }
    pub fn reset_toast_timer(&mut self, id: &Uuid) {
        if let Some(toast) = self.ui.toast_notifications.get_mut(id) {
            toast.reset_time();
        }
    }
    /// Sets the active media to the specified conversation id
    fn set_active_media(&mut self, id: Uuid) {
        self.chats.active_media = Some(id);
        self.ui.current_call = Some(Call::new(None));
    }
    fn set_extension_enabled(&mut self, extension: String, state: bool) {
        let ext = self.ui.extensions.get_mut(&extension);
        match ext {
            Some(e) => e.enabled = state,
            None => {
                log::warn!(
                    "Something went wrong toggling extension '{}' to '{}'.",
                    extension,
                    state
                );
            }
        }
    }
    pub fn set_theme(&mut self, theme: Option<Theme>) {
        self.ui.theme = theme;
    }
    /// Updates the display of the overlay
    fn toggle_overlay(&mut self, enabled: bool) {
        self.ui.enable_overlay = enabled;
        if !enabled {
            self.ui.clear_overlays();
        }
    }
}

// for configuration
impl State {}

// for identities
impl State {
    pub fn blocked_fr_identities(&self) -> Vec<Identity> {
        self.friends
            .blocked
            .iter()
            .filter_map(|did| self.identities.get(did))
            .cloned()
            .collect()
    }
    pub fn friend_identities(&self) -> Vec<Identity> {
        self.friends
            .all
            .iter()
            .filter_map(|did| self.identities.get(did))
            .cloned()
            .collect()
    }
    pub fn get_identities(&self, ids: &[DID]) -> Vec<Identity> {
        ids.iter()
            .filter_map(|id| self.identities.get(id))
            .cloned()
            .collect()
    }
    pub fn get_identity(&self, did: &DID) -> Identity {
        self.identities.get(did).cloned().unwrap_or_default()
    }
    pub fn get_own_identity(&self) -> Identity {
        self.identities
            .get(&self.did_key())
            .cloned()
            .unwrap_or_default()
    }
    pub fn incoming_fr_identities(&self) -> Vec<Identity> {
        self.friends
            .incoming_requests
            .iter()
            .filter_map(|did| self.identities.get(did))
            .cloned()
            .collect()
    }
    /// Getters
    /// Getters are the only public facing methods besides dispatch.
    /// Getters help retrieve data from state in common ways preventing reused code.
    pub fn is_me(&self, identity: &Identity) -> bool {
        identity.did_key().to_string() == self.did_key().to_string()
    }
    pub fn outgoing_fr_identities(&self) -> Vec<Identity> {
        self.friends
            .outgoing_requests
            .iter()
            .filter_map(|did| self.identities.get(did))
            .cloned()
            .collect()
    }
    pub fn set_own_identity(&mut self, identity: Identity) {
        self.id = identity.did_key();
        self.identities.insert(identity.did_key(), identity);
    }
    pub fn update_identity(&mut self, id: DID, ident: identity::Identity) {
        if let Some(friend) = self.identities.get_mut(&id) {
            *friend = ident;
        } else {
            log::warn!("failed up update identity: {}", ident.username());
        }
    }
    // identities are updated once a minute for friends. but if someone sends you a message, they should be seen as online.
    // this function checks if the friend is offline and if so, sets them to online. This may be incorrect, but should
    // be corrected when the identity list is periodically updated
    pub fn update_identity_status_hack(&mut self, id: &DID) {
        if let Some(ident) = self.identities.get_mut(id) {
            if ident.identity_status() == IdentityStatus::Offline {
                ident.set_identity_status(IdentityStatus::Online);
            }
        };
    }

    pub fn graphics(&self) -> warp::multipass::identity::Graphics {
        self.identities
            .get(&self.did_key())
            .map(|x| x.graphics())
            .unwrap_or_default()
    }
    pub fn join_usernames(identities: &[Identity]) -> String {
        identities
            .iter()
            .map(|x| x.username())
            .collect::<Vec<String>>()
            .join(", ")
    }
    pub fn mock_own_platform(&mut self, platform: Platform) {
        if let Some(ident) = self.identities.get_mut(&self.did_key()) {
            ident.set_platform(platform);
        }
    }
    pub fn remove_self(&self, identities: &[Identity]) -> Vec<Identity> {
        identities
            .iter()
            .filter(|x| x.did_key() != self.did_key())
            .cloned()
            .collect()
    }
    pub fn status_message(&self) -> Option<String> {
        self.identities
            .get(&self.did_key())
            .and_then(|x| x.status_message())
    }
    pub fn username(&self) -> String {
        self.identities
            .get(&self.did_key())
            .map(|x| x.username())
            .unwrap_or_default()
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
    pub message: ui_adapter::Message,
    pub is_first: bool,
    pub is_last: bool,
}
