# Uplink Checklist

This document provides a checklist top-to-bottom of every step you should be able to do within the app physically. If you are committing a significant change or want to be sure the application meets all requirements before publishing a release, you should go through this checklist.

# Uplink Testing

The following is a step-by-step list you should follow to ensure functionality when physically or automatically testing Uplink.

Please keep in mind when testing that sometimes things can "work," i.e., meet the guidelines of a requirement but cause undesired visual effects or jarring movements, delay, and disposition of the cursor. We want the application to feel refined; in most cases, when the UI looks ugly, we should go back to the drawing board on some features because modern machines are fast enough not to have these bugs. Indications of jumping UI's or the mouse cursor jumping around when editing text with postprocessing like real-time markdown effects means the way we're doing that processing could be faster or tidier, not that it's so advanced that a computer or browser can handle it. Remember, we're building for everyone here, and the average user wants something easy on the eyes as much as it is functional. Even if your physical tests "passed" they still look nice and don't make sacrifices elsewhere.

Tests marked with `[NYI] Not Yet Implemented` need not pass.

## **Functionality Checklist**

### **Registration / Login**

**PIN Creation**

- [ ] Limits PIN to a maximum of 6 characters.
- [ ] Requires PIN to be a minimum of 4 characters.
- [ ] Shows error if the user tries to enter with less than 4 characters.
- [ ] Shows an error if the user enters an incorrect PIN.

**Username**

- [ ] Limits username to a maximum of 32 characters.
- [ ] Requires a username to be a minimum of 4 characters.
- [ ] Shows error if the user enters a username with less than 4 characters.
- [ ] Shows error if User enters username with more than 32 characters.

**Profile Picture**

- [ ] User can upload a profile picture.
- [ ] User cannot upload invalid formats as a profile picture.
- [ ] User can change their profile picture.
- [ ] Preview of how the profile picture should look appears for the user.
- [ ] User can only proceed with entering the required account information.

### **Friends**

**Adding friends**

- [ ] Clicking Copy Code should copy the user's did key
- [ ] There should be an input field for us to paste a did key or user#short_id.
- [ ] The input should display an error when an invalid value is pasted into the input.
- [ ] A toast message should display an error when something goes wrong. Do not use the input error for errors related to outside events like Warp.
- [ ] The input field should indicate when the user has less than 4 characters.
- [ ] The indicator should change colors when users type more than 4 characters.

**Blocking friends**

- [ ] Clicking Blocked displays all accounts that User has blocked.

### **Files**

- [ ] User should be able to Drag+Drop 1 or more files.
- [ ] User should be able to Drag+Drop Files into a specific Folder.
- [ ] User should not be able to have 2 Folders with the same name inside the same folder.
- [ ] User should not be able to upload 2 files with the same name inside the same folder.
- [ ] File Directory should be clickable.
- [ ] User should be able to rename Files.
- [ ] User should be able to rename Folders.
- [ ] User should be able to download Files by right-clicking that file.
- [ ] User can take a file already uploaded and drag it into the folder.

### Calling & Video

- [ ] Clicking *Settings* button should take User to the *Settings* Page.
- [ ] User should be able to click+drag Pop-out player anywhere on the screen.
- [ ] When getting a call, a ringtone is heard.

## **Visual & UX Checklist**

### **Registration / Login**

**PIN Creation**

- [ ] Displays an error message when the PIN is not at least 4 characters long.
- [ ] Anything already typed should change from blue to red when an error message appears.
- [ ] Display some indication of success when the User enters a valid PIN.

**Username**

- [ ] Displays an error message to the User if they have a username that exceeds 32 characters.
- [ ] Displays an error message to the User if they have a username under 4 characters.
- [ ] Displays some indication of success when the User enters a valid username.

**Profile Picture**

- [ ] Profile picture chooser should closely resemble the shape and appearance of how the profile will be displayed in-app.
- [ ] Profile picture chooser should be responsive to multiple display sizes.
- [ ] Profile picture should indicate to the user that they can interact with it to add a profile picture.

 **CTA Button**

- [ ] The register button should use a reusable component and only appear clickable when all of the required information is submitted, and there are no errors on the page.

