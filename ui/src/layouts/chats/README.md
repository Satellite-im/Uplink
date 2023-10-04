# Chats Layout

## Overview
The Chats layout has its own UseSharedState - ChatData. State.chats still contains the list of participants, their identities, and whether or not they are typing. ChatData contains all the messages (for the active chat) and the information needed to initialize the view for a conversation. 

## Communication with Warp
- `presentation/chat/coroutine.rs` receives events from Warp (same way that `State` receives them in `main.rs`) and, if the message is for the active chat, updates ChatData accordingly. 

## Initialization
- `presentation/messages/effects.rs` has a `use_effect` which detects when the active chat id and chat key have changed. (really only the chat key is needed for this) and does the following
    - ask `ChatData` how to initialize the view (either scroll to the most recent message, scroll up to a specific message, or scroll down to a specific message) and wait for the associated scroll script to complete. 
    - send a command to a coroutine in `presentation/messages/coroutines.rs` to create an IntersectionObserver and receive events from it. 

## IntersectionObserver
- the IntersectionObserver Web API is used to detect which messages are displayed in the chats view. It is created using this script: `scripts/observer_script.js`, and is told which message id is at the top of the view, which id is at the bottom of the view, and if it should respond when said messages are scrolled to. If it responds, it will send an event and disconnect itself. 
- It also sends events when a message enters and exits the view. 
- The script is given a special variable - a UUID called the active chat key. Whenever the callback triggers, it checks for that UUID in the DOM and if it can't find an element with an ID matching that UUID, the IntersectionObserver will disconnect itself. This is needed because if a message is received, Dioxus has no way to tell the intersection observer to observe the new message. It has to modify the DOM and create a new IntersectionObserver with a new UUID (the active chat key). 
- All events emitted by the IntersectionObserver contain its associated UUID. When the `messages` coroutine receives an event from the observer, if the UUID  doesn't match, the event is ignored (this is perhaps a redundant precaution).

## Scrolling Behavior
- When a chat is selected, `DEFAULT_MESSAGES_TO_TAKE` messages are fetched from warp and displayed in the view. 
- `scripts/observer_script.js` is used to create an IntersectionObserver, which sends events to Dioxus when elements are added and removed from the view. 
- `ChatData.active_chat` has an element called `messages` (not to be confused with the presentation layer). `active_chat.messages` contains a list of all messages displayed in the view, all messages which have been loaded from warp, and a HashMap of (message uuid, message time). `active_chat.messages.displayed` and `active_chat.messages.all` are sorted by time, in increasing order. `active_chat.messages.all` is rendered. 
- when the intersection observer adds an element to the view, its timestamp will be either greater than everything in `active_chat.messages.displayed` (in which case the user scrolled down) or it will be less than everything in `active_chat.messages.all` (in which case the user scrolled up). This information is stored in `active_chat.behaviors`. When they return to this chat, Uplink will do the following
    - obtain the message id and timestamp of the message most recently scrolled to, and if the scroll was up or down. 
    - obtain `DEFAULT_MESSAGES_TO_TAKE`/2 before and after the message timestamp and add them to `active_chat.messages.all`. 
    - render the messges and scroll to the message id of aforementioned message. 