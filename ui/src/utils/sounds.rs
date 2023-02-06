pub enum Sounds {
    Notification,
    Flip,
    General,
    Error,
    Interaction,
    On,
    Off,
}

const ERROR: &[u8] = include_bytes!("../../extra/assets/sounds/Error.ogg");
const FLIP: &[u8] = include_bytes!("../../extra/assets/sounds/Flip.ogg");
const INTERACTION: &[u8] = include_bytes!("../../extra/assets/sounds/Interaction.ogg");
const NOTIFICATION: &[u8] = include_bytes!("../../extra/assets/sounds/Notification.ogg");
const ON: &[u8] = include_bytes!("../../extra/assets/sounds/On.ogg");
const OFF: &[u8] = include_bytes!("../../extra/assets/sounds/Off.ogg");

#[allow(non_snake_case)]
pub fn Play(sound: Sounds) {
    // Create a Soloud instance
    std::thread::spawn(move || {
        let Ok((_stream, audio_handle)) = rodio::OutputStream::try_default() else {
            return
        };
        // Load the appropriate sound file based on the `sound` argument
        let buffer = match sound {
            Sounds::Notification => NOTIFICATION,
            Sounds::Flip => FLIP,
            Sounds::Error => ERROR,
            Sounds::Interaction => INTERACTION,
            Sounds::On => ON,
            Sounds::Off => OFF,
            Sounds::General => ERROR,
        };
        //TODO: Maybe append into sink instead?
        if let Ok(sound) = audio_handle.play_once(std::io::Cursor::new(buffer)) {
            sound.sleep_until_end();
        }
    });
}
