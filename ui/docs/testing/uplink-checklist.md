# Uplink Checklist

This document provides a checklist top-to-bottom of every step you should be able to physically do within the app. If you are committing a big change, or want to be certain the application meets all requirements before publishing a release, you should go through this checklist.

# Uplink Testing

The following is a step-by-step list you should follow to ensure functionality when physically or automatically testing Uplink.

Please keep in mind when testing that sometimes things can "work" i.e. meet the guidelines of a requirement but cause undesired visual effects or jarring movements, delay, and disposition of the cursor. We want the application to feel refined, in most cases when the UI looks ugly, it means we should go back to the drawing board on some feature because modern machines are fast enough to not have these bugs. Indications of jumping UI's or the mouse cursor jumping around when editing text with postprocessing like real-time markdown effects means the way we're doing that processing is slow, or un-tidy, not that it's so advanced that a computer or browser can't handle it. Remember we're building for everyone here and the average user wants something easy on the eyes as much as it is functional. Check that even if your physical tests "passed" they also still look nice and don't make sacrifices elsewhere.

Tests marked with `[NYI] Not Yet Implemented` do not need to pass yet.

## **Functionality Checklist**

### **Registration / Login**

**PIN Creation**

- [ ] Limits PIN to a maximum of 6 characters.
- [ ] Requires PIN to be a minimum of 4 characters.
- [ ] Shows error if User tries to enter with less than 4 characters.
- [ ] Shows error if User enters incorrect PIN.

**Username**

- [ ] Limits username to a maximum of 32 characters.
- [ ] Requires a username to be a minimum of 4 characters.
- [ ] Shows error if User enters Username with less than 4 characters.
- [ ] Shows error if User enters Username that is more than 32 characters.

**Profile Picture**

- [ ] User can upload a profile picture.
- [ ] User cannot upload invalid formats as a profile picture.
- [ ] User can change their profile picture.
- [ ] Preview of how the profile picture should look appears for user.
- [ ] User cannot proceed without first entering required account information.

### **Friends**

**Adding friends**

- [ ] Clicking Copy Code should copy User's did key
- [ ] There should be an input field for us to paste a did key or user#short_id.
- [ ] The input should display an error when an invalid value is pasted into the input.
- [ ] An error should be displayed in a toast message when something goes wrong. Do not use the input error for errors related to outside events like Warp.
- [ ] The input field should have an indicator when User has less than 4 characters.
- [ ] The indicator should change colors when User types more than 4 characters.

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
- [ ] User should be able to download Files by right clicking that said file.
- [ ] User can take file already uploaded and drag it into folder.

### Calling & Video

- [ ] Clicking *Settings* button should take User to the *Settings* Page.
- [ ] User should be able to click+drag Pop-out player anywhere on screen.

## **Visual & UX Checklist**

### **Registration / Login**

**PIN Creation**

- [ ] Displays an error message when the PIN is not at least 4 characters long.
- [ ] Anything already typed should change from blue to red when error message appears.
- [ ] Display some indication of success when the user enters a valid PIN.

**Username**

- [ ] Displays an error message to the user if they have a username that exceeds 32 characters.
- [ ] Displays an error message to the user if they have a username that is under 4 characters.
- [ ] Displays some indication of success when the user enters a valid username.

**Profile Picture**

- [ ] Profile picture chooser should closely resemble the shape and appearance of how the profile will be displayed in app.
- [ ] Profile picture chooser should be responsive to fit multiple display sizes.
- [ ] Profile picture should include some clear indication to the user that they can interact with it to add a profile picture.

 **CTA Button**

- [ ] The register button should use a reusable component and only appear clickable when all of the required information is submitted and there are no errors on the page.

### **Chat Page**

**Landing page for New Accounts**

- [ ] "No active chats, wanna make one?" with option underneath to start one.
- [ ] Page indicator in Sidebar should indicate User they are on the Chat page.

**Current Chat**

