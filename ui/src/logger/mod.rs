//! custom logging implementation
//! use with the log crate
//! has options to save logs to a file, print to the terminal, and send new logs to anyone who asks (via logger::subscribe())
//! this hopefully satisfies the needs of everyone:
//!     - people who prefer to view logs in the terminal (with and without saving the logs)
//!     - people who prefer to view logs in the debug_logger GUI
//!
//! the debug_logger GUI loads all entries from debug.log and then adds new logs to the display.
//!
//! for readability, the `Log` struct implements display, and logs are written to the file in a regular log format, rather than using Serde::Serialize
//!
//! for simplicity, the debug_logger should parse these fields directly. this seems better than converting the
//! debug log back into a Log struct (would be easier for debug_logger but more difficult overall)

use colored::Colorize;
use once_cell::sync::Lazy;
use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::prelude::*;
use tokio::sync::mpsc;
use warp::logging::tracing::log::{self, Level, LevelFilter, SetLoggerError};
use warp::sync::RwLock;

use chrono::{DateTime, Local};

use common::STATIC_ARGS;

static LOGGER: Lazy<RwLock<Logger>> = Lazy::new(|| RwLock::new(Logger::load()));

#[derive(Debug, Clone)]
pub struct Log {
    pub level: Level,
    pub message: String,
    pub datetime: DateTime<Local>,
    pub colorized: bool,
}

impl std::fmt::Display for Log {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let datetime = &self.datetime.to_string()[0..19];
        let level = self.get_level_string();
        write!(f, "{} | {} | {}", datetime, level, self.message)
    }
}

#[derive(Debug, Clone)]
pub struct Logger {
    log_file: String,
    // holds the last `max_logs` in memory, unless `save_to_file` is true. when `save_to_file` is set to true, `log_entries` are written to disk.
    log_entries: VecDeque<Log>,
    subscribers: Vec<mpsc::UnboundedSender<Log>>,
    max_logs: usize,
    save_to_file: bool,
    write_to_stdout: bool,
    display_trace: bool,
    display_warp: bool,
}

// connects the `log` crate to the `Logger` singleton
struct LogGlue {
    max_level: LevelFilter,
}

impl LogGlue {
    pub fn new(max_level: LevelFilter) -> Self {
        Self { max_level }
    }
}

impl crate::log::Log for LogGlue {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= self.max_level
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) {
            return;
        }

        // don't care about other libraries
        if record.file().map(|x| x.contains(".cargo")).unwrap_or(true) {
            if LOGGER.read().display_warp
                && record.file().map(|x| x.contains("warp")).unwrap_or(false)
            {
                let msg = format!("{}", record.args());
                LOGGER.write().log_warp(record.level(), &msg);
            }
            return;
        }

        let msg = format!("{}", record.args());
        LOGGER.write().log(record.level(), &msg);
    }

    fn flush(&self) {}
}

impl Logger {
    fn load() -> Self {
        let logger_path = STATIC_ARGS.logger_path.to_string_lossy().to_string();
        let _ = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&logger_path);

        Self {
            save_to_file: false,
            display_warp: false,
            write_to_stdout: false,
            display_trace: false,
            log_file: logger_path,
            subscribers: vec![],
            log_entries: VecDeque::new(),
            max_logs: 128,
        }
    }

    fn subscribe(&mut self) -> mpsc::UnboundedReceiver<Log> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.subscribers.push(tx);
        rx
    }
}

impl Logger {
    fn log(&mut self, level: Level, message: &str) {
        let new_log = Log {
            level,
            message: message.to_string(),
            datetime: Local::now(),
            colorized: false,
        };

        // special path for Trace logs
        // don't persist tracing information. at most, print it to the terminal
        if level == Level::Trace && self.display_trace {
            println!("{}", new_log.colorize());
            return;
        }

        if self.save_to_file {
            let mut file = OpenOptions::new()
                .append(true)
                .create(true)
                .open(&self.log_file)
                .unwrap();

            if let Err(error) = writeln!(file, "{new_log}") {
                eprintln!("Couldn't write to debug.log file. {error}");
            }
        } else {
            self.log_entries.push_back(new_log.clone());

            if self.log_entries.len() >= self.max_logs {
                self.log_entries.pop_front();
            }
        }

        if self.write_to_stdout {
            println!("{}", new_log.colorize())
        }

        // if a subscriber closes a channel, send() will fail. remove from subscribers
        self.subscribers.retain(|x| x.send(new_log.clone()).is_ok());
    }

    fn log_warp(&mut self, level: Level, message: &str) {
        let new_log = Log {
            level,
            message: message.to_string(),
            datetime: Local::now(),
            colorized: false,
        };

        println!("{new_log}");
    }

    fn set_save_to_file(&mut self, enabled: bool) {
        self.save_to_file = enabled;

        if enabled {
            return;
        }

        let mut file = OpenOptions::new()
            .append(true)
            .create(true)
            .open(&self.log_file)
            .unwrap();

        for entry in self.log_entries.drain(..) {
            if let Err(error) = writeln!(file, "{entry}") {
                eprintln!("Couldn't write to debug.log file. {error}");
            }
        }
    }
}

pub fn init_with_level(level: LevelFilter) -> Result<(), SetLoggerError> {
    log::set_max_level(level);
    log::set_boxed_logger(Box::new(LogGlue::new(level)))?;
    Ok(())
}

// used for panic handlers
pub fn dump_logs() -> String {
    let logs = get_logs();
    LOGGER.write().log_entries.clear();
    logs
}

// used for bug report
pub fn get_logs() -> String {
    let logs: Vec<String> = LOGGER
        .read()
        .log_entries
        .iter()
        .map(|x| x.to_string())
        .collect();
    logs.join("\n")
}

pub fn subscribe() -> mpsc::UnboundedReceiver<Log> {
    LOGGER.write().subscribe()
}

pub fn set_display_trace(b: bool) {
    LOGGER.write().display_trace = b;
}

pub fn set_save_to_file(b: bool) {
    LOGGER.write().set_save_to_file(b);
}

pub fn set_display_warp(b: bool) {
    LOGGER.write().display_warp = b;
}

pub fn get_save_to_file() -> bool {
    LOGGER.write().save_to_file
}

pub fn set_write_to_stdout(b: bool) {
    LOGGER.write().write_to_stdout = b;
}

pub fn load_debug_log() -> Vec<String> {
    let raw_file = match std::fs::read_to_string(&STATIC_ARGS.logger_path) {
        Ok(l) => l,
        Err(e) => {
            log::error!("failed to read debug.log: {}", e);
            return vec![];
        }
    };

    let mut in_memory: Vec<_> = LOGGER
        .read()
        .log_entries
        .iter()
        .map(|x| x.to_string())
        .collect();

    raw_file
        .lines()
        .map(|x| x.to_string())
        .chain(in_memory.drain(..))
        .collect::<Vec<_>>()
}

// this is kind of a hack. but Colorize adds characters to a string which display differently in the debug_logger and the terminal.
impl Log {
    fn colorize(&self) -> Self {
        let mut log = self.clone();
        log.colorized = true;
        log
    }

    fn get_level_string(&self) -> String {
        if !self.colorized {
            return self.level.to_string();
        }

        let level = &self.level;
        match self.level {
            Level::Error => level.to_string().red().to_string(),
            Level::Warn => level.to_string().yellow().to_string(),
            Level::Info => level.to_string().cyan().to_string(),
            Level::Debug => level.to_string().purple().to_string(),
            Level::Trace => level.to_string().normal().to_string(),
        }
    }
}
