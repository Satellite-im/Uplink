pub enum Sounds {
    Notification,
    FriendReq,
    General,
}

const NOTIFICATION_SOUND: &[u8] = include_bytes!("../../extra/assets/sounds/Ponderous.ogg");
const FRIEND_SOUND: &[u8] = include_bytes!("../../extra/assets/sounds/Success.ogg");

#[allow(non_snake_case)]
pub fn Play(sound: Sounds) {
    // Create a Soloud instance

    std::thread::spawn(move || {
        let Ok((_stream, audio_handle)) = rodio::OutputStream::try_default() else {
            return
        };
        // Load the appropriate sound file based on the `sound` argument
        let buffer = match sound {
            Sounds::Notification => NOTIFICATION_SOUND,
            Sounds::FriendReq => FRIEND_SOUND,
            // The `General` case is not handled
            Sounds::General => return,
        };
        //TODO: Maybe append into sink instead?
        if let Ok(sound) = audio_handle.play_once(std::io::Cursor::new(buffer)) {
            sound.sleep_until_end();
        }
    });
}
