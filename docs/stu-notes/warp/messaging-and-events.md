> messaging and events
---

# 2023-08-24
- pertinent functions are 
    - message.rs: `process_conversation` and `process_queue`
    - identity.rs: `process_message`

- typical design
    - business logic resides in the `store` folder, and each component has its own store. 

- sending a message:

- receiving a message event: 

## `MessageStore`
- `new()`
    - creates a `MessageStore`, clones it, passes the cloned instance to a task and returns the other instance. 
    - the task subscribes to IPFS pubsub and calls `process_conversation` and `process_queue`. 
- `conversation_event_handle()`
    - for a given conversation cid, creates a pair of channels, starts a task, and stores the task handle and tx channel in `self`.
    - responds to `Set` and `Get` events. 
    - `Get` calls `(*cid).get_local_dag(&ipfs)` and returns the `ConversationDocument`.
        - This seems to treat the cid ad a file which gets loaded into a `Ipld` which is a recursive data structure - basically a `Ipld::Map(BTreeMap<String, Ipld>)` and one of the `Ipld` entries in the map is a `Link` to presumably the previous `Ipld`. 

## ConversationDocument
- `get_raw_message_list`: calls`cid.get_ipld_dag` - not too interesting
- same for `get_message_list`
- `get_messages_stream` 
    - calls `get_message_list` but the returned thing is a `BTreeSet<MessageDocument>` (`MessageDocument` only contains one Cid)
    - the set is turned into a vec and the elements are returned one at a time to the stream. basically loads the whole thing from disk and returns it one at a time. 


## misc
- index a conversation so that you don't have to walk back as far...but how would that work? 
- or use the Ipld as an event log and ensure all the events are applied...
- why use IPLD at all? 
- probably would want to use a MerkleTree instead of a MerkleDag just to make it easier to modify older documents, like editing, reacting to, and deleting a message. 
- note about IPLD - each node seems to be a folder. nodes seem to be implicitly linked via the file system - the root folder is linked to its child folders, and so on. 


# proposed refactor
- store each conversation as a Merkle Tree, with leaf nodes ordered by creation time and sender id. I believe that Ipld can be used for this. 
- when a message is sent or altered, emit an event only to peers who are online. When a peer comes online, compare Merkle Trees and reconcile differences. 

# detecting when a message has been changed
- add a few more timestamp and signature fields to `Message`, to enable detecting when someone added/removed a reaction, edited the message or its attachments, etc. 
- for reactions, a message could store a HashMap<DID, ReactionList>. ReactionList could contain a timestamp and signature. When someone adds/removes a reaction, their ReactionList could be updated, given a new timestamp, and signed. 
- Something similar (using a timestamp and a signature) could be done when `attachments` is updated (if that's allowed) and when a message is pinned/unpinned. 
- might want a list of participants who pinned a message, in case two participants pin the same message independently (may be possible if they are online at different times). 
- if a message is deleted, still keep the message id in the conversation and indicate that the message was deleted. -> the contents of a `Message` could include an enumeration like this
```
struct Message {
    /// ID of the Message
    id: Uuid,

    /// Type of message being sent
    message_type: MessageType,

    /// Conversion id where `Message` is associated with.
    conversation_id: Uuid,

    /// ID of the sender of the message
    sender: DID,

    /// Timestamp of the message
    date: DateTime<Utc>,

    /// Timestamp of when message was modified
    /// Note: Only applies if the message itself was modified and not
    ///       related to being pinned, reacted, etc.
    modified: Option<DateTime<Utc>>,

    /// Signature of the message
    #[serde(skip_serializing_if = "Option::is_none")]
    signature: Option<Vec<u8>>,

    /// Metadata related to the message. Can be used externally, but more internally focused
    #[serde(flatten)]
    metadata: HashMap<String, String>,

    contents: enum Contents {
        Deleted,
        Message {
            /// Pin a message over other messages
            pinned: bool,

            /// List of the reactions for the `Message`
            reactions: Vec<Reaction>,

            /// ID of the message being replied to
            #[serde(skip_serializing_if = "Option::is_none")]
            replied: Option<Uuid>,

            /// Message context for `Message`
            value: Vec<String>,

            /// List of Attachment
            attachment: Vec<File>,
        }
    }
}
```