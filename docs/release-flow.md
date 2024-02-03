# Release flow


## Testing `dev` branch release:

- Go to the [private repo](https://github.com/Satellite-im/Uplink-copy/tree/dev)
- If you want try a release with the same content as the `dev` branch, you go to the `actions` tab and select [A1 - Sync Public Repo to Private
](https://github.com/Satellite-im/Uplink-copy/actions/workflows/sync-repo.yml) workflow and click on `Run workflow` and then again on `Run workflow` green button


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

## Add assets to Windows Installer

Uplink is installed on Windows through a Windows Installer (MSI) created with Wix Toolset. When you are adding an asset file (images, extensions, themes, etc.), this file will need to be added to the [wix configuration file](../ui/wix/main.wxs), in order to include the same file as part of the assets file copied during the installation process performed when execution the Windows Installer.

1. First, you need to create an element with component tag including the following data:
- Id: Any value that will be used to identify the file when creating the ComponentRef element
- Guid: A guid value that will be a unique identifier for the file. You can autogenerate one using a guid generator, for example [GuidGen](https://www.guidgen.com/)

2. Inside the Component tag element, you will have to add a file tag with the following properties:
- Id: Any value that will be used to identify the file
- Name: Any name that will be used to identify the file
- DiskId: Assign the value "1"
- KeyPath: Assign the value "yes"
- Source: Pass the relative path to the file. In the example provided below, the file location provided is for [AU Flag](../ui/extra/images/flags/AU-flag.png)

Example:
```
<Component Id="cmpAUflag.png" Guid="1A45E907-FC60-4195-BE6B-5BCEAB44BF74">
    <File Id="AUflag.png" Name="AU-flag.png" DiskId="1" KeyPath="yes" Source="$(var.CargoTargetDir)\..\ui\extra\images\flags\AU-flag.png" />
</Component>
```

3. Later, inside the feature tag element, there are child elements with tag = "ComponentRef". You will need to add one "ComponentRef" element with the following property:

- Id: Same Id assigned to Component Id

```
<ComponentRef Id="cmpAUflag.png" />
```

This is a process that needs to be done in order to include assets in releases versions for Windows. For MacOS, all assets are automatically copied when running ```make dmg```, and for Linux, all assets are added when running the bash script to create Linux releases: [Linux Installer Script](../build_linux_installer.sh)