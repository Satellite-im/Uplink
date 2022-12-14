pub mod mock_state {

    use std::collections::HashMap;

    use lipsum::lipsum;
    use names::Generator;
    use rand::seq::SliceRandom;
    use rand::Rng;
    use titlecase::titlecase;
    use uuid::Uuid;
    use warp::{crypto::rand, multipass::identity::Identity, raygun::Message};

    use crate::state::{Account, Chat, Chats, Friends, Route, State};

    fn fake_id() -> Identity {
        let mut id = Identity::default();
        let mut generator = Generator::default();
        let mut username = generator.next().unwrap().replace("-", " ");
        username = titlecase(&username);

        let mut rng = rand::thread_rng();
        let status_len = rng.gen_range(4, 10);

        id.set_username(&username);
        id.set_status_message(lipsum(status_len).into());
        id
    }

    fn fake_chat(participants: Vec<Identity>, conversation: Uuid) -> Chat {
        let default_id = Identity::default();
        let mut messages: Vec<Message> = vec![];

        let mut rng = rand::thread_rng();

        let message_count = rng.gen_range(0, 20);
        for _ in 0..message_count {
            let sender = participants
                .choose(&mut rand::thread_rng())
                .unwrap_or(&default_id);
            let word_count = rng.gen_range(3, 20);
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
            unreads: rng.gen_range(0, 2),
            replying_to: None,
        }
    }

    pub fn generate_mock() -> State {
        let mut all_friends = HashMap::new();

        let (a, b, c, d, e) = (fake_id(), fake_id(), fake_id(), fake_id(), fake_id());
        all_friends.insert(a.did_key(), a.clone());
        all_friends.insert(b.did_key(), b.clone());
        all_friends.insert(c.did_key(), c.clone());
        all_friends.insert(d.did_key(), d.clone());
        all_friends.insert(e.did_key(), e.clone());

        let a_key = &a.did_key();

        let default_identity = Identity::default();
        let albert_ford = all_friends.get(&a_key).unwrap_or(&default_identity);
        let ary_fletcher = all_friends.get(&b.did_key()).unwrap_or(&default_identity);
        let henry_otango = all_friends.get(&c.did_key()).unwrap_or(&default_identity);
        let benny_fredrick = all_friends.get(&d.did_key()).unwrap_or(&default_identity);

        let blocked = vec![fake_id()];
        let nefarious_hacker = blocked.get(0).unwrap_or(&default_identity);

        let nitt_swetir = fake_id();
        let phutur_phrehnd = fake_id();

        let thisis_yeu = fake_id();

        let ary_conversation_id = Uuid::new_v4();

        let ary_chat = fake_chat(
            vec![thisis_yeu.clone(), ary_fletcher.clone()],
            ary_conversation_id,
        );

        let active_chat = ary_chat.clone();

        let albert_conversation_id = Uuid::new_v4();
        let albert_chat = fake_chat(
            vec![thisis_yeu.clone(), albert_ford.clone()],
            albert_conversation_id,
        );

        let henry_conversation_id = Uuid::new_v4();
        let henry_chat = fake_chat(
            vec![thisis_yeu.clone(), henry_otango.clone()],
            henry_conversation_id,
        );

        let benny_conversation_id = Uuid::new_v4();
        let benny_chat = fake_chat(
            vec![thisis_yeu.clone(), benny_fredrick.clone()],
            benny_conversation_id,
        );

        let group_conversation_id = Uuid::new_v4();
        let group_chat = fake_chat(
            vec![
                thisis_yeu.clone(),
                benny_fredrick.clone(),
                albert_ford.clone(),
                henry_otango.clone(),
            ],
            group_conversation_id,
        );

        let mut all_chats = HashMap::new();
        all_chats.insert(ary_chat.id, ary_chat.clone());
        all_chats.insert(albert_chat.id, albert_chat.clone());
        all_chats.insert(benny_chat.id, benny_chat.clone());
        all_chats.insert(henry_chat.id, henry_chat.clone());
        all_chats.insert(group_chat.id, group_chat.clone());

        State {
            account: Account {
                identity: thisis_yeu.clone(),
            },
            route: Route {
                active: "/chat".into(),
            },
            chats: Chats {
                all: all_chats.clone(),
                active: Some(active_chat),
                in_sidebar: vec![
                    ary_chat.clone(),
                    albert_chat.clone(),
                    benny_chat.clone(),
                    group_chat.clone(),
                ],
                favorites: vec![albert_chat.clone(), ary_chat.clone()],
            },
            friends: Friends {
                all: all_friends.clone(),
                blocked: vec![nefarious_hacker.clone()],
                incoming_requests: vec![nitt_swetir],
                outgoing_requests: vec![phutur_phrehnd],
            },
            hooks: vec![],
        }
    }
}
