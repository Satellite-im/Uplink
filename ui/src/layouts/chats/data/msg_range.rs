use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct MsgRange {
    start: usize,
    to_take: usize,
}

impl MsgRange {
    pub fn new(start: usize, to_take: usize) -> Self {
        Self { start, to_take }
    }

    pub fn start(&self) -> usize {
        self.start
    }

    pub fn to_take(&self) -> usize {
        self.to_take
    }

    pub fn take_more(&mut self, num: usize) {
        self.to_take += num;
    }

    pub fn take_less(&mut self, num: usize) {
        self.to_take = self.to_take.saturating_sub(num);
    }

    pub fn step_forward(&mut self, increment: usize, range_end: usize) {
        let max_increment = range_end - (self.start + self.to_take);
        let increment = std::cmp::min(max_increment, increment);
        self.start += increment;
    }

    pub fn step_backward(&mut self, decrement: usize) {
        self.start = self.start.saturating_sub(decrement);
    }
}
