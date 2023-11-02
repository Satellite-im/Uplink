#[derive(Clone)]
pub struct TypingInfo {
    pub chat_id: uuid::Uuid,
    pub last_update: std::time::Instant,
}