### **Chat Page**

**Landing page for New Accounts**

- [ ] "No active chats, wanna make one?" with an option underneath to start one.
- [ ] Page indicator in the sidebar should indicate User they are on the Chat page.

**Current Chat**

- [ ] Any message you send yourself should appear within a colored message bubble.
- [ ] Any message received should appear with a grey message bubble.
- [ ] The chat you are in should be highlighted in the sidebar.
- [ ] User Profile Pic should appear next to their message and be up to date.
- [ ] Username should appear above each message or bulk of messages sent or received.
- [ ] Clicking the *Heart* should add the friend to your *Favorites*.
- [ ] Current chat should be displayed at the top of the list in the sidebar.
- [ ] Timestamps should update in chat and sidebar. (now, then goes by minutes-hours-days)
- [ ] Clicking *Phone* icon should open call modal.
- [ ] Chat should close if the User blocks the friend they are in the current chat with.
- [ ] Typing indicator appears when user is typing.
- [ ] Usernames are both displayed in the call modal.
- [ ] Friends Username/Profile Pic/Status should be displayed at the top of the active chat.
- [ ] Tooltip should appear for *Call* button.
- [ ] Tooltip should appear for *Video* button.
- [ ] Tooltip should appear for *Upload* button.
- [ ] Tooltip should appear for *Favorites* button.
- [ ] User can reply to a message by right+clicking and selecting in the context menu.
- [ ] User can react to a message by right+clicking and selecting in the context menu.
- [ ] User should enter chat at the bottom with the most recent messages.
- [ ] Sending a DID will generate a quick profile card within the chat.
- [ ] When on a call, call controls should display in the sidebar.
- [ ] User should not have any conversations limit in the chat list.
- [ ] Sending specific ASCII emojis such as : joy : will convert into the emoji.
- [ ] When user scrolls we fetch messages on demand and we show a scroll to bottom option to scroll all to the bottom.
- [ ] The scroll to bottom option should not display if there are no messages after that.
- [ ] Groups should not have a online indicator.
- [ ] Download icon when sending a image should only appear when hovering the image.
- [ ] User is able to drag and drop files and image within the chat.
- [ ] When a chat has unreads, a unread indicator is displayed in the chat icon in the sidebar and the chat itself in the chat list.
- [ ] User is able to scroll, change chat, go again to the previous chat and scroll will appear in the same scroll position.
- [ ] User can send max 8 files per message.
- [ ] User is able to paste images or files from the clipboard.

## Supported markdown

Italics
- [ ]  `*x*`
- [ ]  `_x_`

Bold
- [ ]  `**x**`
- [ ]  `__x__`

Strikethrough
- [ ] `~~x~~`

Code
- [ ]  `int a = 0;`
- [ ] ```int a = 0;```
- [ ]  multiline code
     ```
     int a = 0;
     int b = 0;
     ```
- [ ]  multiline code with a language
     ```rust
     let a = 0;
     let b = 0;
     ```
Headings
- [ ]  `# heading title`
- [ ]  `## heading title`
- [ ]  `##### heading title`

### Calling & Video

- [ ] Call modal opens when the user starts a call.
- [ ] Tooltip should appear for *End Call* button.
- [ ] Tooltip should appear for *Enable Camera* button.
- [ ] Tooltip should appear for *ScreenShare* button.
- [ ] Call/Video sounds should mute when the user clicks *Silence*.
- [ ] User should be navigated to Settings when they click the *Settings* button.
- [ ] Call should expand when User enters *Fullscreen*.
- [ ] Pop-Out player should appear when the user enables it.
- [ ] While Pop-out is enabled original call should display *Media Detached*.
- [ ] While on call, silence option will display and when used will cut off the audio from the other user.
- [ ] User volum option should only be displayed if user activated the experimental settings.
- [ ] While on a call, recording option appears and if user clicks on it, saves a file on recordings folder within the .uplink folder.
- [ ] There is an indicator for when a user is speaking in a call and username will be enlarged and highlighted.
- [ ] 
### **Friends**

**Friends List**

