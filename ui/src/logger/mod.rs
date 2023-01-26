use colored::Colorize;
use once_cell::sync::Lazy;
use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::prelude::*;
use warp::logging::tracing::log::{self, Level, LevelFilter, SetLoggerError};
use warp::sync::RwLock;

use chrono::Local;

use crate::STATIC_ARGS;

static LOGGER: Lazy<RwLock<Logger>> = Lazy::new(|| RwLock::new(Logger::load()));

pub fn init_with_level(level: LevelFilter) -> Result<(), SetLoggerError> {
    log::set_max_level(level);
    log::set_boxed_logger(Box::new(LogGlue::new(level)))?;
    Ok(())
}

// todo: remove these slowly and replace with log macros
pub fn trace(msg: &str) {
    log::trace!("{msg}");
}

pub fn debug(msg: &str) {
    log::debug!("{msg}");
}

pub fn info(msg: &str) {
    log::info!("{msg}");
}

pub fn warn(msg: &str) {
    log::warn!("{msg}");
}

pub fn error(msg: &str) {
    log::error!("{msg}");
}

pub fn set_save_to_file(b: bool) {
    LOGGER.write().save_to_file = b;
}

pub fn get_save_to_file() -> bool {
    LOGGER.write().save_to_file
}

pub fn set_write_to_stdout(b: bool) {
    LOGGER.write().write_to_stdout = b;
}

pub fn set_max_logs(s: usize) {
    LOGGER.write().max_logs = s;
}

pub fn set_display_trace(b: bool) {
    LOGGER.write().display_trace = b;
}

pub fn get_log_entries() -> Vec<Log> {
    Vec::from_iter(LOGGER.read().log_entries.iter().cloned())
}

pub fn get_logs_limit() -> usize {
    LOGGER.read().max_logs
}

#[derive(Debug, Clone)]
pub struct Log {
    pub level: Level,
    pub message: String,
    pub datetime: String,
}

impl std::fmt::Display for Log {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let level = get_level_string(self.level);
        write!(f, "{} | {} | {}", self.datetime, level, self.message)
    }
}

fn get_level_string(level: Level) -> String {
    match level {
        Level::Error => level.to_string().red().to_string(),
        Level::Warn => level.to_string().yellow().to_string(),
        Level::Info => level.to_string().cyan().to_string(),
        Level::Debug => level.to_string().purple().to_string(),
        Level::Trace => level.to_string().normal().to_string(),
    }
}

pub fn get_color_string(level: Level) -> &'static str {
    match level {
        Level::Debug | Level::Trace => "rgb(0, 255, 0)",
        Level::Info => "rgb(0, 195, 255)",
        Level::Warn => "yellow",
        Level::Error => "red",
    }
}

#[derive(Debug, Clone)]
pub struct Logger {
    save_to_file: bool,
    write_to_stdout: bool,
    display_trace: bool,
    log_file: String,
    log_entries: VecDeque<Log>,
    max_logs: usize,
}

impl Logger {
    fn load() -> Self {
        let logger_path = STATIC_ARGS.logger_path.to_string_lossy().to_string();
        let _ = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&logger_path);

        let log_entries = VecDeque::new();
        Self {
            save_to_file: false,
            write_to_stdout: false,
            display_trace: false,
            log_file: logger_path,
            log_entries,
            max_logs: 100, // todo: configurable?
        }
    }
}

impl Logger {
    fn log(&mut self, level: Level, message: &str) {
        let new_log = Log {
            level,
            message: message.to_string(),
            datetime: Local::now().to_string()[0..19].to_string(),
        };

        // special path for Trace logs
        // don't persist tracing information. at most, print it to the terminal
        if level == Level::Trace && self.display_trace {
            println!("{}", new_log);
            return;
        }

        self.log_entries.push_back(new_log.clone());

        if self.log_entries.len() >= self.max_logs {
            self.log_entries.pop_front();
        }

        if self.save_to_file {
            let mut file = OpenOptions::new()
                .append(true)
                .open(&self.log_file)
                .unwrap();

            if let Err(error) = writeln!(file, "{}", new_log) {
                eprintln!("Couldn't write to debug.log file. {error}");
            }
        }

        if self.write_to_stdout {
            println!("{}", new_log)
        }
    }
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

        // todo: send .warp logs somewhere else
        // don't care about other libraries
        if record.file().map(|x| x.contains(".cargo")).unwrap_or(true) {
            return;
        }

        let msg = format!("{}", record.args());
        LOGGER.write().log(record.level(), &msg);
    }

    fn flush(&self) {}
}
