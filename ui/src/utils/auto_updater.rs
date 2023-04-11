use std::path::Path;
use std::path::PathBuf;

use anyhow::bail;

use common::language::get_local_text;
use futures::StreamExt;
use reqwest::header;
use reqwest::Client;

use rfd::FileDialog;
use serde::Deserialize;
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;
use warp::logging::tracing::log;

// these types exist to allow different parts of the app to share the same logic for managing software updates
pub struct SoftwareUpdateCmd(pub mpsc::UnboundedReceiver<f32>);
pub struct SoftwareDownloadCmd(pub PathBuf);

#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub enum DownloadProgress {
    Idle,
    Pending,
    Finished,
}

impl Default for DownloadProgress {
    fn default() -> Self {
        Self::Idle
    }
}
#[derive(Debug, Default)]
pub struct DownloadState {
    pub stage: DownloadProgress,
    pub destination: Option<PathBuf>,
    pub progress: f32,
}

// https://docs.github.com/en/rest/releases/releases?apiVersion=2022-11-28#get-the-latest-release
#[derive(Debug, Deserialize, Clone)]
pub struct GitHubRelease {
    pub tag_name: String,
    assets: Vec<GitHubAsset>,
}

#[derive(Debug, Deserialize, Clone)]
struct GitHubAsset {
    name: String,
    browser_download_url: String,
    size: usize,
}

pub fn get_download_dest() -> Option<PathBuf> {
    match FileDialog::new()
        .set_directory(dirs::home_dir().unwrap_or(".".into()))
        .set_title(&get_local_text("uplink.pick-download-directory"))
        .pick_folder()
    {
        Some(x) => Some(x),
        None => {
            log::debug!("update download canceled by user");
            None
        }
    }
}

pub async fn check_for_release() -> anyhow::Result<Option<GitHubRelease>> {
    let latest_release =
        get_github_release("https://api.github.com/repos/Satellite-im/Uplink/releases/latest")
            .await?;

    if versions_match(&latest_release.tag_name) {
        Ok(None)
    } else {
        Ok(Some(latest_release))
    }
}

pub async fn download_update(
    binary_dest: PathBuf,
    ch: mpsc::UnboundedSender<f32>,
) -> anyhow::Result<String> {
    let latest_release =
        get_github_release("https://api.github.com/repos/Satellite-im/Uplink/releases/latest")
            .await?;
    let find_asset = |name: &str| {
        latest_release
            .assets
            .iter()
            .find(|x| x.name.contains(name))
            .cloned()
            .ok_or(anyhow::format_err!("failed to find {name}"))
    };

    let binary_asset = if cfg!(target_os = "windows") {
        find_asset(".msi")?
    } else if cfg!(target_os = "linux") {
        find_asset(".deb")?
    } else if cfg!(target_os = "macos") {
        find_asset("Uplink-Mac-Universal.zip")?
    } else {
        bail!("unknown OS type. failed to find binary");
    };

    let total_download_size = binary_asset.size as f32;
    let client = get_client()?;
    let (tx, mut rx) = mpsc::unbounded_channel::<anyhow::Result<usize>>();
    tokio::spawn(async move {
        if let Err(e) = download_file(
            &client,
            binary_dest.join(&binary_asset.name),
            &binary_asset.browser_download_url,
            tx.clone(),
        )
        .await
        {
            let _ = tx.send(Err(e));
        }
    });

    let mut total_bytes_downloaded = 0.0_f32;
    while let Some(x) = rx.recv().await {
        match x {
            Ok(b) => {
                total_bytes_downloaded += b as f32;
                let _ = ch.send(100_f32 * total_bytes_downloaded / total_download_size);
            }
            Err(e) => return Err(e),
        }
    }

    Ok(latest_release.tag_name)
}

fn get_client() -> Result<Client, reqwest::Error> {
    let mut headers = header::HeaderMap::new();
    headers.insert(
        "User-Agent",
        header::HeaderValue::from_static(
            "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/111.0",
        ),
    );
    Client::builder().default_headers(headers).build()
}

async fn get_github_release(url: &str) -> Result<GitHubRelease, reqwest::Error> {
    let client = get_client()?;
    client.get(url).send().await?.json::<GitHubRelease>().await
}

async fn download_file<P: AsRef<Path>>(
    client: &Client,
    dest: P,
    url: &str,
    ch: mpsc::UnboundedSender<anyhow::Result<usize>>,
) -> anyhow::Result<()> {
    let mut bytes = client.get(url).send().await?.bytes_stream();
    let mut file = tokio::fs::File::create(dest).await?;

    while let Some(v) = bytes.next().await {
        let bytes = v?;
        let _ = ch.send(Ok(bytes.len()));
        file.write_all(&bytes).await?;
    }
    file.flush().await?;
    Ok(())
}

fn versions_match(release_version: &str) -> bool {
    format!("v{}", env!("CARGO_PKG_VERSION")) == release_version
        || env!("CARGO_PKG_VERSION") == release_version
}

#[cfg(test)]
mod test {

    use super::*;
    use std::error::Error;

    #[tokio::test]
    async fn test_get_latest_release() -> Result<(), Box<dyn Error>> {
        let response =
            get_github_release("https://api.github.com/repos/sdwoodbury/Uplink/releases/latest")
                .await?;

        println!("assets: {:#?}", response.assets);
        assert_eq!(response.tag_name, String::from("v0.2.8"));
        Ok(())
    }

    // #[tokio::test]
    // async fn test_download_asset() -> Result<(), Box<dyn Error>> {
    //     let dest = "/tmp/test_download";
    //     let response =
    //         get_github_release("https://api.github.com/repos/sdwoodbury/Uplink/releases/latest")
    //             .await?;
    //     let asset = response.assets.first().unwrap();
    //
    //     let client = get_client()?;
    //     println!("downloading {}", asset.name);
    //     download_file(&client, dest, &asset.browser_download_url).await?;
    //
    //     Ok(())
    // }
}
