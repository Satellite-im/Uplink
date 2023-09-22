use std::collections::{HashMap, VecDeque};

use common::{
    state::{pending_message::PendingMessage, GroupedMessage, MessageGroup},
    warp_runner::ui_adapter,
};
use warp::{constellation::Progression, crypto::DID};

pub fn create_message_groups<'a>(
    my_did: DID,
    input: &'a VecDeque<ui_adapter::Message>,
) -> Vec<MessageGroup<'a>> {
    let mut messages: Vec<MessageGroup> = vec![];

    for msg in input.iter() {
        if let Some(group) = messages.iter_mut().last() {
            if group.sender == msg.inner.sender() {
                let g = GroupedMessage {
                    message: &msg,
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
            message: &msg,
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
