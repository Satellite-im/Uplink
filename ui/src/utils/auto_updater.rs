use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct GitHubAsset {
    name: String,
    browser_download_url: String,
}

#[derive(Debug, Deserialize)]
struct GitHubRelease {
    tag_name: String,
    assets: Vec<GitHubAsset>,
}

#[cfg(test)]
mod test {
    use reqwest::Client;

    use super::*;
    use reqwest::header;

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

    #[tokio::test]
    async fn test_get_latest_release() -> Result<(), Box<dyn std::error::Error>> {
        let client = get_client()?;
        //https://docs.github.com/en/rest/releases/releases?apiVersion=2022-11-28#get-the-latest-release
        let response = client
            .get("https://api.github.com/repos/sdwoodbury/Uplink/releases/latest")
            .send()
            .await?
            .json::<GitHubRelease>()
            .await?;

        assert_eq!(response.tag_name, String::from("v0.2.8"));
        println!("assets: {:#?}", response.assets);
        Ok(())
    }
}
