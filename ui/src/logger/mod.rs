use colored::Colorize;
use once_cell::sync::Lazy;
use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::prelude::*;
use std::str::FromStr;
use warp::logging::tracing::log::{self, Level, LevelFilter, SetLoggerError};
use warp::sync::RwLock;

use chrono::{DateTime, Local};

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

// not sure what's worse. logs that are hard to read or needing to write this parsing code.
pub fn get_log_entries() -> Vec<Log> {
    // if you can't read the file, just return the logs in memory
    let in_mem = Vec::from_iter(LOGGER.read().log_entries.iter().cloned());
    let raw_logs = match std::fs::read_to_string(&STATIC_ARGS.logger_path) {
        Ok(l) => l,
        Err(e) => {
            log::error!("failed to read debug.log: {}", e);
            return in_mem;
        }
    };
    // if you can read the file, extract the fields
    let stored_logs: Vec<Option<Log>> = raw_logs
        .lines()
        .map(|line| {
            let mut entries = line.split('|').map(|x| x.trim());
            let datetime = match entries.next().and_then(|x| DateTime::from_str(x).ok()) {
                Some(d) => d,
                None => return None,
            };
            let level: Level = match entries.next().and_then(|s| Level::from_str(s).ok()) {
                Some(s) => s,
                None => return None,
            };
            let message = match entries.next() {
                Some(s) => s.into(),
                None => return None,
            };

            Some(Log {
                level,
                message,
                datetime,
            })
        })
        .collect();
    // get rid of lines which couldn't be parsed
    let flattened: Vec<Log> = stored_logs
        .iter()
        .filter(|x| x.is_some())
        .map(|x| x.clone().expect("get_log_entries failed"))
        .collect();

    // remove duplicate logs
    let earliest_in_mem = match in_mem.first().map(|x| x.datetime) {
        Some(d) => d,
        None => return flattened,
    };

    // combine
    flattened
        .iter()
        .filter(|x| x.datetime < earliest_in_mem)
        .chain(in_mem.iter())
        .cloned()
        .collect()
}

pub fn get_logs_limit() -> usize {
    LOGGER.read().max_logs
}

#[derive(Debug, Clone)]
pub struct Log {
    pub level: Level,
    pub message: String,
    pub datetime: DateTime<Local>,
}

impl std::fmt::Display for Log {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let level = get_level_string(self.level);
        let datetime = &self.datetime.to_string()[0..19];
        write!(f, "{} | {} | {}", datetime, level, self.message)
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
            datetime: Local::now(),
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
