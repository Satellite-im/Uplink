# Building a release for Mac

## Prerequisites

> Note: This guide assumes you've already set up an [Apple developer](https://developer.apple.com/account) Account.

Firstly you'll want to open **Keychain Access** and in the menu bar select Keychain Access > Certificate Assistant > Request a Certificate from Certificate Authority.

Enter your email associated with your **Apple Developer Account** and select the save to disk option leaving the `CA Email Address` blank.

Next go to your [Apple developer](https://developer.apple.com/account) account page and select **Certificates, Identifiers & Profiles**.

Next, click the "+" button next to `Certificates` and upload your signing request.

Lastly, add the certificate to your keychain by downloading it and double-clicking it. You'll want to then find it in the keychain it will look something like `Developer ID Application: Matt Wisniewski (HJF8FSD0WEFSD)`. But with your information.

Take a copy of the string of numbers and letters between the parentheses. Paste that into the `SIGNATURE =` field in the Makefile at the root of the directory.

You're all ready, you can run `make` to view a list of available make scripts.
