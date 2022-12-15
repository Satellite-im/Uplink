use std::{
    collections::HashMap,
    io::{BufWriter, Write},
};

use base64::encode;
use chrono::{Duration, Utc};
use image::{ImageBuffer, Rgb, RgbImage};
use lipsum::lipsum;
use names::Generator;
use rand::{seq::SliceRandom, Rng};
use substring::Substring;
use titlecase::titlecase;
use uuid::Uuid;
use warp::{
    multipass::identity::{Graphics, Identity},
    raygun::Message,
};

use crate::state::{Account, Chat, Chats, Friends, Route, State};

pub fn generate_mock() -> State {
    let me = &generate_random_identities(1)[0];
    let identities = generate_random_identities(10);
    let blocked_identities = generate_random_identities(3);
    let incoming_requests = generate_random_identities(2);
    let outgoing_requests = generate_random_identities(1);

    let mut all_chats: HashMap<Uuid, Chat> = HashMap::new();

    for ident in identities.iter() {
        let chat = generate_random_chat(me.clone(), &vec![ident.clone()]);
        all_chats.insert(chat.id, chat);
    }

    // let group_chat = generate_random_chat(me.clone(), &identities);
    // let group_chat_sidebar = group_chat.clone();

    // all_chats.insert(group_chat.id, group_chat);

    let in_sidebar = vec![];
    // in_sidebar.push(group_chat_sidebar.id);

    State {
        account: Account {
            identity: me.clone(),
        },
        route: Route { active: "/".into() },
        chats: Chats {
            all: all_chats.clone(),
            active: None,
            in_sidebar,
            favorites: vec![],
        },
        friends: Friends {
            all: identities
                .into_iter()
                .map(|id| (id.did_key(), id))
                .collect(),
            blocked: blocked_identities.clone(),
            incoming_requests: incoming_requests.clone(),
            outgoing_requests: outgoing_requests.clone(),
        },
        hooks: Vec::new(),
    }
}

fn generate_fake_chat(participants: Vec<Identity>, conversation: Uuid) -> Chat {
    let default_id = Identity::default();
    let mut messages: Vec<Message> = vec![];

    let mut rng = rand::thread_rng();

    let message_count = rng.gen_range(0..20);
    for _ in 0..message_count {
        let sender = participants
            .choose(&mut rand::thread_rng())
            .unwrap_or(&default_id);
        let word_count = rng.gen_range(3..20);
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
        unreads: rng.gen_range(0..2),
        replying_to: None,
    }
}

// Generate a random chat with the specified DID key as one of the participants
fn generate_random_chat(me: Identity, identities: &[Identity]) -> Chat {
    // Choose a random set of participants for the chat, including "me"
    let mut participants = identities.to_vec();
    participants.push(me);

    // Generate a random conversation UUID
    let conversation = Uuid::new_v4();

    // Generate a fake chat with the selected participants and conversation UUID
    let mut chat = generate_fake_chat(participants, conversation);

    // Generate a random number of messages between the participants
    let mut rng = rand::thread_rng();
    let num_messages = rng.gen_range(0..20);
    for _ in 0..num_messages {
        // Generate a random message and add it to the chat
        let message = generate_fake_message(chat.id, &identities);
        chat.messages.push(message);
    }

    chat
}

fn fake_id() -> Identity {
    let mut id = Identity::default();
    let mut generator = Generator::default();
    let mut username = generator.next().unwrap().replace("-", " ");
    username = titlecase(&username);

    let mut rng = rand::thread_rng();
    let status_len = rng.gen_range(4..10);
    let status_msg = lipsum(status_len).to_string();

    id.set_username(&username);
    id.set_status_message(Some(status_msg));
    id
}

fn generate_random_identities(count: usize) -> Vec<Identity> {
    let mut identities: Vec<Identity> = Vec::new();

    for _ in 0..count {
        let mut identity = fake_id();

        let mut img: RgbImage = ImageBuffer::from_raw(64, 64, vec![0; 64 * 64 * 3]).unwrap();
        for (_, _, pixel) in img.enumerate_pixels_mut() {
            // Set the pixel to a random color
            let random_color = Rgb([
                rand::thread_rng().gen_range(0..255),
                rand::thread_rng().gen_range(0..255),
                rand::thread_rng().gen_range(0..255),
            ]);
            *pixel = random_color;
        }
        let mut buffer = Vec::new();

        {
            let mut writer = BufWriter::new(&mut buffer);
            writer.write_all(&img.into_raw()).unwrap();
        }

        let base64_url = encode(&buffer);
        let image_url = format!("data:image/png;base64,{}", base64_url);

        let mut graphics = Graphics::default();
        graphics.set_profile_picture(&image_url);
        graphics.set_profile_banner(&image_url);

        identity.set_graphics(graphics);

        identities.push(identity);
    }

    identities
}

fn generate_fake_message(conversation_id: Uuid, identities: &[Identity]) -> Message {
    let lorem_ipsum = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.";
    let reactions = ["❤️", "😂", "😍", "💯", "👍", "😮", "😢", "😡", "🤔", "😎"];

    let mut rng = rand::thread_rng();

    // Pick a random start and end index for the lorem ipsum text.
    let start_index = rng.gen_range(0..lorem_ipsum.len() - 1);
    let end_index = rng.gen_range(start_index + 1..lorem_ipsum.len());

    // Use the start and end indices to extract a random substring of the lorem ipsum text.
    let binding = lorem_ipsum.to_string();
    let text = binding.substring(start_index, end_index);

    // Generate a random number of reactions with a 30% probability.
    let _num_reactions = if rng.gen_bool(0.3) {
        rng.gen_range(0..reactions.len())
    } else {
        0
    };

    // Choose a random identity as the sender.
    let sender = &identities[rng.gen_range(0..identities.len())];

    // Generate a random timestamp within the past 30 days.
    let timestamp = Utc::now() - Duration::days(rng.gen_range(0..30));

    let mut default_message = Message::default();
    default_message.set_conversation_id(conversation_id);
    default_message.set_date(timestamp);
    default_message.set_sender(sender.did_key());
    default_message.set_reactions(vec![]);
    default_message.set_replied(None);
    default_message.set_value(vec![text.into()]);

    default_message
}
