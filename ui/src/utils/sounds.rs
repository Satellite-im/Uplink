

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
        let (_stream, audio_handle) = rodio::OutputStream::try_default().unwrap();
        // Load the appropriate sound file based on the `sound` argument
        let buffer = match sound {
            Sounds::Notification => NOTIFICATION_SOUND,
            Sounds::FriendReq => FRIEND_SOUND,
            // The `General` case is not handled
            Sounds::General => return
        };
        //TODO: Maybe append into sink instead?
        let sound = audio_handle.play_once(std::io::Cursor::new(buffer)).unwrap();

        sound.sleep_until_end();
    });
}
