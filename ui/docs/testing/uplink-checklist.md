# Uplink Checklist

This document provides a checklist top-to-bottom of every step you should be able to physically do within the app. If you are commiting a big change, or want to be certain the application meets all requirements before publishing a release, you should go through this checklist.




## **Functionality Checklist**

### **Registration / Login**
**PIN Creation**
- [ ] Limits PIN to a maximun of 6 characters.
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
        
**Blocking friends**
- [ ] Clicking Blocked displays all accounts that User has blocked.

**Files**
- [ ] User should be able to Drag+Drop 1 or more files.
- [ ] User should be able to Drag+Drop Files into a specific Folder.
- [ ] User should not be able to have 2 Folders with the same name.
- [ ] User should not be able to upload 2 files with the same name.
- [ ] File Directory should be clickable.
- [ ] User should be able to rename Files.
- [ ] User should be able to rename Folders. 
- [ ] User should be able to download Files by right clicking that said file.
- [ ] User can take file already uploaded and drag it into folder.

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
- [ ] Clicking the *Heart* should add the friend to your *Favorites*.
- [ ] Currect chat should be displayed at top of the list in Sidebar.
- [ ] Timestamps should update in chat, and sidebar. (now, then goes by minutes-hours-days)
- [ ] Clicking *Phone* icon should open call modal.
- [ ] Chat should close if User blocks friend they are in current chat with. 
- [ ] Typing indicator appears (if user has that extention toggled on).
- [ ] Usernames are both displayed in call modal. 
   
### **Friends**
**Friends List** 
- [ ] Friends are ordered alphabetically.
- [ ] Profile picture should be present next to Username if friend has one.
- [ ] Profile Picture should update if a friend changes it.
- [ ] Online/Offline status should update when friends log in or off.
- [ ] Tooltip should appear when hovering cursor over *Messages*.
- [ ] Tooltip should appear when hovering cursor over *More Options*.

**Incoming Request**
- [ ] Incoming Friend Request should have an *X* or *Checkmark* next it.
- [ ] Profile Picture should appear with Username next to it.
- [ ] Incoming request should be ordered by *Most Relevant*. 
- [ ] Notification counter should display correct amount of requests on *Pending*.
- [ ] Notification counter should display correct amount of requests on *Friends Page Button*

**Files** 
- [ ] + Icon should open the Upload File Modal.
- [ ] Preview should be shown for Uploaded Files. 
- [ ] Folder should highlight when User is drag+dropping a file into it.
- [ ] Folder should also be highlighted when User hovers cursor over it.
- [ ] Upload % should show when User is uploading Files 
- [ ] Clicking the _Home_ buttin in Directory should take you to Files Home page.
- [ ] When User clicks New Folder typing indicator should appear and User can start typing without clicking into textbox first. 
- [ ] Right clicking folder should open Context Menu with option to rename or delete.
- [ ] Scrollbar should appear when any Files are rendered off screen.
- [ ] Files Directory should show updated Folders name if Folder has been renamed.
- [ ] File Uploading should stop as soon as User hits _Cancel_.
- [ ] Size of file should show underneath preview. 
- [ ] Amount of items/size of uploaded files should show underneath the Folder. 
- [ ] Directory should be highlighted when User hovers cursor over it.
- [ ] Upload modal should show path of saif file when User is drag+dropping a file into Modal. 
- [ ] Clicking the X in right corner of Upload Modal should close said Modal. 
- [ ] Progress Bar should show actual amount of Files uploaded.