- [ ] Friends are ordered alphabetically.
- [ ] Profile picture should be next to the username if a friend has one.
- [ ] Profile Picture should update if a friend changes it.
- [ ] Online/Offline status should update when friends log in or off.
- [ ] Tooltip should appear when hovering the cursor over *Unfriend*.
- [ ] Tooltip should appear when hovering the cursor over *Block*.
- [ ] Tooltip should appear when hovering the cursor over *All Friends*.
- [ ] Tooltip should appear when hovering the cursor over *Pending*.
- [ ] Tooltip should appear when hovering the cursor over *Blocked*.
- [ ] Tooltip should appear when hovering the cursor over *Add*.
- [ ] Tooltip should appear when hovering the cursor over *Chat*.
- [ ] Clicking *Chat* should navigate the User to active chat with that friend.
- [ ] Friend Status should appear underneath the username.
- [ ] Clicking *Unfriend* should remove that person from your friend's list.
- [ ] Scrollbar should appear when User scrolls through the friend's list.
- [ ] User#short_id should appear after the friend's username.
- [ ] Right+Clicking on a friend should bring up the context menu.
- [ ] Friend should be added to Favorites when the User adds them with the context menu.
- [ ] When the User clicks *Chat* in the context menu, they should be navigated to active chat with that friend.
- [ ] When the User starts a call with the context menu, they should be navigated to an active call with that friend.
- [ ] User should be able to remove a friend using the context menu.
- [ ] User should also be able to block a friend by using the context menu.
- [ ] Green indicator should appear when the User pastes a correct did key in the Add Friend input field.
- [ ] Online status / Device indicator should appear next to the friend's profile pic. (This should appear anywhere a friends profile pic is throughout the entire app)

### Adding Friends

- [ ] Search Bar should display *Username#0000* when user is not clicked into it.
- [ ] Error should appear when User has less than 4 chars typed.
- [ ] Search Input should display a green indicator when the User types more than 4 chars.
- [ ] request should appear under *Pending* after sending it.
- [ ] If the User cancels the request, the request should no longer appear in *Pending*.
- [ ] Error should appear if User sends 2nd friend request to the same person.
- [ ] Error should appear when the User tries to add themselves.

**Incoming Request**

- [ ] Incoming Friend Request should have an *Deny* or *Accept* next it.
- [ ] Profile Picture should appear with username next to it.
- [ ] Incoming requests should be ordered by *Most Relevant*.
- [ ] Notification counter should display the correct amount of requests on *Pending*.
- [ ] Notification counter should display the correct amount of requests on the *Friends Page Button*
- [ ] After accepting a friend request, the pending request should clear, and they should be added to the All Friends list.

### Files

- [ ] + Icon should open the Upload File Modal.
- [ ] Preview should be shown for Uploaded Files.
- [ ] A folder should highlight when the User is drag+dropping a file into it.
- [ ] Folder should also be highlighted when the User hovers the cursor.
- [ ] Upload % should show when the User is uploading Files
- [ ] Clicking the *Home* button in Directory should take you to the Files Home page.
- [ ] When the User clicks, the New Folder typing indicator should appear, and the User can start typing without clicking into the textbox first.
- [ ] Right-clicking folder should open Context Menu with the option to rename or delete.
- [ ] Scrollbar should appear when any Files are rendered off-screen.
- [ ] Files Directory should show updated Folders name if the folder has been renamed.
- [ ] File Uploading should stop when User hits *Cancel*.
- [ ] Size of the file should show underneath the preview.
- [ ] Amount of items/size of uploaded files should show underneath the folder.
- [ ] Directory should be highlighted when the User hovers the cursor.
- [ ] Upload modal should show the file's path when the User is drag+dropping a file into the Modal.
- [ ] Clicking the X in the right corner of Upload Modal should close said Modal.
- [ ] Progress Bar should show the actual amount of Files uploaded.
- [ ] Free Space should appear at the top of the Files Page.
- [ ] Total Space should appear at the top of the Files Page.
- [ ] Going to files and right-click, share should not appear if user has no chats.
- [ ] User is able to send a file from within files section in the app and from the computer to various chats.
- [ ] User is able to drag and drop files within files section.

