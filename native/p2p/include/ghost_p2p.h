/*
 * The direct network's core (native/p2p; docs/OPEN_NETWORK.md, section 2): the whole C interface.
 *
 * A node is a number. Commands go in as bytes; events come out as messages the library posts to the Dart port the
 * node was made with, through the Dart VM's own Dart_PostCObject: the library never calls into Dart, so it cannot call
 * an isolate that has gone (a post to its port fails, and every node made for that port is then let go). README.md
 * beside this folder lays out commands, events and messages. lib/net/p2p/node_ffi.dart is the one caller.
 *
 * Nothing here waits on the network, and every function may be called from any thread.
 */
#ifndef GHOST_P2P_H
#define GHOST_P2P_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* What ghost_p2p_abi() answers in this version of the interface. A caller that finds another number uses nothing. */
#define GHOST_P2P_ABI 2

/* The Dart VM interface's major version (DART_API_DL_MAJOR_VERSION) whose message layout the library writes. */
#define GHOST_P2P_DART_API_MAJOR 2

/* What ghost_p2p_command() answers. */
#define GHOST_P2P_OK 0
#define GHOST_P2P_NO_NODE (-1)   /* There is no such node. */
#define GHOST_P2P_MALFORMED (-2) /* The command could not be read. */
#define GHOST_P2P_NO_STREAM (-3) /* SEND: there is no such stream (it has closed). */
#define GHOST_P2P_OVERFLOW (-4)  /* SEND: the stream's queue was full, and the stream is now closed. */
#define GHOST_P2P_TOO_LONG (-5)  /* SEND: the frame is longer than a stream carries (1 MiB). */
#define GHOST_P2P_PANICKED (-6)  /* A bug in the library was caught. */

/* Dart_PostCObject, as the Dart VM gives it (NativeApi.postCObject): the port, then the message. */
typedef bool (*ghost_p2p_post_cb)(int64_t port, void *message);

/* The number of this interface: GHOST_P2P_ABI. */
uint32_t ghost_p2p_abi(void);

/*
 * Whether this copy of the library has what it needs of the system to make a node: on Android, the app's context,
 * which Kotlin hands over (P2pCore.kt, the first time the app starts a node); elsewhere nothing. 1 or 0.
 */
int32_t ghost_p2p_ready(void);

/*
 * The node id a node key makes, with nothing started. `secret` is 32 bytes; `out` is room for 32.
 * Answers GHOST_P2P_OK, or GHOST_P2P_MALFORMED where either is null.
 */
int32_t ghost_p2p_node_id(const uint8_t *secret, uint8_t *out);

/*
 * Makes a node, not started, whose events are posted to the Dart port `port` (RawReceivePort.sendPort.nativePort)
 * through `post`. `dart_api_major` is NativeApi.majorVersion: another than GHOST_P2P_DART_API_MAJOR lays messages out
 * otherwise, and no node is made. Answers its number, or 0 where it could not be made. Each message is a list: the
 * node's number, then each event's bytes in order, and for a FRAME event its frame's bytes after it.
 */
uint64_t ghost_p2p_new(int64_t port, ghost_p2p_post_cb post, int64_t dart_api_major);

/*
 * Gives a node a command: `len` bytes, read before this returns and not kept. Answers one of the numbers above.
 * What the command comes to is said in events.
 */
int32_t ghost_p2p_command(uint64_t node, const uint8_t *command, size_t len);

/*
 * Stops a node and forgets it. Once this has returned nothing more of it is posted; its links and sockets close in
 * the background, within a few seconds.
 */
void ghost_p2p_drop(uint64_t node);

/*
 * ghost_p2p_drop with the node's number as the token: for a NativeFinalizer attached to each node, so that the nodes
 * of an isolate that ends are stopped as it ends, even ones that would never have posted again.
 */
void ghost_p2p_finalize(void *token);

#ifdef __cplusplus
}
#endif

#endif
