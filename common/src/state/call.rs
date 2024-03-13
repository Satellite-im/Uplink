use std::{
    collections::HashMap,
    time::{Duration, Instant},
};

use anyhow::bail;
use chrono::{DateTime, Local};
use dioxus_desktop::tao::window::WindowId;
use uuid::Uuid;
use warp::{blink::ParticipantState, crypto::DID};

#[derive(Clone, Default)]
pub struct CallInfo {
    active_call: Option<ActiveCall>,
    pending_calls: Vec<Call>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct ActiveCall {
    pub call: Call,
    pub answer_time: DateTime<Local>,
    pub popout_window_id: Option<WindowId>,
}

impl From<Call> for ActiveCall {
    fn from(value: Call) -> Self {
        Self {
            call: value,
            answer_time: Local::now(),
            popout_window_id: None,
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct Call {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub participants: Vec<DID>,
    pub participants_joined: HashMap<DID, ParticipantState>,
    pub participants_speaking: HashMap<DID, Instant>,
    pub self_muted: bool,
    pub call_silenced: bool,
}

impl CallInfo {
    pub fn active_call(&self) -> Option<ActiveCall> {
        self.active_call.clone()
    }
    pub fn active_call_id(&self) -> Option<Uuid> {
        self.active_call.as_ref().map(|x| x.call.id)
    }
    pub fn pending_calls(&self) -> Vec<Call> {
        self.pending_calls.clone()
    }
    pub fn offer_call(&mut self, id: Uuid, conversation_id: Uuid, participants: Vec<DID>) {
        self.active_call
            .replace(Call::new(id, conversation_id, participants).into());
    }

    pub fn end_call(&mut self) {
        self.active_call.take();
    }

    pub fn answer_call(&mut self, id: Uuid, did: Option<DID>) -> anyhow::Result<Call> {
        match self.pending_calls.iter().position(|x| x.id == id) {
            Some(idx) => {
                let mut call = self.pending_calls.remove(idx);
                if let Some(did) = did {
                    call.participant_joined(did);
                }
                self.active_call.replace(call.clone().into());
                Ok(call)
            }
            None => bail!("call not pending"),
        }
    }

    pub fn reject_call(&mut self, id: Uuid) {
        self.pending_calls.retain(|x| x.id != id);
    }

    pub fn pending_call(
        &mut self,
        id: Uuid,
        conversation_id: Uuid,
        participants: Vec<DID>,
    ) -> anyhow::Result<()> {
        if self.pending_calls.iter().any(|x| x.id == id) {
            bail!("call with that id was already pending");
        }
        self.pending_calls
            .push(Call::new(id, conversation_id, participants));
        Ok(())
    }

    pub fn remove_pending_call(&mut self, id: Uuid) {
        self.pending_calls.retain(|x| x.id != id);
    }

    pub fn remove_participant(&mut self, conversation_id: Uuid, id: &DID) -> anyhow::Result<()> {
        if let Some(active_call) = self.active_call.as_mut() {
            if active_call.call.conversation_id.eq(&conversation_id) {
                active_call.call.remove_participant(id);
            }
        }
        self.pending_calls.iter_mut().for_each(|c| {
            if c.conversation_id.eq(&conversation_id) {
                c.remove_participant(id);
            }
        });
        Ok(())
    }

    pub fn participant_speaking(&mut self, id: DID) -> anyhow::Result<()> {
        let active_call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        active_call.call.participant_speaking(id);
        Ok(())
    }

    pub fn participant_joined(&mut self, call_id: Uuid, id: DID) -> anyhow::Result<()> {
        let active_call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        if active_call.call.id != call_id {
            bail!("wrong call id");
        }
        active_call.call.participant_joined(id);
        Ok(())
    }

    pub fn participant_left(&mut self, call_id: Uuid, id: &DID) -> anyhow::Result<()> {
        let active_call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        if active_call.call.id != call_id {
            bail!("wrong call id");
        }
        active_call.call.participant_left(id);
        Ok(())
    }

    pub fn update_active_call(&mut self) -> bool {
        if let Some(active_call) = self.active_call.as_mut() {
            return active_call.call.update_speaking_participants();
        };
        false
    }

    pub fn update_participant_state(
        &mut self,
        id: DID,
        state: ParticipantState,
    ) -> anyhow::Result<()> {
        let active_call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        active_call.call.update_participant_state(id, state);
        Ok(())
    }

    pub fn mute_self(&mut self) -> anyhow::Result<()> {
        let active_call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        active_call.call.mute_self();
        Ok(())
    }

    pub fn unmute_self(&mut self) -> anyhow::Result<()> {
        let active_call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        active_call.call.unmute_self();
        Ok(())
    }

    pub fn silence_call(&mut self) -> anyhow::Result<()> {
        let active_call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        active_call.call.silence_call();
        Ok(())
    }

    pub fn unsilence_call(&mut self) -> anyhow::Result<()> {
        let active_call = match self.active_call.as_mut() {
            Some(c) => c,
            None => bail!("call not in progress"),
        };
        active_call.call.unsilence_call();
        Ok(())
    }

    pub fn set_popout_window_id(&mut self, popout_window_id: WindowId) {
        if let Some(ac) = self.active_call.as_mut() {
            ac.popout_window_id = Some(popout_window_id);
        }
    }
    pub fn take_popout_window_id(&mut self) -> Option<WindowId> {
        if let Some(ac) = self.active_call.as_mut() {
            ac.popout_window_id.take()
        } else {
            None
        }
    }
}

impl Call {
    pub fn new(id: Uuid, conversation_id: Uuid, participants: Vec<DID>) -> Self {
        Self {
            id,
            conversation_id,
            participants,
            participants_joined: HashMap::new(),
            participants_speaking: HashMap::new(),
            self_muted: false,
            call_silenced: false,
        }
    }

    fn remove_participant(&mut self, id: &DID) {
        self.participants.retain(|x| x != id);
        self.participant_left(id);
        self.participant_not_speaking(id);
    }

    fn participant_joined(&mut self, id: DID) {
        if self.participants.contains(&id) && !self.participants_joined.contains_key(&id) {
            self.participants_joined
                .insert(id, ParticipantState::default());
        }
    }

    fn participant_left(&mut self, id: &DID) {
        self.participants_joined.remove(id);
    }

    fn participant_speaking(&mut self, id: DID) {
        if self.participants.contains(&id) {
            self.participants_speaking.insert(id, Instant::now());
        }
    }

    fn update_speaking_participants(&mut self) -> bool {
        let delay = Duration::from_secs(3);
        let len = self.participants_speaking.len();
        self.participants_speaking
            .retain(|_, time| time.elapsed() <= delay);
        len != self.participants_speaking.len()
    }

    fn participant_not_speaking(&mut self, id: &DID) {
        self.participants_speaking.remove(id);
    }

    fn mute_self(&mut self) {
        self.self_muted = true;
    }

    fn unmute_self(&mut self) {
        self.self_muted = false;
    }

    fn update_participant_state(&mut self, id: DID, state: ParticipantState) {
        if self.participants.contains(&id) {
            self.participants_joined.insert(id, state);
        }
    }

    fn silence_call(&mut self) {
        self.call_silenced = true;
    }

    fn unsilence_call(&mut self) {
        self.call_silenced = false;
    }
}
