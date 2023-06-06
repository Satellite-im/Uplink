use std::collections::{HashMap, HashSet};

use anyhow::bail;
use uuid::Uuid;
use warp::crypto::DID;

#[derive(Clone, Default)]
pub struct CallInfo {
    active_call: Option<Call>,
    pending_calls: HashMap<Uuid, Call>,
}

#[derive(Clone)]
pub struct Call {
    pub id: Uuid,
    pub participants: Vec<DID>,
    pub participants_joined: HashSet<DID>,
    pub participants_speaking: HashSet<DID>,
    pub self_muted: bool,
    pub call_silenced: bool,
}

impl CallInfo {
    pub fn active_call(&self) -> Option<Call> {
        self.active_call.clone()
    }
    pub fn active_call_id(&self) -> Option<Uuid> {
        self.active_call.as_ref().map(|x| x.id)
    }
    pub fn pending_calls(&self) -> HashMap<Uuid, Call> {
        self.pending_calls.clone()
    }
    pub fn offer_call(&mut self, id: Uuid, participants: Vec<DID>) {
        self.active_call.replace(Call::new(id, participants));
    }

    pub fn end_call(&mut self) {
        self.active_call.take();
    }

    pub fn answer_call(&mut self, id: Uuid) -> anyhow::Result<()> {
        match self.pending_calls.remove(&id) {
            Some(call) => self.active_call.replace(call),
            None => bail!("call not pending"),
        };
        Ok(())
    }

    pub fn reject_call(&mut self, id: Uuid) {
        self.pending_calls.remove(&id);
    }

    pub fn pending_call(&mut self, id: Uuid, participants: Vec<DID>) -> anyhow::Result<()> {
        match self.pending_calls.insert(id, Call::new(id, participants)) {
            None => Ok(()),
            Some(_) => bail!("call with that id was already pending"),
        }
    }

    pub fn participant_joined(&mut self, call_id: Uuid, id: DID) -> anyhow::Result<()> {
        let call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        if call.id != call_id {
            bail!("wrong call id");
        }
        call.participant_joined(id);
        Ok(())
    }

    pub fn participant_left(&mut self, call_id: Uuid, id: DID) -> anyhow::Result<()> {
        let call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        if call.id != call_id {
            bail!("wrong call id");
        }
        call.participant_left(id);
        Ok(())
    }

    pub fn participant_speaking(&mut self, id: DID) -> anyhow::Result<()> {
        let call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        call.participant_speaking(id);
        Ok(())
    }

    pub fn participant_not_speaking(&mut self, id: DID) -> anyhow::Result<()> {
        let call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        call.participant_not_speaking(id);
        Ok(())
    }

    pub fn mute_self(&mut self) -> anyhow::Result<()> {
        let call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        call.mute_self();
        Ok(())
    }

    pub fn unmute_self(&mut self) -> anyhow::Result<()> {
        let call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        call.unmute_self();
        Ok(())
    }
}

impl Call {
    fn new(id: Uuid, participants: Vec<DID>) -> Self {
        Self {
            id,
            participants,
            participants_joined: HashSet::new(),
            participants_speaking: HashSet::new(),
            self_muted: false,
            call_silenced: false,
        }
    }

    fn participant_joined(&mut self, id: DID) {
        self.participants_joined.insert(id);
    }

    fn participant_left(&mut self, id: DID) {
        self.participants_joined.remove(&id);
    }

    fn participant_speaking(&mut self, id: DID) {
        self.participants_speaking.insert(id);
    }

    fn participant_not_speaking(&mut self, id: DID) {
        self.participants_speaking.remove(&id);
    }

    fn mute_self(&mut self) {
        self.self_muted = true;
    }

    fn unmute_self(&mut self) {
        self.self_muted = false;
    }
}
