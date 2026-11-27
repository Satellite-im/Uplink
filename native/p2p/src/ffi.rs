//! The C interface: seven functions (include/ghost_p2p.h), and on Android one more for Kotlin.
//!
//! A node is a number. Commands go in as bytes (`ghost_p2p_command`). Events come out as messages posted to the Dart
//! port the node was made with, through the Dart VM's own `Dart_PostCObject` (which the Dart side hands over as
//! `NativeApi.postCObject`): nothing here ever calls into Dart, so nothing here can call an isolate that has gone. A
//! post to the port of an isolate that has gone fails, harmlessly, and then every node made for that port is let go:
//! the one who made them is gone. src/wire.rs is the layout of commands and events; README.md says it in tables.
//!
//! Nothing here waits on the network, and nothing here can take the app down: every entry catches a panic and
//! answers [`PANICKED`] (or nothing) instead.

use std::{
    collections::HashMap,
    ffi::c_void,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc, Mutex, MutexGuard, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

use tokio::runtime::Runtime;

use crate::{node::Node, wire::Event};

/// What the Dart side must find, or it does not use the library: raised whenever a function, a command, an event or
/// what one of them means changes.
pub const ABI: u32 = 2;

/// The version of the Dart VM's interface for native code (`DART_API_DL_MAJOR_VERSION`) whose message layout this
/// library writes. The Dart side says which its VM has; a node is made only where the two are one.
pub const DART_API_MAJOR: i64 = 2;

/// What `ghost_p2p_command` answers.
pub const OK: i32 = 0;
/// There is no such node.
pub const NO_NODE: i32 = -1;
/// The command could not be read.
pub const MALFORMED: i32 = -2;
/// SEND: there is no such stream (it has closed).
pub const NO_STREAM: i32 = -3;
/// SEND: the stream's queue was full, and the stream is now closed.
pub const OVERFLOW: i32 = -4;
/// SEND: the frame is longer than a stream carries.
pub const TOO_LONG: i32 = -5;
/// A bug in the library was caught.
pub const PANICKED: i32 = -6;

/// `bool Dart_PostCObject(Dart_Port port, Dart_CObject* message)`, as the Dart VM gives it.
pub type PostCObject = unsafe extern "C" fn(port: i64, message: *mut c_void) -> bool;

/// A message to a Dart port, as dart_native_api.h lays out `Dart_CObject` (its layout is the VM interface's major
/// version, [`DART_API_MAJOR`]): a kind, then a union of 40 bytes on a 64-bit system.
#[repr(C)]
struct DartCObject {
    kind: i32,
    value: DartValue,
}

/// The union in a `Dart_CObject`, with only the members a message here uses.
#[repr(C)]
#[derive(Clone, Copy)]
union DartValue {
    as_int64: i64,
    as_array: DartArray,
    as_typed_data: DartTypedData,
    /// The union's whole size: its largest member is the external typed data no message here uses.
    _whole: [u64; 5],
}

/// A list: how many items, and a pointer to each.
#[repr(C)]
#[derive(Clone, Copy)]
struct DartArray {
    length: isize,
    values: *mut *mut DartCObject,
}

/// Bytes the VM copies as it is posted them: what kind of typed data, how long, and where.
#[repr(C)]
#[derive(Clone, Copy)]
struct DartTypedData {
    kind: i32,
    length: isize,
    values: *const u8,
}

/// `Dart_CObject_kInt64`, `kArray` and `kTypedData`, and `Dart_TypedData_kUint8`.
const KIND_INT64: i32 = 3;
const KIND_ARRAY: i32 = 6;
const KIND_TYPED_DATA: i32 = 7;
const TYPED_UINT8: i32 = 2;

/// Posts a batch of a node's events to its port as one message, a list: the node's number, then each event's bytes,
/// a frame's own bytes beside its event's. The VM copies every byte before this returns (typed data is the sender's
/// to keep), so nothing here is held by Dart afterwards. False where the port is gone.
///
/// # Safety
/// `post` must be the Dart VM's `Dart_PostCObject`, called while the VM runs.
unsafe fn deliver(post: PostCObject, port: i64, node: u64, events: Vec<Event>) -> bool {
    let mut buffers: Vec<Vec<u8>> = Vec::with_capacity(events.len() + 1);
    for event in events {
        let (head, frame) = event.encode();
        buffers.push(head);
        if let Some(frame) = frame {
            buffers.push(frame);
        }
    }
    let mut objects: Vec<DartCObject> = Vec::with_capacity(buffers.len() + 1);
    objects.push(DartCObject { kind: KIND_INT64, value: DartValue { as_int64: node as i64 } });
    for bytes in &buffers {
        objects.push(DartCObject {
            kind: KIND_TYPED_DATA,
            value: DartValue { as_typed_data: DartTypedData { kind: TYPED_UINT8, length: bytes.len() as isize, values: bytes.as_ptr() } },
        });
    }
    let mut pointers: Vec<*mut DartCObject> = objects.iter_mut().map(|object| object as *mut DartCObject).collect();
    let mut message =
        DartCObject { kind: KIND_ARRAY, value: DartValue { as_array: DartArray { length: pointers.len() as isize, values: pointers.as_mut_ptr() } } };
    // SAFETY: the caller's word on `post`; the message and everything it points to live until this returns, and the
    // VM reads them only while it does.
    unsafe { post(port, (&mut message as *mut DartCObject).cast()) }
}

/// A node as the table holds it under its number.
struct Kept {
    node: Node,
    /// The Dart port its events go to, and so who made it: one port for each isolate.
    port: i64,
    /// Whether its events are still posted: not once it is dropped, or its port is gone.
    live: Arc<AtomicBool>,
}

/// Every node there is, by its number; the next number to give (never 0, never one twice); and the library's threads
/// (none where they could not be made).
static NODES: Mutex<Option<HashMap<u64, Arc<Kept>>>> = Mutex::new(None);
static NEXT: AtomicU64 = AtomicU64::new(1);
static RUNTIME: OnceLock<Option<Runtime>> = OnceLock::new();
/// Android: the app's context is in iroh's DNS ([`Java_com_infamousvague_ghostmessaging_P2pCore_nativeInstall`]).
#[cfg(target_os = "android")]
static ANDROID_READY: AtomicBool = AtomicBool::new(false);

/// A lock that a panic elsewhere has not made useless.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The library's own threads: two, made when the first node is, and kept for the life of the process.
fn runtime() -> Option<&'static Runtime> {
    RUNTIME.get_or_init(|| tokio::runtime::Builder::new_multi_thread().worker_threads(2).thread_name("ghost-p2p").enable_all().build().ok()).as_ref()
}

