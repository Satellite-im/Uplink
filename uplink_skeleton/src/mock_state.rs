pub mod mock_state {

    use uuid::Uuid;
    use rand::Rng;
    use rand::seq::SliceRandom;
    use lipsum::lipsum;
    use warp::{multipass::identity::Identity, raygun::Message, crypto::rand};

    use crate::store::state::{State, Route, Chats, Friends, Account, Chat};


    fn fake_id(username: &'static str) -> Identity {
        let mut id = Identity::default();

        id.set_username(username);
        id.set_status_message(lipsum(6).into());
        id
    }

    fn fake_chat(participants: Vec<Identity>, conversation: Uuid) -> Chat {
        let default_id = Identity::default();
        let mut messages: Vec<Message> = vec![];

        let mut rng = rand::thread_rng();
        
        let message_count = rng.gen_range(0,20);
        for _ in 0..message_count {
            let sender = participants.choose(&mut rand::thread_rng()).unwrap_or(&default_id);
            let word_count = rng.gen_range(1, 10);
            let mut default_message = Message::default();
            default_message.set_conversation_id(conversation);
            default_message.set_sender(sender.did_key());
            default_message.set_reactions(vec![]);
            default_message.set_replied(None);
            default_message.set_value(vec![lipsum(word_count).into()]);
            messages.push(default_message);
        }

        Chat {
            id: conversation,
            participants,
            messages,
            unreads: rng.gen_range(0,2),
        }
    }

    pub fn generate_mock() -> State {
        let all_friends = vec![fake_id("Albert Ford"), fake_id("Ary Fletcher"), fake_id("Henry Otango"), fake_id("Benny Fredrick")];
        
        let default_identity = Identity::default();
        let albert_ford = all_friends.get(0).unwrap_or( &default_identity);
        let ary_fletcher = all_friends.get(1).unwrap_or( &default_identity);
        let henry_otango = all_friends.get(2).unwrap_or( &default_identity);
        let benny_fredrick = all_friends.get(3).unwrap_or( &default_identity);

        let blocked = vec![fake_id("Nefarious Hacker")];
        let nefarious_hacker = blocked.get(0).unwrap_or( &default_identity);

        let nitt_swetir = fake_id("Nitt Swetir");
        let phutur_phrehnd = fake_id("Phutur Phrehnd");

        let thisis_yeu = fake_id("Thisis Yeu");

        let ary_conversation_id = Uuid::new_v4();

        let active_chat = fake_chat( vec![thisis_yeu.clone(), ary_fletcher.clone()], ary_conversation_id);

        let albert_conversation_id = Uuid::new_v4();
        let albert_chat = fake_chat( vec![thisis_yeu.clone(), albert_ford.clone()], albert_conversation_id);

        let henry_conversation_id = Uuid::new_v4();
        let henry_chat = fake_chat( vec![thisis_yeu.clone(), henry_otango.clone()], henry_conversation_id);

        let benny_conversation_id = Uuid::new_v4();
        let benny_chat = fake_chat( vec![thisis_yeu.clone(), benny_fredrick.clone()], benny_conversation_id);

        State {
            account: Account {
                identity: thisis_yeu.clone(),
            },
            route: Route {
                active: "/chat".into(),
            },
            chats: Chats {
                all: vec![active_chat.clone(), albert_chat.clone(), benny_chat.clone(), henry_chat.clone()],
                active: active_chat.clone(),
                in_sidebar: vec![active_chat.clone(), albert_chat.clone(), benny_chat.clone()],
            },
            friends: Friends {
                all: all_friends.clone(),
                blocked: vec![nefarious_hacker.clone()],
                incoming_requests: vec![nitt_swetir],
                outgoing_requests: vec![phutur_phrehnd],
                favorites: vec![ary_fletcher.clone(), henry_otango.clone()],
            },
        }
    }
}