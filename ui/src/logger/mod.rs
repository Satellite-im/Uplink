use std::fs::{self, OpenOptions};
use std::io::prelude::*;
use std::path::Path;
use std::sync::Mutex;

#[derive(Debug, Clone)]
struct Log {
    level: LogLevel,
    message: String,
}

#[derive(Debug, Clone)]
enum LogLevel {
    Debug,
    Warn,
    Info,
    Error,
}

pub struct Logger {
    log_file: String,
    log_entries: Mutex<Vec<Log>>,
}

impl Logger {
    pub fn get() -> Logger {
        let log_file = ".uplink/debug.log".to_string();
        let log_entries = Mutex::new(Vec::new());
        Logger {
            log_file: log_file.clone(),
            log_entries,
        }
    }

    fn log(&self, level: LogLevel, message: &str) {
        let error = Log {
            level,
            message: message.to_string(),
        };

        let mut log_entries = self.log_entries.lock().unwrap();
        log_entries.push(error.clone());

        let mut file = OpenOptions::new()
            .append(true)
            .open(&self.log_file)
            .unwrap();

        if let Err(e) = writeln!(file, "{:?}", error.clone()) {
            eprintln!("Couldn't write to file: {}", e);
        }
    }

    pub fn debug(&self, message: &str) {
        self.log(LogLevel::Debug, message);
    }

    pub fn warn(&self, message: &str) {
        self.log(LogLevel::Warn, message);
    }

    pub fn info(&self, message: &str) {
        self.log(LogLevel::Info, message);
    }

    pub fn error(&self, message: &str) {
        self.log(LogLevel::Error, message);
    }

    pub fn show_log(&self) {
        let log_entries = self.log_entries.lock().unwrap();
        println!("{:?}", log_entries);
    }
}
