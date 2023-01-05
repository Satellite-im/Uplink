# Uplink Testing

The following is a step-by-step list you should follow to ensure functionality when physically or automatically testing Uplink.

Please keep in mind when testing that sometimes things can "work" i.e. meet the guidelines of a requirement but cause undesired visual effects or jarring movements, delay, and disposition of the cursor. We want the application to feel refined, in most cases when the UI looks ugly, it means we should go back to the drawing board on some feature because modern machines are fast enough to not have these bugs. Indications of jumping UI's or the mouse cursor jumping around when editing text with postprocessing like real-time markdown effects means the way we're doing that processing is slow, or un-tidy, not that it's so advanced that a computer or browser can't handle it. Remember we're building for everyone here and the average user wants something easy on the eyes as much as it is functional. Check that even if your physical tests "passed" they also still look nice and don't make sacrifices elsewhere.

Tests marked with `[NYI] Not Yet Implemented` do not need to pass yet.

## Compilation

1. `cargo run` should not return any errors.
2. `cargo run` should not return any warnings.

## Onboarding

1. Create Pin
    1. Should be able to enter any alphanumeric key to input a new character into the pin.
    2. Should not be able to use modifier keys and spacebar to enter pin.
    3. Should be able to backspace characters from the pin.
        1. Should delete a character from the pin when pressing the `backspace / delete` key.
        2. Should do nothing when pressing the `backspace / delete` key when the pin is empty.
    4. Should be able to enter up to 6 characters.
    5. Should not be able to submit with less than 4 characters.
    6. Should be able to leave the app then click back into the app and resume all the above tests.
    7. Should submit when clicking the “check” button.
    8. Should submit when pressing the `enter` key.
2. Create Account
    1. Should be able to enter a username.
    2. Should be able to click around and use keyboard shortcuts (such as copy-paste) to create the name.
    3. Submit button should be clickable once the username is valid.
    4. Submit button should not be clickable when the username is invalid.
    5. **NYI** Should be able to upload an image for the profile picture.
    6. Clicking the create account button should take you to the main application screen.

## Unlock

1. Should display the following when entering a pin
    1. Error text stating the pin didn’t work.
    2. Pin should turn red.
    3. “Check” button should not display.
    4. **NYI** Pin should shake.
2. Should be able to delete an incorrect pin to try again.
3. Should take you to the main page when entering the correct pin.
4. Should not take you to any other page.

## Friends

1. Should display a button in the sidebar if you have no friends yet.
    1. Should open friend modal when clicked.
    2. Should open the friends modal when clicking the `users` icon in the menu bar.
    3. Should copy `DIDKey` to the clipboard when clicking the “Copy Code” button.
    4. Should be able to interact with the add friend input.
        1. Should be able to paste a `DIDKey`.
        2. Should not be able to add yourself.
        3. Should be able to send a request to valid `DIDKey`.
        4. Should return an error when invalid `DIDKey` is supplied.
        5. Should submit when pressing the `enter` key.
        6. Should submit when pressing the “add” button.
    5. Should show friend requests on the remote instance of the app.
    6. Should allow remote to accept the request.
    7. Should allow remote to deny the request.
        1. Should remove the outgoing request from the origin’s account.
    8. Should show outgoing requests on the origin instance of the app.
        1. Should remove outgoing request on origin if remote denies the request.
    9. Should show a list of active friends.
    10. Should allow clicking the “chat” button to start a chat with a friend.

## Compose

1. Should be able to focus and type a multi-line message in the compose input.
2. Should be able to resize when multiple lines of text exist inside the input.
3. Should be able to use keyboard shortcuts to select, copy, paste, and otherwise modify the message.
4. Should be able to send the message by hitting either the return or the send button.
5. Should clear the input when a message is sent.
6. Should show placeholder text when the input is empty.
7. **NYI** (pending extension support) Should display any widgets next to the chat bar.
8. Should allow modification of text without any stuttering, delay, or disposition of the cursor during rapid typing. (Basically, we want to be able to be slamming out messages fast without any UI delay or ugly effects that make the app feel un-refined. It should feel nice to use the app.)

## File-Sharing

1. **NYE**

## Messaging

1. Should display messages between two or more people.
    1. Should display single and multi-line text messages which display matching the mock-ups.
    2. Should be clickable to make a message reply.
        1. Should be able to see a message pop up and type multi-line replies to a message.
        2. **NYE** (pending extension support) Should allow us to reply to messages with emojis.
        3. **NYE** (pending extension support) Should display any chatbar widgets.
    3. Should properly group messages and display timestamps and profile pictures according to the mock-ups.
    4. **NYI** Should allow us to click profile pictures to open the user's profile in a modal.
    5. Should automatically scroll to the bottom of the message box any time we get a new message in the conversation.
    6. Should update whenever we compose a new message in the conversation.
    7. **NYE** Should show messages in a different state when we've sent the message, but are still waiting for the recipient to get it. (This doesn't necessarily mean they read it, just that their system has the message and is ready for them to see it.)
    8. Should change when moving to a new conversation smoothly and cleanly without visual issues when rendering or jarring effects.

## Profile

1. **NYE**

## Sidebar

1. Should display the navbar at bottom of the sidebar.
    1. Home button is just an indicator right now and does not do anything.
    2. **NYE** Should be able to click files to open files browser view.
    3. Should open friends popup when user icon is clicked.
    4. Should open profile popup when a user with a circle icon is clicked. (Partially implemented.)
    5. **NYE** New chat button under favorites should display the quick chat popup.
    6. **NYE** Most frequently used chats should show up under the favorites tab. Note that this should be based off message quantity in addition to frequency recently, not just the most recent chats.
    7. **NYE** (pending extension support) Sidebar widgets should display.
    8. **NYE** Should display search results when a query is entered into search bar.
