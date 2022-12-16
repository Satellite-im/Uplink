use chrono::{DateTime, Utc};
use either::Either;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use uuid::Uuid;

use warp::{
    constellation::item::Item,
    crypto::DID,
    multipass::identity::Identity,
    raygun::{Message, Reaction},
};

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

// Define a new struct to represent a hook that listens for a specific action type.
pub struct ActionHook {
    action_type: Either<Action, Vec<Action>>,
    callback: Box<dyn Fn(&State, &Action)>,
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

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Route {
    // String representation of the current active route.
    #[serde(default)]
    pub active: To,
}

#[derive(Clone, Debug, PartialEq, Eq, Default, Deserialize, Serialize)]
pub struct Chat {
    // Warp generated UUID of the chat
    #[serde(default)]
    pub id: Uuid,
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
        let mut cloned = State::default();

        // Copy over the relevant fields from the original State struct.
        cloned.account = self.account.clone();
        cloned.route = self.route.clone();
        cloned.chats = self.chats.clone();
        cloned.friends = self.friends.clone();

        // The hooks field should not be cloned, so we clear it.
        cloned.hooks.clear();

        cloned
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

    /// Sets the active chat in the `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to set as the active chat.
    fn set_active_chat(&mut self, chat: &Chat) {
        self.chats.active = Some(chat.id);
        if !self.chats.in_sidebar.contains(&chat.id) {
            self.chats.in_sidebar.push(chat.id.clone());
        }
    }

    /// Clears the active chat in the `State` struct.
    fn clear_active_chat(&mut self) {
        self.chats.active = None;
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
    pub fn favorite(&mut self, chat: &Chat) {
        if !self.chats.favorites.contains(&chat.id) {
            self.chats.favorites.push(chat.id.clone());
        }
    }

    /// Removes the given chat from the user's favorites.
    pub fn unfavorite(&mut self, chat: &Chat) {
        if let Some(index) = self
            .chats
            .favorites
            .iter()
            .position(|uid| uid.to_owned() == chat.id)
        {
            self.chats.favorites.remove(index);
        }
    }

    /// Toggles the specified chat as a favorite in the `State` struct. If the chat
    /// is already a favorite, it is removed from the favorites list. Otherwise, it
    /// is added to the list.
    fn toggle_favorite(&mut self, chat: &Chat) {
        let faves = &mut self.chats.favorites;

        if faves.contains(&chat.id) {
            if let Some(index) = faves.iter().position(|uid| uid.to_owned() == chat.id) {
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

        *self.chats.all.get_mut(&chat.id).unwrap() = c.clone();
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

        *self.chats.all.get_mut(&chat.id).unwrap() = c.clone();
    }

    /// Clear unreads  within a given chat on `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to clear unreads on.
    ///
    fn clear_unreads(&mut self, chat: &Chat) {
        match self.chats.all.get_mut(&chat.id) {
            Some(chat) => chat.unreads = 0,
            None => return,
        };
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
                .position(|x| x.to_owned() == chat.id)
                .unwrap();
            self.chats.in_sidebar.remove(index);
        }

        if self.chats.active.is_some() {
            if self.get_active_chat().unwrap_or_default().id == chat.id {
                self.clear_active_chat();
            }
        }
    }

    /// Sets the user's identity.
    pub fn set_identity(&mut self, identity: &Identity) {
        self.account.identity = identity.clone();
    }

    pub fn is_me(&self, identity: &Identity) -> bool {
        identity.did_key().to_string() == self.account.identity.did_key().to_string()
    }

    /// Getters
    /// Getters are the only public facing methods besides dispatch.
    /// Getters help retrieve data from state in common ways preventing reused code.

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

    pub fn get_friends_by_first_letter(&self) -> HashMap<char, Vec<Identity>> {
        let friends = self.friends.all.clone();
        let mut friends_by_first_letter: HashMap<char, Vec<Identity>> = HashMap::new();

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

        // Sort the keys of the HashMap alphabetically
        let mut sorted_keys: Vec<char> = friends_by_first_letter.keys().cloned().collect();
        sorted_keys.sort_unstable();

        // Create a new HashMap with the same values as friends_by_first_letter, but with
        // the keys in alphabetical order
        let mut sorted_friends_by_first_letter: HashMap<char, Vec<Identity>> = HashMap::new();
        for key in sorted_keys {
            sorted_friends_by_first_letter
                .insert(key, friends_by_first_letter.get(&key).unwrap().clone());
        }

        sorted_friends_by_first_letter
    }
}

impl State {
    pub fn mutate(&mut self, action: Action) {
        self.call_hooks(&action);

        match action {
            Action::SetId(identity) => self.set_identity(&identity),
            Action::SendRequest(_) => todo!(),
            Action::RequestAccepted(_) => todo!(),
            Action::CancelRequest(_) => todo!(),
            Action::IncomingRequest(_) => todo!(),
            Action::AcceptRequest(_) => todo!(),
            Action::DenyRequest(_) => todo!(),
            Action::Block(_) => todo!(),
            Action::UnBlock(_) => todo!(),
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
        }

        let _ = self.save();
    }

    fn call_hooks(&mut self, action: &Action) {
        for hook in self.hooks.iter() {
            match &hook.action_type {
                Either::Left(a) => {
                    if a.compare_discriminant(action) {
                        (hook.callback)(&self, &action);
                    }
                }
                Either::Right(actions) => {
                    for a in actions.iter() {
                        if a.compare_discriminant(action) {
                            (hook.callback)(&self, &action);
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
        fs::write("state.json", serialized)?;
        Ok(())
    }

    /// Loads the state from a file on disk, if it exists.
    pub fn load() -> Result<Self, std::io::Error> {
        match fs::read_to_string("state.json") {
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

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub enum Action {
    // Account
    /// Sets the ID for the user.
    SetId(Identity),

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
