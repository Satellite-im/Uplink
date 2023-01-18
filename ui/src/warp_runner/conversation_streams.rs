use std::{collections::HashMap, pin::Pin};

use futures::{
    stream::{FuturesUnordered, Next},
    Stream, StreamExt,
};
use tokio::task::JoinHandle;
use uuid::Uuid;
use warp::raygun::{MessageEventKind, MessageEventStream};

use super::Messaging;

pub struct Manager<'a> {
    streams: HashMap<Uuid, JoinHandle>,
}

impl<'a> Manager<'a> {
    pub fn init() -> Self {
        Self {
            streams: HashMap::new(),
            futures: FuturesUnordered::new(),
        }
    }

    pub async fn add_conversation(&'a mut self, id: Uuid, messaging: &mut Messaging) {
        if self.streams.contains_key(&id) {
            return;
        }

        let stream = match messaging.get_conversation_stream(id).await {
            Ok(s) => s,
            Err(_e) => {
                //todo: log error
                return;
            }
        };

        self.streams.insert(id, stream);
        self.add_stream_to_fut(id);
    }

    pub fn remove_conversation(&'a mut self, id: Uuid) {
        self.streams.remove(&id);

        let futures = FuturesUnordered::new();
        for (_, stream) in &mut self.streams {
            futures.push(stream.next());
        }

        self.futures = futures;
    }

    pub async fn next(&'a mut self) -> Option<MessageEventKind> {
        self.futures
            .next()
            .await
            .and_then(|x| x)
            .map(|evt| match &evt {
                MessageEventKind::MessageSent {
                    conversation_id, ..
                }
                | MessageEventKind::MessageReceived {
                    conversation_id, ..
                }
                | MessageEventKind::MessageEdited {
                    conversation_id, ..
                }
                | MessageEventKind::MessageDeleted {
                    conversation_id, ..
                }
                | MessageEventKind::MessagePinned {
                    conversation_id, ..
                }
                | MessageEventKind::MessageUnpinned {
                    conversation_id, ..
                }
                | MessageEventKind::MessageReactionAdded {
                    conversation_id, ..
                }
                | MessageEventKind::MessageReactionRemoved {
                    conversation_id, ..
                }
                | MessageEventKind::RecipientAdded {
                    conversation_id, ..
                }
                | MessageEventKind::RecipientRemoved {
                    conversation_id, ..
                }
                | MessageEventKind::EventReceived {
                    conversation_id, ..
                }
                | MessageEventKind::EventCancelled {
                    conversation_id, ..
                } => {
                    self.add_stream_to_fut(*conversation_id);
                    evt
                }
            })
    }

    fn add_stream_to_fut(&'a mut self, id: Uuid) {
        let fut = match self.streams.get_mut(&id) {
            Some(s) => s.next(),
            None => return,
        };

        self.futures.push(fut);
    }
}
