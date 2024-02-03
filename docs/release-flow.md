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

The artifacts will appear under the release number you choose above 

example

<img width="1191" alt="Captura de ecrã 2024-02-03, às 00 27 34" src="https://github.com/Satellite-im/Uplink/assets/29093946/178b7768-fbba-4c68-927e-e76b9b1f9161">


# How to do the real release

- Test the release with the above steps
- Add a commit updating Cargo.toml and Cargo.lock with the release number that you wanna do
- Push that to dev
- Go to tags
- Create a new tag with that number
- Create a release with that tag, add title in this case the same number as the release and description
- Done

https://github.com/Satellite-im/Uplink/assets/29093946/748d192e-752d-43cb-9c51-7791a19b93c7