/// The node of that number, where there is one.
fn kept(node: u64) -> Option<Arc<Kept>> {
    lock(&NODES).as_ref()?.get(&node).cloned()
}

/// Lets a node go: nothing more of it is posted, and it stops by itself, in the background, once the last holder of
/// it (a command under way on another thread) is done with it.
fn let_go(kept: Arc<Kept>) {
    kept.live.store(false, Ordering::Relaxed);
}

/// The isolate `port` belongs to is gone (a post to it failed): so is every node made for it. Nothing else knows they
/// are there, so they are stopped, sockets and all.
fn orphaned(port: i64) {
    let gone: Vec<Arc<Kept>> = {
        let mut nodes = lock(&NODES);
        let Some(nodes) = nodes.as_mut() else { return };
        let numbers: Vec<u64> = nodes.iter().filter(|(_, kept)| kept.port == port).map(|(number, _)| *number).collect();
        numbers.iter().filter_map(|number| nodes.remove(number)).collect()
    };
    for kept in gone {
        let_go(kept);
    }
}

/// The number the Dart side checks before it uses anything else.
#[unsafe(no_mangle)]
pub extern "C" fn ghost_p2p_abi() -> u32 {
    ABI
}

/// Whether this copy of the library has what it needs of the system to make a node: on Android, the app's context,
/// which Kotlin hands over (P2pCore.kt) and without which no link helper's name can be looked up; elsewhere, nothing.
/// 1 or 0.
#[unsafe(no_mangle)]
pub extern "C" fn ghost_p2p_ready() -> i32 {
    #[cfg(target_os = "android")]
    return ANDROID_READY.load(Ordering::Relaxed) as i32;
    #[cfg(not(target_os = "android"))]
    1
}