- [ ] Any message you sent yourself should appear within a colored message bubble.
- [ ] Any message received should appear with a grey message bubble.
- [ ] The chat that you are in should be highlighted in the Sidebar.
- [ ] User Profile Pic should appear next to their Message and be up to date.
- [ ] Username should appear above each message or bulk of messages sent or received.
- [ ] Clicking the *Heart* should add the friend to your *Favorites*.
- [ ] Currect chat should be displayed at top of the list in Sidebar.
- [ ] Timestamps should update in chat, and sidebar. (now, then goes by minutes-hours-days)
- [ ] Clicking *Phone* icon should open call modal.
- [ ] Chat should close if User blocks friend they are in current chat with.
- [ ] Typing indicator appears (if user has that extension toggled on).
- [ ] Usernames are both displayed in call modal.
- [ ] Friends Username/Profile Pic/Status should be displayed at top of active chat.
- [ ] Tooltip should appear for *Call* button.
- [ ] Tooltip should appear for *Video* button.
- [ ] Tooltip should appear for *Upload* button.
- [ ] Tooltip should appear for *Favorites* button.
- [ ] User can reply to a message by right+clicking and selecting in context menu.
- [ ] User can react to a message by right+clicking and selecting in context menu.
- [ ] User should enter chat at the bottom with most recent messages.

### Calling & Video

- [ ] Call modal opens when User starts a call.
- [ ] Tooltip should appear for *End Call* button.
- [ ] Tooltip should appear for *Enable Camera* button.
- [ ] Tooltip should appear for *ScreenShare* button.
- [ ] Call/Video sounds should mute when User clicks *Silence*.
- [ ] User should be navigated to Settings when they click *Settings* button.
- [ ] Call should expand when User enters *Fullscreen*.
- [ ] Pop-Out player should appear when User enables it.
- [ ] While Pop-out is enabled original call should display *Media Detached*.

### **Friends**

**Friends List**

- [ ] Friends are ordered alphabetically.
- [ ] Profile picture should be present next to Username if friend has one.
- [ ] Profile Picture should update if a friend changes it.
- [ ] Online/Offline status should update when friends log in or off.
- [ ] Tooltip should appear when hovering cursor over *Unfriend*.
- [ ] Tooltip should appear when hovering cursor over *Block*.
- [ ] Tooltip should appear when hovering cursor over *All Friends*.
- [ ] Tooltip should appear when hovering cursor over *Pending*.
- [ ] Tooltip should appear when hovering cursor over *Blocked*.
- [ ] Tooltip should appear when hovering cursor over *Add*.
- [ ] Tooltip should appear when hovering cursor over *Chat*.
- [ ] Clicking *Chat* should navigate User to active chat with that friend.
- [ ] Friend Status should appear underneath username.
- [ ] Clicking *Unfriend* should remove that person from your friends list.
- [ ] Scrollbar should appear when user scrolls through friends list.
- [ ] User#short_id should appear after the friends username.
- [ ] Right+Clicking on a friend should bring up the context menu.
- [ ] Friend should be added to Favorites when User adds them with the context menu.
- [ ] When User clicks *Chat* in the context menu, they should be navigated to active chat with that friend.
- [ ] When User starts a call with the context menu they should be navigated to active call with that friend.
- [ ] User should be able to remove a friend by using the context menu.
- [ ] User should also be able to block a friend by using the context menu.
- [ ] Green indicator should appear when User paste a correct did key in the Add Friend input field.
- [ ] Online status / Device indicator should appear next to friends profile pic. (This should appear anywhere a friends profile pic is throughout entire app)

### Adding Friends

- [ ] Search Bar should display *Username#0000* when user is not clicked into it.
- [ ] Error should appear when User has less than 4 chars typed.
- [ ] Search Input should display green indicator when User types more than 4 chars.
- [ ] Request should appear under *Pending* after it is sent.
- [ ] If user cancels request, the request should no longer appear in *Pending*.
- [ ] Error should appear if User sends 2nd friend request to the same person.
- [ ] Error should appear when User tries to add themselves.

**Incoming Request**

- [ ] Incoming Friend Request should have an *Deny* or *Accept* next it.
- [ ] Profile Picture should appear with Username next to it.
- [ ] Incoming request should be ordered by *Most Relevant*.
- [ ] Notification counter should display correct amount of requests on *Pending*.
- [ ] Notification counter should display correct amount of requests on *Friends Page Button*
- [ ] After accepting friend request, the pending request should clear and they should be added to the All Friends list.

### Files

