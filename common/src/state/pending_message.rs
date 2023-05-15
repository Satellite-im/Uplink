use std::{collections::HashMap, path::PathBuf};

use warp::constellation::Progression;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingSentMessages {
    msg: Vec<PendingSentMessage>,
}

impl PendingSentMessages {
    pub fn new() -> Self {
        PendingSentMessages { msg: vec![] }
    }

    pub fn append(mut self, msg: Vec<String>, attachments: Vec<PathBuf>) -> Self {
        self.msg.push(PendingSentMessage::new(msg, attachments));
        self
    }

    pub fn update(mut self, msg: Vec<String>, progress: (PathBuf, Progression)) -> Self {
        self
    }

    pub fn finish(mut self, msg: Vec<String>, attachments: usize) -> Self {
        self
    }
}

#[derive(Clone, Debug)]
pub struct PendingSentMessage {
    text: Vec<String>,
    attachments: HashMap<PathBuf, Option<Progression>>,
}

impl PendingSentMessage {
    pub fn new(text: Vec<String>, attachments: Vec<PathBuf>) -> Self {
        PendingSentMessage {
            text,
            attachments: {
                let mut m = HashMap::new();
                attachments.iter().for_each(|p| {
                    m.insert(p.clone(), None);
                });
                m
            },
        }
    }
}

impl PartialEq for PendingSentMessage {
    fn eq(&self, other: &Self) -> bool {
        self.text.eq(&other.text)
            && self
                .attachments
                .keys()
                .all(|k| other.attachments.contains_key(k))
    }
}

impl Eq for PendingSentMessage {}
