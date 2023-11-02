#[derive(Eq, PartialEq)]
pub enum TypingIndicator {
    // reset the typing indicator timer
    Typing(uuid::Uuid),
    // clears the typing indicator, ensuring the indicator
    // will not be refreshed
    NotTyping,
    // resend the typing indicator
    Refresh(uuid::Uuid),
}
