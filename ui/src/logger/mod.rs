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
use log::{self, Level, LevelFilter, SetLoggerError};
use once_cell::sync::Lazy;
use std::collections::HashSet;
use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::prelude::*;
use std::path::PathBuf;
use tokio::sync::mpsc;
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

#[derive(Debug)]
pub struct Logger {
    file_tx: Option<std::sync::mpsc::SyncSender<Log>>,
    file_thread: Option<std::thread::JoinHandle<()>>,
    log_file: PathBuf,
    // holds the last `max_logs` in memory, unless `save_to_file` is true. when `save_to_file` is set to true, `log_entries` are written to disk.
    log_entries: VecDeque<Log>,
    subscribers: Vec<mpsc::UnboundedSender<Log>>,
    max_logs: usize,
    write_to_stdout: bool,

    // minimum log level for 3rd party crates (warp, dioxus, etc)
    max_level_3rd_party: Option<Level>,
    whitelist: Option<HashSet<String>>,
}

// connects the `log` crate to the `Logger` singleton
struct LogGlue {
    max_level: LevelFilter,
}

impl LogGlue {
    pub fn new(max_level: LevelFilter) -> Self {
        Self { max_level }
    }

    fn log_external(&self, record: &log::Record) {
        if LOGGER
            .read()
            .max_level_3rd_party
            .as_ref()
            .map(|max_level| &record.level() > max_level)
            .unwrap_or(true)
        {
            return;
        }

        if let Some(whitelist) = LOGGER.read().whitelist.as_ref() {
            let file_name = record.file();
            let any_allowed = whitelist
                .iter()
                .any(|x| file_name.as_ref().map(|y| y.contains(x)).unwrap_or(false));
            if !any_allowed {
                return;
            }
        }

        let msg = record.args();
        LOGGER.write().log(record.level(), &msg.to_string());
    }
}

impl crate::log::Log for LogGlue {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= self.max_level
    }

    fn log(&self, record: &log::Record) {
        // special path for other libraries
        if record.file().map(|x| x.contains(".cargo")).unwrap_or(true) {
            return self.log_external(record);
        }

        if self.enabled(record.metadata()) {
            let msg = record.args();
            LOGGER.write().log(record.level(), &msg.to_string());
        }
    }

    fn flush(&self) {}
}

impl Logger {
    fn load() -> Self {
        let logger_path = STATIC_ARGS.logger_path.clone();
        Self {
            file_tx: None,
            file_thread: None,
            write_to_stdout: false,
            log_file: logger_path,
            subscribers: vec![],
            log_entries: VecDeque::new(),
            max_logs: 128,
            max_level_3rd_party: None,
            whitelist: None,
        }
    }

    fn subscribe(&mut self) -> mpsc::UnboundedReceiver<Log> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.subscribers.push(tx);
        rx
    }
}

fn log_thread(mut file: std::fs::File, rx: std::sync::mpsc::Receiver<Log>) {
    while let Ok(log) = rx.recv() {
        if let Err(error) = writeln!(file, "{log}") {
            eprintln!("Couldn't write to debug.log file. {error}");
        }
    }

    let _ = file.sync_all();
}

impl Logger {
    fn log(&mut self, level: Level, message: &str) {
        let new_log = Log {
            level,
            message: message.to_string(),
            datetime: Local::now(),
            colorized: false,
        };

        if let Some(sender) = self.file_tx.as_mut() {
            let _ = sender.send(new_log.clone());
        } else if level != Level::Trace {
            // keeping a running log of entries probably won't help identify a crash if the log is filled with trace logs.
            self.log_entries.push_back(new_log.clone());

            if self.log_entries.len() > self.max_logs {
                self.log_entries.pop_front();
            }
        }

        if self.write_to_stdout {
            println!("{}", new_log.colorize())
        }

        // if a subscriber closes a channel, send() will fail. remove from subscribers
        self.subscribers.retain(|x| x.send(new_log.clone()).is_ok());
    }

    fn get_save_to_file(&self) -> bool {
        self.file_tx.is_some()
    }

    fn set_save_to_file(&mut self, enabled: bool) {
        if !enabled {
            let sender = self.file_tx.take();
            //ensure that the receiver in the thread errors to allow the thread to close
            drop(sender);
            let r = self.file_thread.take().map(|x| x.join());
            if let Some(Err(e)) = r {
                eprintln!("error joining file thread: {e:?}");
            }
            return;
        }

        // already saving to file. no need to make a new thread.
        if self.file_tx.is_some() {
            return;
        }

        if let Some(path) = self.log_file.parent() {
            if !path.is_dir() {
                let _ = std::fs::create_dir_all(path);
            }
        }

        let file = OpenOptions::new()
            .append(true)
            .create(true)
            .open(&self.log_file)
            .unwrap();

        let (tx, rx) = std::sync::mpsc::sync_channel(100);
        let thread = std::thread::spawn(move || log_thread(file, rx));

        self.file_thread = Some(thread);
        self.file_tx = Some(tx);

        let sender = self.file_tx.as_mut().expect("Sender exist");

        for entry in self.log_entries.drain(..) {
            if let Err(error) = sender.send(entry) {
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

pub fn allow_other_crates(min_level: Level, whitelist: Option<&[&str]>) {
    LOGGER.write().max_level_3rd_party.replace(min_level);
    LOGGER.write().whitelist =
        whitelist.map(|x| HashSet::from_iter(x.iter().map(|y| y.to_string())));
}

pub fn set_save_to_file(b: bool) {
    LOGGER.write().set_save_to_file(b);
}

pub fn get_save_to_file() -> bool {
    LOGGER.read().get_save_to_file()
}

pub fn set_write_to_stdout(b: bool) {
    LOGGER.write().write_to_stdout = b;
}

pub fn load_debug_log() -> Vec<String> {
    //Note: We shouldnt read from the file since it may be too big or contain irrelevant information related to uplink
    //      unless we have a specific file related to uplink/dioxus logging, in which case we should read only the last few lines
    LOGGER
        .read()
        .log_entries
        .iter()
        .map(|x| x.to_string())
        .collect()
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
