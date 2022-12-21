# Uplink Checklist

This document provides a checklist top-to-bottom of every step you should be able to physically do within the app. If you are commiting a big change, or want to be certain the application meets all requirements before publishing a release, you should go through this checklist.




## **Functionality Checklist**

### **Registration / Login**
**PIN Creation**
- [ ] Limits PIN to a maximun of 6 characters.
- [ ] Reqiures PIN to be a minimum of 4 characters.
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
- [ ] Any message you sent yourself should appear with in a colored message bubble.
- [ ] Any message received should appear with a grey message bubble.
- [ ] The chat that you are in should be highlighted in the Sidebar. 
- [ ] User Profile Pic should appear next to their Message and be up to date.
- [ ] Clicking the *Heart* should add the friend to your *Favorites*.
- [ ] Currect chat should be displayed at top of the list in Sidebar.
   
### **Friends**
**Friends List** 
- [ ] Friends are ordered alphabetically.
- [ ] Profile picture should be present next to Username if friend has one.
- [ ] Profile Picture should update if a friend changes it.
- [ ] Online/Offline status should update when friends log in or off.
- [ ] Tooltip should appear when hovering curser over *Messages*.
- [ ] Tooltip should appear when hovering curser over *More Options*.

**Incoming Request**
- [ ] Incoming Friend Request should have an *X* or *Checkmark* next it.
- [ ] Profile Picture should appear with Username next to it.
- [ ] Any incoming friend request should appear underneat *Copy Code*.
- [ ] Incoming request should be ordered by *Most Relevant*. 
- [ ] Notication counter should display correct amount of requests on *Pending*.
- [ ] Notication counter should display correct amount of requests on *Friends Page Button*
