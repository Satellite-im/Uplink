use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use warp::logging::tracing::log;

pub enum Sounds {
    Notification,
    Flip,
    General,
    Error,
    Interaction,
    On,
    Off,
}

pub enum ContinousSound {
    RingTone,
}

const ERROR: &[u8] = include_bytes!("sounds/Error.ogg");
const FLIP: &[u8] = include_bytes!("sounds/Flip.ogg");
const INTERACTION: &[u8] = include_bytes!("sounds/Interaction.ogg");
const NOTIFICATION: &[u8] = include_bytes!("sounds/Notification.ogg");
const ON: &[u8] = include_bytes!("sounds/On.ogg");
const OFF: &[u8] = include_bytes!("sounds/Off.ogg");
const RING_TONE: &[u8] = include_bytes!("sounds/RingTone.ogg");

#[allow(non_snake_case)]
pub fn Play(sound: Sounds) {
    // Create a Soloud instance
    std::thread::spawn(move || {
        let Ok((_stream, audio_handle)) = rodio::OutputStream::try_default() else {
            return;
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

// Play a sound till the condition has no refs anymore or is set to false
#[allow(non_snake_case)]
pub fn PlayUntil(sound: ContinousSound, condition: Arc<AtomicBool>) {
    // Create a Soloud instance
    std::thread::spawn(move || {
        let Ok((_stream, audio_handle)) = rodio::OutputStream::try_default() else {
            return;
        };
        let buffer = match sound {
            ContinousSound::RingTone => RING_TONE,
        };
        let mut sound_inst = None;
        loop {
            match sound_inst.as_ref() {
                None => {
                    if let Ok(sound) = audio_handle.play_once(std::io::Cursor::new(buffer)) {
                        sound_inst = Some(sound);
                    }
                }
                Some(sound) => {
                    if sound.empty() {
                        sound_inst = None
                    }
                }
            }
            if Arc::strong_count(&condition) <= 1 || condition.load(Ordering::Relaxed) {
                if let Some(sound) = sound_inst {
                    log::trace!("Stopping ringtone");
                    sound.stop();
                }
                return;
            }
        }
    });
}
