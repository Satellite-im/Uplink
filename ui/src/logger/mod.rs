use std::fs::{File, OpenOptions};
use std::io::{prelude::*, BufReader};
use std::sync::Mutex;
#[derive(Debug, Clone)]
pub struct Log {
    pub level: LogLevel,
    pub message: String,
}

#[derive(Debug, Clone)]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

impl LogLevel {
    pub fn from_str(log_level: &str) -> Self {
        match log_level.trim() {
            "Debug" => LogLevel::Debug,
            "Warn" => LogLevel::Warn,
            "Info" => LogLevel::Info,
            "Error" => LogLevel::Error,
            _ => LogLevel::Debug,
        }
    }
    pub fn color(&self) -> &'static str {
        match self {
            LogLevel::Debug => "white",
            LogLevel::Info => "blue",
            LogLevel::Warn => "yellow",
            LogLevel::Error => "red",
        }
    }
}

pub struct Logger {
    log_file: String,
    log_entries: Mutex<Vec<Log>>,
}

impl Logger {
    pub fn load() -> Logger {
        let log_file = ".uplink/debug.log".to_string();
        let _ = OpenOptions::new().create(true).append(true).open(&log_file);

        let log_entries = Mutex::new(Vec::new());
        Logger {
            log_file,
            log_entries,
        }
    }

    fn log(&self, level: LogLevel, message: &str) {
        let new_log = Log {
            level,
            message: message.to_string(),
        };

        let mut log_entries = self.log_entries.lock().unwrap();
        log_entries.push(new_log.clone());

        let mut file = OpenOptions::new()
            .append(true)
            .open(&self.log_file)
            .unwrap();

        if let Err(e) = writeln!(file, "{:?}", new_log.clone()) {
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

    pub fn show_log(&self) -> Vec<Log> {
        let file = File::open(".uplink/debug.log").expect("Unable to open debug.log");
        let reader = BufReader::new(file);
        let mut logs: Vec<Log> = vec![];
        for line in reader.lines() {
            let line = line.expect("Unable to read line");
            let parts: Vec<&str> = line.split(":").collect();
            let message_part = parts.last().unwrap();
            let message = message_part.split("\"").nth(1).unwrap().to_string();
            let level_string_parts: Vec<&str> = parts[1].split(",").collect();
            println!("{:?}", level_string_parts);
            let level_string = level_string_parts.first().unwrap();
            println!("{:?}", level_string);

            let level = LogLevel::from_str(*level_string);
            let log = Log { level, message };
            logs.push(log);
        }
        logs
    }
}
