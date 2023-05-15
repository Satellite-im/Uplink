use std::{collections::HashMap, path::PathBuf};

use warp::constellation::Progression;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingMessage {
    text: Vec<String>,
    attachments: HashMap<PathBuf, Option<Progression>>,
}

impl PendingMessage {
    pub fn new(text: Vec<String>, attachments: Vec<PathBuf>) -> Self {
        PendingMessage {
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
