pub mod actions {
    use warp::{
        multipass::identity::Identity,
        raygun::{Message, Reaction},
    };

    use super::state::{Chat, To};

    /// Actions can be called with data and will internally dispatch nessisary mutations and Warp methods.
    pub enum Actions {
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
        /// Sends a message to the given chat
        Send(Chat, Message),
    }
}

pub mod state {
    use uuid::Uuid;
    use warp::{constellation::item::Item, multipass::identity::Identity, raygun::Message};

    use crate::mock_state::mock_state::generate_mock;

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
    }

    #[derive(Clone, Debug, Default)]
    pub struct Chats {
        // All active chats from warp.
        pub all: Vec<Chat>,
        // Chat to display / interact with currently.
        pub active: Chat,
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
                    mutations::set_active_chat(self, chat);
                }
                Actions::AddToSidebar(chat) => {
                    mutations::add_chat_to_sidebar(self, chat);
                }
                Actions::RemoveFromSidebar(_) => todo!(),
                Actions::NewMessage(_, _) => todo!(),
                Actions::ToggleFavorite(chat) => {
                    mutations::toggle_favorite(self, &chat);
                },
                Actions::React(_, _, _) => todo!(),
                Actions::Reply(_, _) => todo!(),
                Actions::Send(_, _) => todo!(),
                Actions::Navigate(to) => {
                    mutations::set_active_route(self, to);
                }
            }

            // TODO: Serialize and save on action
        }
    }

    /// Mutations should be the only place updating the values in state.
    pub mod mutations {
        use super::{Chat, State};

        pub fn set_active_chat(state: &mut State, chat: Chat) {
            state.chats.active = chat;
        }

        pub fn add_chat_to_sidebar(state: &mut State, chat: Chat) {
            if !state.chats.in_sidebar.contains(&chat) {
                state.chats.in_sidebar.push(chat);
            }
        }

        pub fn set_active_route(state: &mut State, to: String) {
            state.route.active = to;
        }

        pub fn toggle_favorite(state: &mut State, chat: &Chat) {
            let mut faves = state.chats.favorites.clone();

            if faves.contains(chat) {
                let index = faves.iter().position(|c| c.id == chat.id).unwrap();
                faves.remove(index);
            } else {
                faves.push(chat.clone());
            }

            state.chats.favorites = faves;
        }
    }

    pub mod getters {
        use super::{Chat, State};

        pub fn is_favorite(state: &State, chat: &Chat) -> bool {
            state.chats.favorites.contains(chat)
        }
    }

    pub fn mock_state() -> State {
        generate_mock()
    }
}
