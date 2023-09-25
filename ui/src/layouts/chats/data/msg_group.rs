// todo: move the MessageGroup from State to this file.
// todo: consider building a VecDeque of MessageGroup inside of ChatData, as messages are added/removed.

use std::collections::VecDeque;

use common::{state::pending_message::PendingMessage, warp_runner::ui_adapter};
use warp::crypto::DID;

// Define a struct to represent a group of messages from the same sender.
#[derive(Clone)]
pub struct MessageGroup {
    pub sender: DID,
    pub remote: bool,
    pub messages: Vec<MessageGroupMsg>,
}

impl MessageGroup {
    pub fn new(sender: DID, my_did: &DID) -> Self {
        Self {
            remote: sender != *my_did,
            sender,
            messages: vec![],
        }
    }
}

// The naming is somewhat verbose and redundant but it's better than what it was before.
// Define a struct to represent a message that has been placed into a group.
#[derive(Clone)]
pub struct MessageGroupMsg {
    pub message: ui_adapter::Message,
    pub is_pending: bool,
    pub is_first: bool,
    pub is_last: bool,
}

impl MessageGroupMsg {
    pub fn clear_last(&mut self) {
        self.is_last = false;
    }
}

pub fn create_message_groups(
    my_did: DID,
    input: &VecDeque<ui_adapter::Message>,
) -> Vec<MessageGroup> {
    let mut messages: Vec<MessageGroup> = vec![];

    for msg in input.iter() {
        if let Some(group) = messages.iter_mut().last() {
            if group.sender == msg.inner.sender() {
                let g = MessageGroupMsg {
                    message: msg.clone(),
                    is_pending: false,
                    is_first: false,
                    is_last: true,
                };
                // I really hope last() is O(1) time
                if let Some(g) = group.messages.iter_mut().last() {
                    g.clear_last();
                }

                group.messages.push(g);
                continue;
            }
        }

        // new group
        let mut grp = MessageGroup::new(msg.inner.sender(), &my_did);
        let g = MessageGroupMsg {
            message: msg.clone(),
            is_pending: false,
            is_first: true,
            is_last: true,
        };
        grp.messages.push(g);
        messages.push(grp);
    }

    messages
}

pub fn pending_group_messages(pending: &Vec<PendingMessage>, own_did: DID) -> Option<MessageGroup> {
    if pending.is_empty() {
        return None;
    };
    let mut messages: Vec<MessageGroupMsg> = vec![];
    let size = pending.len();
    for (i, msg) in pending.iter().enumerate() {
        if i == size - 1 {
            let g = MessageGroupMsg {
                message: msg.message.clone(),
                is_pending: true,
                is_first: false,
                is_last: true,
            };
            messages.push(g);
            continue;
        }
        let g = MessageGroupMsg {
            message: msg.message.clone(),
            is_pending: true,
            is_first: true,
            is_last: true,
        };
        messages.push(g);
    }
    Some(MessageGroup {
        sender: own_did,
        remote: false,
        messages,
    })
}
