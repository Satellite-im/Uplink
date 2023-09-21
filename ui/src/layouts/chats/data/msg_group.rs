use std::collections::{HashMap, VecDeque};

use common::{state::pending_message::PendingMessage, warp_runner::ui_adapter};
use warp::{constellation::Progression, crypto::DID};

// Define a struct to represent a group of messages from the same sender.
#[derive(Clone)]
pub struct MessageGroup {
    pub sender: DID,
    pub remote: bool,
    pub messages: Vec<GroupedMessage>,
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

// Define a struct to represent a message that has been placed into a group.
#[derive(Clone)]
pub struct GroupedMessage {
    pub message: ui_adapter::Message,
    // todo: make this a hook
    pub attachment_progress: Option<HashMap<String, Progression>>,
    pub is_pending: bool,
    pub is_first: bool,
    pub is_last: bool,
    // if the user scrolls over this message, more messages should be loaded
    pub should_fetch_more: bool,
}

impl GroupedMessage {
    pub fn clear_last(&mut self) {
        self.is_last = false;
    }
}

pub fn create_message_groups(
    my_did: DID,
    mut input: VecDeque<ui_adapter::Message>,
) -> Vec<MessageGroup> {
    let mut messages: Vec<MessageGroup> = vec![];

    for msg in input.drain(..) {
        if let Some(group) = messages.iter_mut().last() {
            if group.sender == msg.inner.sender() {
                let g = GroupedMessage {
                    message: msg,
                    attachment_progress: None,
                    is_pending: false,
                    is_first: false,
                    is_last: true,
                    should_fetch_more: false,
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
        let g = GroupedMessage {
            message: msg,
            attachment_progress: None,
            is_pending: false,
            is_first: true,
            is_last: true,
            should_fetch_more: false,
        };
        grp.messages.push(g);
        messages.push(grp);
    }

    messages
}

pub fn pending_group_messages(
    mut pending: Vec<PendingMessage>,
    own_did: DID,
) -> Option<MessageGroup> {
    if pending.is_empty() {
        return None;
    };
    let mut messages: Vec<GroupedMessage> = vec![];
    let size = pending.len();
    for (i, msg) in pending.drain(..).enumerate() {
        if i == size - 1 {
            let g = GroupedMessage {
                message: msg.message,
                attachment_progress: Some(msg.attachments_progress),
                is_pending: true,
                is_first: false,
                is_last: true,
                should_fetch_more: false,
            };
            messages.push(g);
            continue;
        }
        let g = GroupedMessage {
            message: msg.message,
            attachment_progress: Some(msg.attachments_progress),
            is_pending: true,
            is_first: true,
            is_last: true,
            should_fetch_more: false,
        };
        messages.push(g);
    }
    Some(MessageGroup {
        sender: own_did,
        remote: false,
        messages,
    })
}
