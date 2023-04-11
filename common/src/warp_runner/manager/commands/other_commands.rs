use std::{
    fs::File,
    io::{Read, Seek, Write},
    path::{Path, PathBuf},
};
use walkdir::WalkDir;
use zip::{result::ZipError, write::FileOptions};

use derive_more::Display;
use futures::channel::oneshot;
use warp::{error, logging::tracing::log};
#[derive(Display)]
pub enum OtherCmd {
    #[display(fmt = "CompressFolder {{ src: {src:?}, dest: {dest:?} }} ")]
    CompressFolder {
        src: PathBuf,
        dest: PathBuf,
        rsp: oneshot::Sender<Result<(), error::Error>>,
    },
}

pub async fn handle_other_cmd(cmd: OtherCmd) {
    match cmd {
        OtherCmd::CompressFolder { src, dest, rsp } => {
            let r = compress_folder(src, dest).await;
            let _ = rsp.send(r);
        }
    }
}

async fn compress_folder(src: PathBuf, dest: PathBuf) -> Result<(), error::Error> {
    // I know that warp_runner is basically single threaded but still...put the blocking operation in a separate task and await it
    let handle = tokio::task::spawn_blocking(move || {
        let z = || -> Result<(), ZipError> {
            let file = File::create(dest).unwrap();
            let prefix = src.to_string_lossy().to_string();

            let walkdir = WalkDir::new(src);
            let it = walkdir.into_iter();

            zip_dir(
                &mut it.filter_map(|e: Result<walkdir::DirEntry, walkdir::Error>| e.ok()),
                &prefix,
                file,
                zip::CompressionMethod::Bzip2,
            )?;

            Ok(())
        };
        z()
    });
    let res = match handle.await {
        Ok(r) => r,
        Err(_) => {
            log::warn!("compress operation canceled");
            return Ok(());
        }
    };
    res.map_err(|e| warp::error::Error::OtherWithContext(e.to_string()))
}

// taken from https://github.com/zip-rs/zip/blob/master/examples/write_dir.rs
fn zip_dir<T>(
    it: &mut dyn Iterator<Item = walkdir::DirEntry>,
    prefix: &str,
    writer: T,
    method: zip::CompressionMethod,
) -> zip::result::ZipResult<()>
where
    T: Write + Seek,
{
    let mut zip = zip::ZipWriter::new(writer);
    let options = FileOptions::default()
        .compression_method(method)
        .unix_permissions(0o755)
        .large_file(true);

    let mut buffer = Vec::new();
    for entry in it {
        let path = entry.path();
        let name = path.strip_prefix(Path::new(prefix)).unwrap();

        // Write file or directory explicitly
        // Some unzip tools unzip files with directory paths correctly, some do not!
        if path.is_file() {
            log::trace!("adding file {path:?} as {name:?} ...");
            #[allow(deprecated)]
            zip.start_file_from_path(name, options)?;
            let mut f = File::open(path)?;

            f.read_to_end(&mut buffer)?;
            zip.write_all(&buffer)?;
            buffer.clear();
        } else if !name.as_os_str().is_empty() {
            // Only if not root! Avoids path spec / warning
            // and mapname conversion failed error on unzip
            log::trace!("adding dir {path:?} as {name:?} ...");
            #[allow(deprecated)]
            zip.add_directory_from_path(name, options)?;
        }
    }
    zip.finish()?;
    Result::Ok(())
}
