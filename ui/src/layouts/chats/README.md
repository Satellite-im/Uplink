# Chats Layout

## Code Organization
- The first thing rendered (after the `ChatLayout`, found in the top level `mod.rs` file) is in `presentation/chat/mod.rs` - the `Compose` element. It composes the other elements defined in `presentation`.
- The Dioxus functions `use_future`, `use_effect`, and `use_coroutine` tend to take lots of space and have been moved into their own files. 
    - `use_coroutine` and `use_future` calls may be found in a file called `coroutines.rs`. (`use_future` can't go in a `futures.rs` file because that name conflicts with another crate). 
    - `use_effect` may be found in a file called `effects.rs`. 
- `data/` contains models used by the chats layout. 
- `scripts/` contains scripts needed by the chats layout. Each script is its own `.js` file and is imported in the `mod.rs` file using `include_str!`. 
- everything else is in `presentation/`

## Overview
The Chats layout has its own `UseSharedState` - `ChatData`. `State.chats` still contains the list of participants, their identities, and whether or not they are typing. `ChatData` contains all the messages (for the active chat) and the information needed to initialize the view for a chat. 

## ChatData
`ChatData` contains two fields - the `ActiveChat` and a `HashMap` of `ChatBehavior`s. 
- `ChatBehavior` does the following
    - describes how to initialize the view (which message should be at the top or bottom of the view)
    - tells what to do when the top or bottom of the view is reached (fetch more messages or do nothing)
- `ActiveChat` does the following
    - stores the messages which were fetched from warp
    - tracks which messages were displayed
    - stores "metadata" which is stuff fetched from `state.chats`
    - `ActiveChat` is further described in the section on scrolling behavior. 

## Communication with Warp
- `presentation/chat/coroutine.rs` receives events from `Warp` (same way that `State` receives them in `main.rs`) and, if the message is for the active chat, updates `ChatData` accordingly. 

## Initialization
- `presentation/messages/effects.rs` has a `use_effect` which detects when the chat key has changed and does the following
    - ask `ChatData` how to initialize the view (either scroll to the most recent message, scroll up to a specific message, or scroll down to a specific message) and wait for the associated scroll script to complete. 
    - send a command to a coroutine in `presentation/messages/coroutines.rs` to create an `IntersectionObserver` and receive events from it. 

## IntersectionObserver
- the `IntersectionObserver` Web API (https://developer.mozilla.org/en-US/docs/Web/API/IntersectionObserver) is used to detect which messages are displayed in the chats view. It is created using this script: `scripts/observer_script.js`, and is told which message id is at the start of the list, which id is at the end of the list, and if it should respond when said messages are scrolled into view. If it responds, it will send an event and disconnect itself. 
- The script is given a special variable - a UUID called the active chat key. Whenever the callback triggers, it checks for that UUID in the DOM and if it can't find an element with an ID matching that UUID, the `IntersectionObserver` will disconnect itself. This is needed because if a message is received, Dioxus has no way to tell the `IntersectionObserver` to observe the new message (also has no way to stop the `IntersectionObserver`). It has to modify the DOM and create a new `IntersectionObserver` with a new active chat key. Note that the active chat id is different from the active chat key.  
- All events emitted by the `IntersectionObserver` contain its associated UUID. When the `messages` coroutine receives an event from the observer, if the UUID  doesn't match, the event is ignored (this is perhaps a redundant precaution, now that the `IntersectionObserver` checks the DOM and self terminates).

## Scrolling Behavior
- When a chat is selected, `DEFAULT_MESSAGES_TO_TAKE` messages are fetched from `Warp` and displayed in the view. 
- An `IntersectionObserver` is created.
- `ChatData.active_chat` has an element called `messages` (not to be confused with the presentation layer `presentation/messages`). `active_chat.messages` contains a list of all messages displayed in the view, all messages which have been loaded from `Warp`, and a `HashMap` of (message uuid, message time). `active_chat.messages.displayed` and `active_chat.messages.all` are sorted by time, in increasing order. `active_chat.messages.all` is rendered in `presentation/messages/mod.rs`. 
- when the intersection observer adds an element to the view, its timestamp will be either greater than everything in `active_chat.messages.displayed` (in which case the user scrolled down) or it will be less than everything in `active_chat.messages.all` (in which case the user scrolled up). This information is stored in `active_chat.behaviors`. When they return to this chat, Uplink will do the following
    - obtain the message id and timestamp of the message most recently scrolled to, and if the scroll was up or down. 
    - obtain `DEFAULT_MESSAGES_TO_TAKE`/2 before and after the message timestamp and add them to `active_chat.messages.all`. 
    - if the user had scrolled to the bottom of the view, instead fetch the most recent messages.
    - render the messges and scroll to the message id of previously mentioned message. 

## More Initialization
- `presentation/messages/coroutine.rs` needs to do the following:
    - wait until `presentation/messages/mod.rs` renders the messages in `active_chat.messages.all`
    - next create the `IntersectionObserver`. 
    - receive events from the `IntersectionObserver` but also receive events from the coroutine channel (in case the active chat key changes, due to switching conversations or loading new messages into `active_chat.messages.all`).
- To accomidate this, there is a nested loop in `presentation/messages/coroutine.rs`. The innermost loop uses a `tokio::select!` statement to poll the javascript evaluator and the coroutine channel. 