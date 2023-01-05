use soloud::*;

pub enum Sounds {
    Notification,
    FriendReq,
    General,
}

#[allow(non_snake_case)]
pub fn Play(sound: Sounds) {
    // Create a Soloud instance
    let sl = Soloud::default().expect("Soloud::default");
    // Create a Wav instance
    let mut wav = audio::Wav::default();
    // Load the appropriate sound file based on the `sound` argument
    match sound {
        Sounds::Notification => wav
            .load_mem(include_bytes!("../../extra/assets/sounds/Ponderous.ogg"))
            .expect("Ponderous.ogg"),
        Sounds::FriendReq => wav
            .load_mem(include_bytes!("../../extra/assets/sounds/Success.ogg"))
            .expect("Success.ogg"),
        // The `General` case is not handled
        Sounds::General => {}
    };
    // Play the sound
    sl.play(&wav);
    // Wait until the sound finishes playing
    while sl.voice_count() > 0 {
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}
