pub mod actions {
    use warp::{
        multipass::identity::Identity,
        raygun::{Message, Reaction},
    };

    use super::state::{Chat, To};

    /// Actions can be called with data and will internally dispatch nessisary mutations and Warp methods.
    pub enum Actions<'a> {
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
        Favorite(&'a Chat),
        UnFavorite(&'a Chat),
        /// Sets the active chat to a given chat
        ChatWith(&'a Chat),
        /// Adds a chat to the sidebar
        AddToSidebar(Chat),
        /// Removes a chat from the sidebar, also removes the active chat if the chat being removed matches
        RemoveFromSidebar(&'a Chat),
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
        ClearUnreads(&'a Chat),
    }
}

pub mod state {
    use uuid::Uuid;
    use warp::{constellation::item::Item, multipass::identity::Identity, raygun::Message};

    use crate::mock::mock_state::generate_mock;

    use super::actions::Actions;

    pub type To = String;

    #[derive(Clone, Debug, Default)]
    pub struct Account {
        pub identity: Identity,
        // pub settings: Option<CustomSettings>,
        // pub profile: Option<Profile>,
    }

    #[derive(Clone, Debug, Default)]
    pub struct Route {
        // String representation of the current active route.
        pub active: To,
    }

    #[derive(Clone, Debug, PartialEq, Eq, Default)]
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

    #[derive(Clone, Debug, Default)]
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

    #[derive(Clone, Debug, Default)]
    pub struct Friends {
        // All active friends.
        pub all: Vec<Identity>,
        // List of friends the user has blocked
        pub blocked: Vec<Identity>,
        // Friend requests, incoming and outgoing.
        pub incoming_requests: Vec<Identity>,
        pub outgoing_requests: Vec<Identity>,
    }

    #[derive(Clone, Debug, Default)]
    pub struct Files {
        // All files
        pub all: Vec<Item>,
        // Optional, active folder.
        pub active_folder: Option<Item>,
    }

    #[derive(Clone, Debug, Default)]
    pub struct State {
        pub account: Account,
        pub route: Route,
        pub chats: Chats,
        pub friends: Friends,
    }

    impl State {
        /// Internal Mutations
        /// mutations should be the only place updating the values in state.
        fn set_active_chat(&mut self, chat: &Chat) {
            self.chats.active = Some(chat.clone());
        }

        fn clear_active_chat(&mut self) {
            self.chats.active = None;
        }

        fn add_chat_to_sidebar(&mut self, chat: Chat) {
            if !self.chats.in_sidebar.contains(&chat) {
                self.chats.in_sidebar.push(chat);
            }
        }

        fn set_active_route(&mut self, to: String) {
            self.route.active = to;
        }

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

        /// Actions
        /// Actions are how the UI tells the state it'd like to change it.
        pub fn dispatch(&mut self, action: Actions) {
            match action {
                Actions::SetId(_) => todo!(),
                Actions::SendRequest(_) => todo!(),
                Actions::RequestAccepted(_) => todo!(),
                Actions::CancelRequest(_) => todo!(),
                Actions::IncomingRequest(_) => todo!(),
                Actions::AcceptRequest(_) => todo!(),
                Actions::DenyRequest(_) => todo!(),
                Actions::Block(_) => todo!(),
                Actions::UnBlock(_) => todo!(),
                Actions::Favorite(_) => todo!(),
                Actions::UnFavorite(_) => todo!(),
                Actions::ChatWith(chat) => {
                    // TODO: this should create a conversation in warp if one doesn't exist
                    self.set_active_chat(&chat);
                    self.clear_unreads(&chat);
                }
                Actions::AddToSidebar(chat) => {
                    self.add_chat_to_sidebar(chat);
                }
                Actions::RemoveFromSidebar(chat) => {
                    self.remove_sidebar_chat(chat);
                }
                Actions::NewMessage(_, _) => todo!(),
                Actions::ToggleFavorite(chat) => {
                    self.toggle_favorite(&chat);
                }
                Actions::StartReplying(chat, message) => {
                    self.start_replying(&chat, &message);
                }
                Actions::CancelReply(chat) => {
                    self.cancel_reply(&chat);
                }
                Actions::ClearUnreads(chat) => {
                    self.clear_unreads(&chat);
                }
                Actions::React(_, _, _) => todo!(),
                Actions::Reply(_, _) => todo!(),
                Actions::Send(_, _) => todo!(),
                Actions::Navigate(to) => {
                    self.set_active_route(to);
                }
            }

            // TODO: Serialize and save on action
        }
    }

    pub fn mock() -> State {
        generate_mock()
    }
}
