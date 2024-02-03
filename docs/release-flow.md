# Release flow


## Testing `dev` branch release:

- Go to the [private repo](https://github.com/Satellite-im/Uplink-copy/tree/dev)
- If you want try a release with the same content as the `dev` branch, you go to the `actions` tab and select [A1 - Sync Public Repo to Private
](https://github.com/Satellite-im/Uplink-copy/actions/workflows/sync-repo.yml) workflow and click on `Run workflow` and then again on + `Run workflow` green button


https://github.com/Satellite-im/Uplink/assets/29093946/4fb57366-71c8-4d25-a0a0-8a6cacedf689


If you wanna send a specific branch from public repo to private one, you go to the `actions` tab and select [A2 - Sync Public Repo to Private
](https://github.com/Satellite-im/Uplink-copy/actions/workflows/sync-branch.yml) workflow and click on `Run workflow` and add the branch name and click again on `Run workflow` green button 


https://github.com/Satellite-im/Uplink/assets/29093946/3662b81d-469f-4b81-a116-b9192709d187


# How to do a release with the same content as dev


https://github.com/Satellite-im/Uplink/assets/29093946/d8fd9eb5-34a7-47df-948f-856a0f2bfcff


# How to do a release with the same content as a specific branch


https://github.com/Satellite-im/Uplink/assets/29093946/97ef7baf-13a8-41ae-a2b3-cb240940989b

# How to do the real release

- Test the release with the above steps
- Add a commit updating Cargo.toml and Cargo.lock with the release number that you wanna do
- Push that to dev
- Go to tags
- Create a new tag with that number
- Create a release with that tag, add title in this case the same number as the release and description
- Done




https://github.com/Satellite-im/Uplink/assets/29093946/e50dfcbe-fffd-4834-a9d7-91cc71126540




