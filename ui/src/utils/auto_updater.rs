use reqwest::header;
use reqwest::Client;
use serde::Deserialize;

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

pub async fn try_upgrade() -> Result<(), Box<dyn std::error::Error>> {
    let latest_release =
        get_github_release("https://api.github.com/repos/Satellite-im/Uplink/releases/latest")
            .await?;
    if !should_upgrade(&latest_release.tag_name) {
        return Ok(());
    }

    // copy executable here
    let exe_path = std::env::current_exe()?;

    // todo: find executable in latest_release.assets

    // todo: find extra.zip in latest_release.assets

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

// assumes each release is tagged vX.Y.Z where X.Y.Z equals CARGO_PKG_VERSION
// assumes `release_version` is the most recently published release
fn should_upgrade(release_version: &str) -> bool {
    let current_version = format!("v{}", env!("CARGO_PKG_VERSION"));
    current_version == release_version
}

#[cfg(test)]
mod test {

    use super::*;

    #[tokio::test]
    async fn test_get_latest_release() -> Result<(), Box<dyn std::error::Error>> {
        let response =
            get_github_release("https://api.github.com/repos/sdwoodbury/Uplink/releases/latest")
                .await?;
        assert_eq!(response.tag_name, String::from("v0.2.8"));
        println!("assets: {:#?}", response.assets);
        Ok(())
    }
}