- [ ] + Icon should open the Upload File Modal.
- [ ] Preview should be shown for Uploaded Files.
- [ ] Folder should highlight when User is drag+dropping a file into it.
- [ ] Folder should also be highlighted when User hovers cursor over it.
- [ ] Upload % should show when User is uploading Files
- [ ] Clicking the *Home* button in Directory should take you to Files Home page.
- [ ] When User clicks New Folder typing indicator should appear and User can start typing without clicking into textbox first.
- [ ] Right clicking folder should open Context Menu with option to rename or delete.
- [ ] Scrollbar should appear when any Files are rendered off screen.
- [ ] Files Directory should show updated Folders name if Folder has been renamed.
- [ ] File Uploading should stop as soon as User hits *Cancel*.
- [ ] Size of file should show underneath preview.
- [ ] Amount of items/size of uploaded files should show underneath the Folder.
- [ ] Directory should be highlighted when User hovers cursor over it.
- [ ] Upload modal should show path of said file when User is drag+dropping a file into Modal.
- [ ] Clicking the X in right corner of Upload Modal should close said Modal.
- [ ] Progress Bar should show actual amount of Files uploaded.
- [ ] Free Space should appear at the top of Files Page.
- [ ] Total Space should appear at the top of Files Page.

### Settings

**Profile Page**

- [ ] *Change Avatar* should appear when user hovers cursor over Profile Pic.
- [ ] *Change Banner* should appear when user hovers cursor over Banner area.
- [ ] Clicking the Banner should open Users local files browser.
- [ ] Clicking the Profile Picutre should open Users local files browser.
- [ ] Clicking *Edit* should display input fields for Username and Status.
- [ ] Error message should appear when User tries to type a username or stauts message longer than 32 characters.
- [ ] Error message should appear when user attempts to save a username or status with less than 4 characters.

**General**

- [ ] User should land in General tab when entering Settings.
- [ ] Clicking Theme should open the Themes Dropdown.
- [ ] Clicking *Clear Themes* should set the theme back to default.
- [ ] UI should change accordingly when User sets a new theme.
- [ ] User should be able to change the language by selecting from the Language Dropdown menu.
  
**Privacy**

- [ ] Clicking *Backup Phrase* in the *Privacy* tab should backup Users account phrase.

**Audio**

- [ ] User should be able to toggle *Call Timer* on and off.

**Files**

- [ ] User should be able to toggle *Local Sync* on and off.
- [ ] Clicking *Open Sync Folder* should open the folder where Users local files are synced to.

**Extensions**

- [ ] User should be able to toggle Placeholder on and off.
- [ ] Clicking "Open Extensions Folder" should open Users extension folder.

**Developer**

- [ ] Clicking *Open Codebase* should take the User to Github.
- [ ] Clicking *Open Cache* should open the .Cache folder within Uplink.
- [ ] Clicking *Compress* should compress the Users .Cache into a zip file.
- [ ] User can clear .Cache by clicking *Clear Cache*
- [ ] Chat Sidebar should not appear when User is in Settings.
- [ ] Clicking *Open debug logger* should open the debugging logger.
- [ ] Logs should save in a file when User toggles on *Save Logs In A File*
- [ ] Dev tools should appear in top right corner when toggled on.
- [ ] Clicking Mobile dev tool should resize window to replicate a Mobile device.
- [ ] Clicking Tablet dev tool should resize window to replicate a Tablet.
- [ ] Clicking Desktop dev tool sohuld resize window to original Desktop view.
- [ ] Clicking fullscreen dev tool should resize window to take up entire screen.
  
### Sidebar

**Basics**

- [ ] Sidebar should persist through Chat, Files, and Friends pages.
- [ ] Any active chats user has created should appear in Sidebar.
- [ ] Sidebar should be hidden when User enters Settings.
- [ ] Sidebar should display Users favorite chats (If user has any).
- [ ] User should be navigated to chat when they click a friend in their favorites.
- [ ] Sidebar sholud display all of Users chats with most relevant at the top.
- [ ] Notification bubble should appear on Chat icon if User has any.
- [ ] Notification bubble should appear on Friends icon if User has any.
- [ ] User can clear unread messages by right+clicking to open context menu.
- [ ] User can call a friend by right+clicking to open context menu.
- [ ] User can hide chat by right+clicking to open context menu.
- [ ] Tooltip should appear when hovering cursor over *Chat Page* icon.
- [ ] Tooltip should appear when hovering cursor over *Files Page* icon.
- [ ] Tooltip should appear when hovering cursor over *Friends Page* icon.
- [ ] Tooltip should appear when hovering cursor over *Settings Page* icon.
- [ ] User can search within Settings by clicking into Settings Search Bar.
- [ ] Call controls should appear in Sidebar when User enters a call.