/// The node id a node key makes, with nothing started. `secret` is 32 bytes, `out` is room for 32. Answers 0, or
/// [`MALFORMED`] where either is null.
///
/// # Safety
/// `secret` must be readable and `out` writable for 32 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ghost_p2p_node_id(secret: *const u8, out: *mut u8) -> i32 {
    if secret.is_null() || out.is_null() {
        return MALFORMED;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let mut key = [0u8; 32];
        // SAFETY: the caller's word that 32 bytes are there to read, and 32 to write.
        unsafe { std::ptr::copy_nonoverlapping(secret, key.as_mut_ptr(), 32) };
        let id = crate::node::node_id(&key);
        zeroize::Zeroize::zeroize(&mut key);
        unsafe { std::ptr::copy_nonoverlapping(id.as_ptr(), out, 32) };
        OK
    }))
    .unwrap_or(PANICKED)
}

/// Makes a node, not started, whose events are posted to `port` (a Dart port: `RawReceivePort.sendPort.nativePort`)
/// through `post` (the Dart VM's `Dart_PostCObject`: `NativeApi.postCObject`). `dart_api_major` is the VM interface's
/// major version (`NativeApi.majorVersion`): another than [`DART_API_MAJOR`] lays messages out otherwise, and no node
/// is made. Answers the node's number, or 0.
#[unsafe(no_mangle)]
pub extern "C" fn ghost_p2p_new(port: i64, post: Option<PostCObject>, dart_api_major: i64) -> u64 {
    let Some(post) = post else { return 0 };
    if port == 0 || dart_api_major != DART_API_MAJOR {
        return 0;
    }
    catch_unwind(|| {
        let Some(runtime) = runtime() else { return 0 };
        let number = NEXT.fetch_add(1, Ordering::Relaxed);
        let live = Arc::new(AtomicBool::new(true));
        let node = Node::new(runtime.handle(), {
            let live = live.clone();
            move |events: Vec<Event>| {
                if !live.load(Ordering::Relaxed) {
                    return;
                }
                // SAFETY: `post` is the Dart VM's own, which may be called from any thread while the VM runs.
                if !unsafe { deliver(post, port, number, events) } {
                    live.store(false, Ordering::Relaxed);
                    orphaned(port);
                }
            }
        });
        lock(&NODES).get_or_insert_with(HashMap::new).insert(number, Arc::new(Kept { node, port, live }));
        number
    })
    .unwrap_or(0)
}

/// Gives a node a command (README.md, "Commands"). Never waits: what a command comes to is said in events.
///
/// # Safety
/// `command` must be readable for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ghost_p2p_command(node: u64, command: *const u8, len: usize) -> i32 {
    if command.is_null() || len == 0 {
        return MALFORMED;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let Some(kept) = kept(node) else { return NO_NODE };
        // SAFETY: the caller's word that `len` bytes are there; they are read, never kept.
        let bytes = unsafe { std::slice::from_raw_parts(command, len) };
        kept.node.command(bytes)
    }))
    .unwrap_or(PANICKED)
}

/// Stops a node and forgets it. Once this has returned nothing more of it is posted; its links and sockets close in
/// the background, within a few seconds.
#[unsafe(no_mangle)]
pub extern "C" fn ghost_p2p_drop(node: u64) {
    let _ = catch_unwind(|| {
        let kept = lock(&NODES).as_mut().and_then(|nodes| nodes.remove(&node));
        if let Some(kept) = kept {
            let_go(kept);
        }
    });
}

/// The same as [`ghost_p2p_drop`], with the node's number as the token: what the Dart side attaches to each node with
/// a `NativeFinalizer`, so that the nodes of an isolate that ends (a hot restart, a test that forgot to let go, an
/// isolate that exits) are stopped as it ends, sockets and all, even where they would never have posted again.
#[unsafe(no_mangle)]
pub extern "C" fn ghost_p2p_finalize(token: *mut c_void) {
    ghost_p2p_drop(token as usize as u64);
}

