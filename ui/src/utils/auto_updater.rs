use std::path::Path;

use anyhow::bail;
use futures::StreamExt;
use reqwest::header;
use reqwest::Client;
use serde::Deserialize;
use tokio::io::AsyncWriteExt;

use crate::utils;

// https://docs.github.com/en/rest/releases/releases?apiVersion=2022-11-28#get-the-latest-release
#[derive(Debug, Deserialize)]
struct GitHubRelease {
    tag_name: String,
    assets: Vec<GitHubAsset>,
}

#[derive(Debug, Deserialize)]
struct GitHubAsset {
    name: String,
    browser_download_url: String,
}

pub async fn try_upgrade() -> anyhow::Result<()> {
    let latest_release =
        get_github_release("https://api.github.com/repos/Satellite-im/Uplink/releases/latest")
            .await?;

    if !should_upgrade(&latest_release.tag_name) {
        return Ok(());
    }

    let find_asset = |name: &str| {
        latest_release
            .assets
            .iter()
            .find(|x| x.name == name)
            .ok_or(anyhow::format_err!("failed to find {name}"))
    };

    let binary_asset = if cfg!(target_os = "windows") {
        find_asset("uplink.exe")?
    } else if cfg!(target_os = "linux") {
        find_asset("uplink")?
    } else if cfg!(any(target_os = "macos", target_os = "ios")) {
        find_asset("uplink-mac")?
    } else {
        bail!("unknown OS type. failed to find binary");
    };

    let exe_path = std::env::current_exe()?;
    let assets_dir = utils::get_assets_dir()?;
    let extra_asset = find_asset("extra.zip")?;
    let binary_dest = assets_dir.join(&binary_asset.name);
    let extras_dest = assets_dir.join("extra.zip");

    let client = get_client()?;
    download_file(&client, binary_dest, &binary_asset.browser_download_url).await?;
    download_file(&client, extras_dest, &extra_asset.browser_download_url).await?;

    // todo: overwrite executable and copy_assets

    todo!()
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

async fn download_file<P: AsRef<Path>>(client: &Client, dest: P, url: &str) -> anyhow::Result<()> {
    let mut bytes = client.get(url).send().await?.bytes_stream();
    let mut file = tokio::fs::File::create(dest).await?;

    while let Some(v) = bytes.next().await {
        let bytes = v?;
        file.write_all(&bytes).await?;
    }
    file.flush().await?;
    Ok(())
}

// assumes each release is tagged vX.Y.Z where X.Y.Z equals CARGO_PKG_VERSION
// assumes `release_version` is the most recently published release
fn should_upgrade(release_version: &str) -> bool {
    let current_version = format!("v{}", env!("CARGO_PKG_VERSION"));
    current_version == release_version
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

    #[tokio::test]
    async fn test_download_asset() -> Result<(), Box<dyn Error>> {
        let dest = "/tmp/test_download";
        let response =
            get_github_release("https://api.github.com/repos/sdwoodbury/Uplink/releases/latest")
                .await?;
        let asset = response.assets.first().unwrap();

        let client = get_client()?;
        println!("downloading {}", asset.name);
        download_file(&client, dest, &asset.browser_download_url).await?;

        Ok(())
    }
}
