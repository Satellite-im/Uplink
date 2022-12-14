use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use uuid::Uuid;
use warp::{
    constellation::item::Item,
    multipass::identity::Identity,
    raygun::{Message, Reaction},
};

use std::fs;

/// Alias for the type representing a route.
pub type To = String;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Account {
    pub identity: Identity,
    // pub settings: Option<CustomSettings>,
    // pub profile: Option<Profile>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Route {
    // String representation of the current active route.
    pub active: To,
}

#[derive(Clone, Debug, PartialEq, Eq, Default, Deserialize, Serialize)]
pub struct Chat {
    // Warp generated UUID of the chat
    pub id: Uuid,
    // Includes the list of participants within a given chat.
    pub participants: Vec<Identity>,
    // Messages should only contain messages we want to render. Do not include the entire message history.
    pub messages: Vec<Message>,
    // Unread count for this chat, should be cleared when we view the chat.
    pub unreads: u32,
    // If a value exists, we will render the message we're replying to above the chatbar
    pub replying_to: Option<Message>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Chats {
    // All active chats from warp.
    pub all: Vec<Chat>,
    // Chat to display / interact with currently.
    pub active: Option<Chat>,
    // Chats to show in the sidebar
    pub in_sidebar: Vec<Chat>,
    // Favorite Chats
    pub favorites: Vec<Chat>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Friends {
    // All active friends.
    pub all: Vec<Identity>,
    // List of friends the user has blocked
    pub blocked: Vec<Identity>,
    // Friend requests, incoming and outgoing.
    pub incoming_requests: Vec<Identity>,
    pub outgoing_requests: Vec<Identity>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Files {
    // All files
    pub all: Vec<Item>,
    // Optional, active folder.
    pub active_folder: Option<Item>,
}

use std::fmt;

#[derive(Default, Deserialize, Serialize)]
struct State {
    account: Account,
    route: Route,
    chats: Chats,
    friends: Friends,
    #[serde(skip_serializing, skip_deserializing)]
    hooks: Vec<Box<dyn Fn(&State)>>,
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
        let mut cloned = self.clone();
        cloned.hooks.clear();
        cloned
    }
}

// This code defines a number of methods for the State struct, which are used to mutate the state in a controlled manner.
// For example, the set_active_chat method sets the active chat in the State struct, and the toggle_favorite method adds or removes a chat from the user's favorites.
//  These methods are used to update the relevant fields within the State struct in response to user actions or other events within the application.
impl State {
    /// Constructs a new `State` instance with default values.
    fn new() -> Self {
        State::default()
    }

    /// Sets the active chat in the `State` struct.
    ///
    /// # Arguments
    ///
    /// * `chat` - The chat to set as the active chat.
    fn set_active_chat(&mut self, chat: &Chat) {
        self.chats.active = Some(chat.clone());
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
        if !self.chats.in_sidebar.contains(&chat) {
            self.chats.in_sidebar.push(chat);
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

    /// Toggles the specified chat as a favorite in the `State` struct. If the chat
    /// is already a favorite, it is removed from the favorites list. Otherwise, it
    /// is added to the list.
    fn toggle_favorite(&mut self, chat: &Chat) {
        let faves = &mut self.chats.favorites;

        if faves.contains(chat) {
            if let Some(index) = faves.iter().position(|c| c.id == chat.id) {
                faves.remove(index);
            }
        } else {
            faves.push(chat.clone());
        }
    }

    /// Begins replying to a message in the specified chat in the `State` struct.
    fn start_replying(&mut self, chat: &Chat, message: &Message) {
        let chat_index = self.chats.all.iter().position(|c| c.id == chat.id).unwrap();
        self.chats.all[chat_index].replying_to = Some(message.to_owned());

        // Update the active state if it matches the one we're modifying
        if self.chats.active.is_some() {
            let mut active_chat = self.get_active_chat();
            if active_chat.id == chat.id {
                active_chat.replying_to = Some(message.to_owned());
                self.chats.active = Some(active_chat);
            }
        }
    }

    fn cancel_reply(&mut self, chat: &Chat) {
        let chat_index = self.chats.all.iter().position(|c| c.id == chat.id).unwrap();
        self.chats.all[chat_index].replying_to = None;

        // Update the active state if it matches the one we're modifying
        if self.chats.active.is_some() {
            let mut active_chat = self.get_active_chat();
            if active_chat.id == chat.id {
                active_chat.replying_to = None;
                self.chats.active = Some(active_chat);
            }
        }
    }

    fn clear_unreads(&mut self, chat: &Chat) {
        let chat_index = self.chats.all.iter().position(|c| c.id == chat.id).unwrap();
        self.chats.all[chat_index].unreads = 0;

        // Update the active state if it matches the one we're modifying
        if self.chats.active.is_some() {
            let mut active_chat = self.get_active_chat();
            if active_chat.id == chat.id {
                active_chat.unreads = 0;
                self.chats.active = Some(active_chat);
            }
        }

        // Update the sidebar chats if it matches the one we're modifying
        if self.chats.in_sidebar.contains(chat) {
            for c in self.chats.in_sidebar.iter_mut() {
                if c.id == chat.id {
                    c.unreads = 0;
                }
            }
        }
    }

    fn remove_sidebar_chat(&mut self, chat: &Chat) {
        if self.chats.in_sidebar.contains(chat) {
            let index = self
                .chats
                .in_sidebar
                .iter()
                .position(|x| x.id == chat.id)
                .unwrap();
            self.chats.in_sidebar.remove(index);
        }

        if self.chats.active.is_some() {
            if self.get_active_chat().id == chat.id {
                self.clear_active_chat();
            }
        }
    }

    /// Getters
    /// Getters are the only public facing methods besides dispatch.
    /// Getters help retrieve data from state in common ways preventing reused code.

    pub fn is_favorite(&self, chat: &Chat) -> bool {
        self.chats.favorites.contains(chat)
    }

    pub fn get_active_chat(&self) -> Chat {
        let chat = self.chats.active.clone();
        chat.unwrap_or_default()
    }

    // Internal

    fn mutate(&mut self, action: Action) {
        match action {
            Action::SetId(_) => todo!(),
            Action::SendRequest(_) => todo!(),
            Action::RequestAccepted(_) => todo!(),
            Action::CancelRequest(_) => todo!(),
            Action::IncomingRequest(_) => todo!(),
            Action::AcceptRequest(_) => todo!(),
            Action::DenyRequest(_) => todo!(),
            Action::Block(_) => todo!(),
            Action::UnBlock(_) => todo!(),
            Action::Favorite(_) => todo!(),
            Action::UnFavorite(_) => todo!(),
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

        // Call the hooks
        for hook in &self.hooks {
            hook(&self);
        }

        self.save();
    }

    fn add_hook<F>(&mut self, hook: F)
    where
        F: Fn(&State) + 'static,
    {
        self.hooks.push(Box::new(hook));
    }
}

impl State {
    /// Saves the current state to disk.
    fn save(&self) -> Result<(), Box<dyn std::error::Error>> {
        let serialized = serde_json::to_string(self)?;
        fs::write("state.json", serialized)?;
        Ok(())
    }

    /// Loads the state from a file on disk, if it exists.
    fn load() -> Result<Self, std::io::Error> {
        if let Ok(contents) = fs::read_to_string("state.json") {
            let state: State = serde_json::from_str(&contents)?;
            Ok(state)
        } else {
            Ok(State::default())
        }
    }
}

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

fn main() {
    let state = Arc::new(Mutex::new(State::new()));

    // Add a hook to the state
    {
        let state = state.clone();
        let mut state = state.lock().unwrap();
        state.add_hook(move |s| {
            println!("State updated: {:?}", s);
        });
    }

    // Mutate the state
    {
        let state = state.clone();
        let mut state = state.lock().unwrap();
        state.mutate(Action::Navigate(String::from("/")));
    }
}
