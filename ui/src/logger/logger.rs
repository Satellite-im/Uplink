use once_cell::sync::Lazy;
use regex::Regex;
use std::fs::{File, OpenOptions};
use std::io::{prelude::*, BufReader};
use std::sync::Mutex;
use warp::sync::RwLock;

use chrono::{Local, NaiveTime};

static LOG_ACTIVE: Lazy<RwLock<bool>> = Lazy::new(|| RwLock::new(false));

pub static LOGGER: Lazy<RwLock<Logger>> = Lazy::new(|| RwLock::new(Logger::load()));

#[derive(Debug, Clone)]
pub struct Log {
    pub level: LogLevel,
    pub message: String,
    pub datetime: String,
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
            LogLevel::Info => "rgb(0, 195, 255)",
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
    pub fn activate_logger() {
        *LOG_ACTIVE.write() = true;
    }

    fn load() -> Logger {
        let log_file = ".uplink/debug.log".to_string();
        let _ = OpenOptions::new().create(true).append(true).open(&log_file);
        let log_entries = Mutex::new(Vec::new());
        Logger {
            log_file,
            log_entries,
        }
    }
}

impl Logger {
    fn log(&self, level: LogLevel, message: &str) {
        if *LOG_ACTIVE.read() {
            let new_log = Log {
                level,
                message: message.to_string(),
                datetime: Local::now().to_string(),
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
    }

    pub fn debug(message: &str) {
        LOGGER.read().log(LogLevel::Debug, message);
    }

    pub fn warn(message: &str) {
        LOGGER.read().log(LogLevel::Warn, message);
    }

    pub fn info(message: &str) {
        LOGGER.read().log(LogLevel::Info, message);
    }

    pub fn error(message: &str) {
        LOGGER.read().log(LogLevel::Error, message);
    }

    pub fn show_log(&self) -> Vec<Log> {
        let file = File::open(".uplink/debug.log").expect("Unable to open debug.log");
        let reader = BufReader::new(file);
        let mut logs: Vec<Log> = vec![];

        let re_level = Regex::new(r#"level: (.*?),"#).unwrap();
        let re_message = Regex::new(r#"message: "(.*?)""#).unwrap();
        let re_datetime = Regex::new(r#"datetime: "(.*?)""#).unwrap();

        for line in reader.lines() {
            let log = line.expect("Unable to read line");
            let level_string = re_level.captures(&log).unwrap()[1].to_string();
            let message = re_message.captures(&log).unwrap()[1].to_string();
            let datetime = re_datetime.captures(&log).unwrap()[1].to_string();
            let datetime_time = NaiveTime::parse_from_str(&datetime[11..19], "%H:%M:%S").unwrap();
            let level = LogLevel::from_str(&level_string);
            let log = Log {
                level,
                message,
                datetime: datetime_time.to_string(),
            };
            logs.push(log);
        }
        logs
    }
}
