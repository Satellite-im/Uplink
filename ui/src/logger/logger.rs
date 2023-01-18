use dioxus_desktop::tao::window::WindowId;
use once_cell::sync::Lazy;
use regex::Regex;
use std::fs::{File, OpenOptions};
use std::io::{prelude::*, BufReader};
use std::sync::Mutex;
use warp::sync::RwLock;

use chrono::Local;

static LOG_ACTIVE: Lazy<RwLock<bool>> = Lazy::new(|| RwLock::new(false));

static DEBUG_LOG_PATH: &str = ".uplink/debug.log";

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

    pub fn to_str(&self) -> &str {
        match self {
            LogLevel::Debug => "DEBUG",
            LogLevel::Warn => "WARN",
            LogLevel::Info => "INFO",
            LogLevel::Error => "ERROR",
        }
    }

    pub fn color(&self) -> &'static str {
        match self {
            LogLevel::Debug => "rgb(0, 255, 0)",
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
        let log_file = DEBUG_LOG_PATH.to_string();
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

            if let Err(error) = writeln!(file, "{:?}", new_log.clone()) {
                Logger::error(format!("Couldn't write to debug.log file. {error}").as_str());
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
        let file = match File::open(DEBUG_LOG_PATH) {
            Ok(log) => log,
            Err(error) => {
                Logger::error(format!("Unable to read debug.log file. {error}").as_str());
                return Vec::new();
            }
        };

        let reader = BufReader::new(file);
        let mut logs: Vec<Log> = vec![];

        let re_level = Regex::new(r#"level: (.*?),"#).unwrap();
        let re_message = Regex::new(r#"message: "(.*?)""#).unwrap();
        let re_datetime = Regex::new(r#"datetime: "(.*?)""#).unwrap();

        for line in reader.lines() {
            let log = match line {
                Ok(log) => log,
                Err(error) => {
                    Logger::error(format!("Unable to read a line from log file. {error}").as_str());
                    continue;
                }
            };

            let level_string = re_level.captures(&log).unwrap()[1].to_string();
            let message = re_message.captures(&log).unwrap()[1].to_string();
            let datetime = re_datetime.captures(&log).unwrap()[1].to_string();

            let level = LogLevel::from_str(&level_string);
            let log = Log {
                level,
                message,
                datetime: datetime[0..19].to_string(),
            };
            logs.push(log);
        }
        logs
    }
}
