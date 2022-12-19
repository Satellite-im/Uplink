# Uplink Checklist

This document provides a checklist top-to-bottom of every step you should be able to physically do within the app. If you are commiting a big change, or want to be certain the application meets all requirements before publishing a release, you should go through this checklist.




## Functionality Checklist

- [ ] Registration
    - [ ] Username
        - [ ] Limits username to a maximum of 32 characters.
        - [ ] Requires a username to be a minimum of 4 characters.
    - [ ] Profile Picture
        - [ ] User can upload a profile picture.
        - [ ] User cannot upload invalid formats as a profile picture.
        - [ ] User can change their profile picture.
        - [ ] Preview of how the profile picture should look appears for user.
    - [ ] User cannot proceed without first entering required account information.
- [ ] Chat
    - [ ] Friends
        - [ ] Add
            - [ ] There should be an input field for us to paste a did key or user#short_id
            - [ ] The input should display an error when an invalid value is pasted into the input.
            - [ ] An error should be displayed in a toast message when something goes wrong. Do not use the input error for errors related to outside events like Warp. 


## Visual & UX Checklist

- [ ] Registration
    - [ ] Username
        - [ ] Displays an error message to the user if they have a username that exceeds 32 characters.
        - [ ] Displays an error message to the user if they have a username that is under 4 characters.
        - [ ] Displays some indication of success when the user enters a valid username.
    - [ ] Profile Picture
        - [ ] Profile picture chooser should closely resemble the shape and appearance of how the profile will be displayed in app.
        - [ ] Profile picture chooser should be responsive to fit multiple display sizes.
        - [ ] Profile picture should include some clear indication to the user that they can interact with it to add a profile picture.
    - [ ] CTA Button
        - [ ] The register button should use a reusable component and only appear clickable when all of the required information is submitted and there are no errors on the page.        