### Settings

**Profile Page**

- [ ] *Change Avatar* should appear when the user hovers the cursor over Profile Pic.
- [ ] *Change Banner* should appear when the user hovers the cursor over the Banner area.
- [ ] Clicking the Banner should open Users local files browser.
- [ ] Clicking the Profile Picture should open Users local files browser.
- [ ] Clicking *Edit* should display the username and status input fields.
- [ ] Error message should appear when the User tries to type a username or status message longer than 32 characters.
- [ ] Error message should appear when the User attempts to save a username or status with less than 4 characters.
- [ ] User can upload and crop a banner image.
- [ ] User can upload and crop a profile image.
- [ ] User can move the image within the crop.

**General**

- [ ] User should land in the General tab when entering Settings.
- [ ] Clicking Theme should open the Themes Dropdown.
- [ ] Clicking *Clear Themes* should set the theme back to default.
- [ ] UI should change accordingly when the User sets a new theme.
- [ ] User should be able to change the language by selecting from the Language Dropdown menu.
- [ ] When you go to settings and go to other part of the app, going again to settings should be on the same section where you were previously.
- [ ] Window size is remembered and reloaded on app start

**Privacy**

- [ ] Clicking *Backup Phrase* in the *Privacy* tab should backup Users account phrase.

**Audio**

- [ ] User should be able to toggle *Call Timer* on and off.

**Files**

- [ ] User should be able to toggle *Local Sync* on and off.
- [ ] Clicking *Open Sync Folder* should open the folder to which User's local files are synced.

**Extensions**

- [ ] User should be able to toggle Placeholder on and off.
- [ ] Clicking "Open Extensions Folder" should open the Users extension folder.

**Developer**

- [ ] Clicking *Open Codebase* should take the User to Github.
- [ ] Clicking *Open Cache* should open the .Cache folder within Uplink.
- [ ] Clicking *Compress* should compress the Users .Cache into a zip file.
- [ ] User can clear .Cache by clicking *Clear Cache*
- [ ] Chat Sidebar should not appear when the User is in Settings.
- [ ] Clicking *Open debug logger* should open the debugging logger.
- [ ] Logs should save in a file when the User toggles on *Save Logs In A File*
- [ ] Dev tools should appear when toggled on in the top right corner.
- [ ] Clicking the Mobile dev tool should resize the window to replicate a Mobile device.
- [ ] Clicking the Tablet dev tool should resize the window to replicate a Tablet.
- [ ] Clicking the Desktop dev tool should resize the window to the original Desktop view.
- [ ] Clicking the fullscreen dev tool should resize the window to take up the entire screen.
- [ ] Only show developer settings after clicking version number 10 times

**Licenses**
- [ ] It displays the licenses we have and a button that opens the license as well.

### Sidebar

**Basics**

- [ ] Sidebar should persist through Chat, Files, and Friends pages.
- [ ] The user's active chats should appear in the sidebar.
- [ ] Sidebar should be hidden when the User enters Settings.
- [ ] Sidebar should display User's favorite chats (If the User has any).
- [ ] Users should be navigated to chat when they click a friend in their favorites.
- [ ] Sidebar should display all User's chats with the most relevant at the top.
- [ ] Notification bubble should appear on the Chat icon if the User has any.
- [ ] Notification bubble should appear on the Friends icon if the User has any.
- [ ] User can clear unread messages by right+clicking to open the context menu.
- [ ] User can call a friend by right+clicking to open the context menu.
- [ ] User can hide chat by right+clicking to open the context menu.
- [ ] Tooltip should appear when hovering the cursor over *Chat Page* icon.
- [ ] Tooltip should appear when hovering the cursor over *Files Page* icon.
- [ ] Tooltip should appear when hovering the cursor over *Friends Page* icon.
- [ ] Tooltip should appear when hovering the cursor over *Settings Page* icon.
- [ ] User can search within Settings by clicking on Settings Search Bar.
- [ ] Call controls should appear in Sidebar when User enters a call.
- [ ] Clear unreads should not appear when there are no unreads.
- [ ] Sidebar should not display when there are no favorites or chats or anything unless is dev features are activated.
