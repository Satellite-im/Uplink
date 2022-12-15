use std::{
    collections::HashMap,
    io::{BufWriter, Write},
};
use std::ops::Range;

use base64::encode;
use chrono::{DateTime, Duration, NaiveDateTime, Utc};
use image::{ImageBuffer, Rgb, RgbImage};
use lipsum::lipsum;
use names::Generator;
use rand::{seq::SliceRandom, Rng};
use titlecase::titlecase;
use uuid::Uuid;
use warp::{
    multipass::identity::{Graphics, Identity},
    raygun::{Message, Reaction},
};

use crate::state::{Account, Chat, Chats, Friends, Route, State};

const MSG_LENGTH: Range<usize> = 2..10;
const NUM_MSG: Range<usize> = 0..20;
const NUM_USERS: Range<usize> = 3..5;
const NUM_GROUP_CHATS: Range<usize> = 3..15;
const NUM_GROUP_CHAT_USERS: Range<usize> = 2..6;
const NUM_CHATS: Range<usize> = 3..15;
const NUM_FRIENDS: Range<usize> = 10..20;
const NUM_FAVORITES: Range<usize> = 3..6;
const NUM_REACTIONS: Range<usize> = 1..3;
const REPLIES_PROB: f64 = 0.25;
const REACTIONS_PROB: f64 = 0.5;

pub fn generate_mock() -> State {
    let me = fake_id();
    let users = gen_users(random_num(NUM_USERS));
    let in_req = gen_users(3);
    let out_req = gen_users(2);
    let friends = gen_users(random_num(NUM_FRIENDS));
    let blocked = pick_random(&friends, 2);

    let participants = [
        vec![me.clone()],
        users.clone(),
        friends.clone(),
        blocked.clone(),
    ].concat();

    let chats = [
        gen_chats(me.clone(), pick_random(&friends, random_num(NUM_CHATS))),
        gen_group_chats(participants.clone())
    ].concat();

    let active_chat = chats[1].clone().id;
    let favorites = pick_random(&chats, random_num(NUM_FAVORITES)).iter().map(|v| v.id).collect();
    let in_sidebar = pick_random(&chats, 5).into_iter().map(|v| v.id).collect();

    let all_chats = chats.into_iter().map(|v| (v.id, v)).collect::<HashMap<_, _>>();
    let all_friends = friends.into_iter().map(|v| (v.did_key(), v)).collect::<HashMap<_, _>>();

    State {
        account: Account {
            identity: me,
        },
        route: Route {
            active: "/chat".into(),
        },
        chats: Chats {
            all: all_chats.clone(),
            active: Some(active_chat),
            in_sidebar,
            favorites,
        },
        friends: Friends {
            all: all_friends.clone(),
            blocked: blocked.clone(),
            incoming_requests: in_req.clone(),
            outgoing_requests: out_req.clone(),
        },
        hooks: vec![],
    }
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
    id.set_graphics(gen_graphics());
    id
}

fn gen_graphics() -> Graphics {
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

    graphics
}

fn gen_reaction(users: Vec<Identity>) -> Reaction {
    let emojis = ["❤️", "😂", "😍", "💯", "👍", "😮", "😢", "😡", "🤔", "😎"];
    let emoji = emojis.choose(&mut rand::thread_rng()).clone().unwrap();
    let dids = users.into_iter().map(|v| v.did_key()).collect::<Vec<_>>();
    let mut reaction = Reaction::default();
    reaction.set_emoji(emoji);
    reaction.set_users(dids);
    reaction
}

fn gen_reactions(users: &Vec<Identity>) -> Vec<Reaction> {
    let mut reactions = vec![];

    for _ in 0..random_num(NUM_REACTIONS) {
        let num_users = users.len();
        let reaction = gen_reaction(pick_random(users, random_num(1..num_users)));
        reactions.push(reaction);
    }

    reactions
}

fn gen_chat_message(chat: &Chat) -> Option<Message> {
    let sender = chat.participants.choose(&mut rand::thread_rng())?;
    let word_count = random_num(MSG_LENGTH);
    let mut message = Message::default();
    let mut rng = rand::thread_rng();

    let date = Utc::now() - Duration::days(rng.gen_range(0..60));

    message.set_conversation_id(chat.id);
    message.set_sender(sender.did_key());
    message.set_value(vec![lipsum(word_count).into()]);
    message.set_date(date);

    if rng.gen_bool(REACTIONS_PROB) {
        message.set_reactions(gen_reactions(&chat.participants));
    }

    Some(message)
}

fn gen_chat_reply(chat: &Chat) -> Option<Message> {
    let mut rng = rand::thread_rng();
    let sender = chat.participants.choose(&mut rng)?.did_key();
    let messages: Vec<Message> = chat.messages.iter()
        .filter(|v| v.sender() != sender)
        .map(|v| v.clone())
        .collect();

    if let Some(message) = messages.choose(&mut rng) {
        let mut reply = gen_chat_message(chat)?;
        let timestamp = rng.gen_range(
            message.date().timestamp_millis()..Utc::now().timestamp_millis() + 1
        );

        let naive = NaiveDateTime::from_timestamp_millis(timestamp).unwrap_or_default();
        let date: DateTime<Utc> = DateTime::from_utc(naive, Utc);
        reply.set_sender(sender);
        reply.set_replied(Some(message.id()));
        reply.set_date(date);
        Some(reply)
    } else {
        None
    }
}

fn gen_chat(participants: Vec<Identity>, conversation: Uuid) -> Chat {
    let mut rng = rand::thread_rng();

    let mut chat = Chat {
        id: conversation,
        participants,
        messages: vec![],
        unreads: rng.gen_range(0..2),
        replying_to: None,
    };

    for _ in 0..random_num(NUM_MSG) {
        if let Some(message) = gen_chat_message(&chat) {
            chat.messages.push(message);
        }
        if rng.gen_bool(REPLIES_PROB) {
            if let Some(message) = gen_chat_reply(&chat) {
                chat.messages.push(message);
            }
        }
    }

    chat
}

pub fn gen_users(count: usize) -> Vec<Identity> {
    let mut users = vec![];
    for _ in 0..count {
        users.push(fake_id());
    }
    users
}

pub fn gen_chats(me: Identity, users: Vec<Identity>) -> Vec<Chat> {
    users.into_iter()
        .map(|user| gen_chat(vec![me.clone(), user], Uuid::new_v4()))
        .collect()
}

pub fn gen_group_chats(users: Vec<Identity>) -> Vec<Chat> {
    let mut chats = vec![];
    let mut rng = rand::thread_rng();

    for _ in 0..random_num(NUM_GROUP_CHATS) {
        let users_count = random_num(NUM_GROUP_CHAT_USERS);
        let participants = users.choose_multiple(&mut rng, users_count).cloned().collect();
        let chat = gen_chat(participants, Uuid::new_v4());
        chats.push(chat);
    }
    chats
}

pub fn random_num(r: Range<usize>) -> usize {
    rand::thread_rng().gen_range(r)
}

pub fn pick_random<T: PartialEq + Clone>(items: &Vec<T>, count: usize) -> Vec<T> {
    let mut rng = rand::thread_rng();
    let source = items
        .into_iter()
        .map(|v| v.clone())
        .collect::<Vec<T>>();

    source.choose_multiple(&mut rng, count).cloned().collect()
}