/// Android: hands iroh's DNS the app's context, which it reads the phone's DNS servers through. P2pCore.kt calls it
/// when the app first starts a node, not before: a person who never switches the direct route on runs nothing of this
/// library. Without it no link helper's name can be looked up: this library asks no public DNS server in the system's
/// place. Answers whether the context is in place.
///
/// # Safety
/// Called by the JVM as the native method `P2pCore.nativeInstall(Context)`.
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub unsafe extern "system" fn Java_com_infamousvague_ghostmessaging_P2pCore_nativeInstall(
    env: *mut jni_sys::JNIEnv,
    _this: jni_sys::jobject,
    context: jni_sys::jobject,
) -> jni_sys::jboolean {
    static INSTALLING: Mutex<()> = Mutex::new(());
    if env.is_null() || context.is_null() {
        return false;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let _one = lock(&INSTALLING);
        if ANDROID_READY.load(Ordering::Relaxed) {
            return true;
        }
        // SAFETY: `env` is the JNI environment of the calling thread, and `context` a live reference, for the length
        // of this call. The context is made a global reference, which lives (as the virtual machine does) until the
        // process ends: what iroh asks of both.
        unsafe {
            let mut vm: *mut jni_sys::JavaVM = std::ptr::null_mut();
            // (Both calls are as old as JNI itself, which jni-sys files under the first version, 1.1.)
            if ((**env).v1_1.GetJavaVM)(env, &mut vm) != jni_sys::JNI_OK || vm.is_null() {
                return false;
            }
            let global = ((**env).v1_1.NewGlobalRef)(env, context);
            if global.is_null() {
                return false;
            }
            iroh::dns::install_android_jni_context(vm.cast(), global.cast());
        }
        ANDROID_READY.store(true, Ordering::Relaxed);
        true
    }))
    .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{cmd, ev};
    use std::{sync::mpsc, time::Duration};

    /// What the fake VM was posted: the port, the node, and each item after the node's number.
    type Heard = (i64, u64, Vec<Vec<u8>>);
    static HEARD: Mutex<Option<mpsc::Sender<Heard>>> = Mutex::new(None);
    /// The ports whose isolates the fake VM says are gone.
    static GONE: Mutex<Vec<i64>> = Mutex::new(Vec::new());

    /// Dart_PostCObject as the tests stand for it: it reads the message as the VM would, item by item, and copies
    /// what it is posted; a gone port's post fails, as the VM's does.
    unsafe extern "C" fn post(port: i64, message: *mut c_void) -> bool {
        if lock(&GONE).contains(&port) {
            return false;
        }
        // SAFETY: what `deliver` hands the VM, read while the call lasts.
        let (node, items) = unsafe {
            let message = &*(message as *const DartCObject);
            assert_eq!(message.kind, KIND_ARRAY);
            let array = message.value.as_array;
            let items = std::slice::from_raw_parts(array.values, array.length as usize);
            assert_eq!((*items[0]).kind, KIND_INT64);
            let node = (*items[0]).value.as_int64 as u64;
            let rest: Vec<Vec<u8>> = items[1..]
                .iter()
                .map(|item| {
                    assert_eq!((**item).kind, KIND_TYPED_DATA);
                    let data = (**item).value.as_typed_data;
                    assert_eq!(data.kind, TYPED_UINT8);
                    std::slice::from_raw_parts(data.values, data.length as usize).to_vec()
                })
                .collect();
            (node, rest)
        };
        if let Some(heard) = lock(&HEARD).as_ref() {
            let _ = heard.send((port, node, items));
        }
        true
    }

    /// `ghost_p2p_command`, given a slice.
    fn command(node: u64, bytes: &[u8]) -> i32 {
        unsafe { ghost_p2p_command(node, bytes.as_ptr(), bytes.len()) }
    }

    /// Starts a node with `secret` and no link helper.
    fn start(node: u64, secret: [u8; 32]) {
        let mut start = vec![cmd::START, 0];
        start.extend_from_slice(&secret);
        start.push(0);
        assert_eq!(command(node, &start), OK);
    }

    /// The layout the VM reads a message by: a kind of four bytes, then a union of forty, eight bytes in.
    #[test]
    fn a_message_is_laid_out_as_the_vm_reads_it() {
        assert_eq!(std::mem::size_of::<DartCObject>(), 48);
        assert_eq!(std::mem::align_of::<DartCObject>(), 8);
        assert_eq!(std::mem::offset_of!(DartCObject, value), 8);
        assert_eq!(std::mem::size_of::<DartTypedData>(), 24);
        assert_eq!(std::mem::offset_of!(DartTypedData, length), 8);
        assert_eq!(std::mem::offset_of!(DartTypedData, values), 16);
        assert_eq!(std::mem::size_of::<DartArray>(), 16);
    }

    /// The whole interface, as the Dart side uses it: a node is made, started, heard from, stopped and dropped, and
    /// what is wrong is answered, not obeyed. A node whose port is gone (its isolate ended) is let go, and so is every
    /// other node of that port; another port's are left alone.
    #[test]
    fn the_c_interface_end_to_end() {
        let (tx, rx) = mpsc::channel();
        *lock(&HEARD) = Some(tx);
        // The next event of a kind, whatever came before it.
        let next = |want: u8| loop {
            let (port, node, items) = rx.recv_timeout(Duration::from_secs(20)).expect("an event");
            if let Some(at) = items.iter().position(|item| item.first() == Some(&want)) {
                return (port, node, items[at].clone());
            }
        };
        assert_eq!(ghost_p2p_abi(), ABI);
        assert_eq!(ghost_p2p_ready(), 1);
        assert_eq!(ghost_p2p_new(7, None, DART_API_MAJOR), 0);
        assert_eq!(ghost_p2p_new(0, Some(post), DART_API_MAJOR), 0, "no port, no node");
        assert_eq!(ghost_p2p_new(7, Some(post), 3), 0, "a VM that lays messages out otherwise gets no node");

        let secret = [9u8; 32];
        let mut id = [0u8; 32];
        assert_eq!(unsafe { ghost_p2p_node_id(secret.as_ptr(), id.as_mut_ptr()) }, OK);
        assert_eq!(id, crate::node::node_id(&secret));
        assert_eq!(unsafe { ghost_p2p_node_id(std::ptr::null(), id.as_mut_ptr()) }, MALFORMED);

        let node = ghost_p2p_new(7, Some(post), DART_API_MAJOR);
        assert_ne!(node, 0);
        assert_eq!(command(node + 1000, &[cmd::STOP]), NO_NODE);
        assert_eq!(command(node, &[0x7f]), MALFORMED);
        assert_eq!(command(node, &[cmd::START, 0]), MALFORMED);
        assert_eq!(unsafe { ghost_p2p_command(node, std::ptr::null(), 4) }, MALFORMED);
        let mut send = vec![cmd::SEND];
        send.extend_from_slice(&77u64.to_be_bytes());
        send.extend_from_slice(b"to nobody");
        assert_eq!(command(node, &send), NO_STREAM);
        send.resize(crate::wire::FRAME_AT + crate::wire::MAX_FRAME + 1, 0);
        assert_eq!(command(node, &send), TOO_LONG);

        start(node, secret);
        // The first thing a node says is that it is up, and who it is; where it is comes after.
        let (port, from, items) = rx.recv_timeout(Duration::from_secs(20)).expect("an event");
        assert_eq!((port, from), (7, node));
        assert_eq!(items[0][0], ev::UP);
        assert_eq!(&items[0][1..], &id);
        next(ev::WHEREABOUTS);

        // An open to a node nothing is known of fails at once, and says which request failed.
        let mut open = vec![cmd::OPEN];
        open.extend_from_slice(&5u32.to_be_bytes());
        open.extend_from_slice(&crate::node::node_id(&[8u8; 32]));
        open.push(0);
        open.extend_from_slice(&2000u32.to_be_bytes());
        open.extend_from_slice(&[0, 0, 0]);
        assert_eq!(command(node, &open), OK);
        let (_, _, failed) = next(ev::OPEN_FAILED);
        assert_eq!(&failed[1..6], &[0, 0, 0, 5, crate::wire::OpenError::Unreachable as u8]);

        assert_eq!(command(node, &[cmd::STOP]), OK);
        next(ev::OFF);

        // Two more on the same port, and one on another. The first port's isolate goes: the next post there fails,
        // and every node of that port is let go with it; the other port's node goes on.
        let sibling = ghost_p2p_new(7, Some(post), DART_API_MAJOR);
        let other = ghost_p2p_new(8, Some(post), DART_API_MAJOR);
        assert!(sibling != 0 && other != 0 && sibling != node && other != sibling);
        lock(&GONE).push(7);
        start(node, secret);
        let mut gone = false;
        for _ in 0..400 {
            if command(node, &[cmd::STOP]) == NO_NODE {
                gone = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        assert!(gone, "a node whose port is gone was kept");
        assert_eq!(command(sibling, &[cmd::STOP]), NO_NODE, "another node of a port that is gone was kept");
        assert_eq!(command(other, &[cmd::STOP]), OK, "another port's node was let go");
        next(ev::OFF);

        // Dropped by a finalizer's token: the same as by its number.
        ghost_p2p_finalize(other as usize as *mut c_void);
        assert_eq!(command(other, &[cmd::STOP]), NO_NODE);
        ghost_p2p_drop(other);
        ghost_p2p_drop(node);
        lock(&GONE).clear();
    }
}
