package com.infamousvague.ghostmessaging

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * A WebSocket client (RFC 6455), as much of one as the relay needs (docs/desktop.md): `ws://` and `wss://`, text
 * and binary messages, pings answered. Android gives apps no WebSocket client of its own, and the app takes on no
 * networking library for this one connection. Nothing here touches Android (WsClientTest).
 *
 * [run] opens the connection and reads until it ends, on the thread that calls it; [sendText], [sendBinary] and
 * [close] are for any other thread.
 */
class WsClient(private val url: String, private val listener: Listener) {
    /** What the connection tells its owner, all on the thread that called [run]. */
    interface Listener {
        fun onOpen()
        fun onText(text: String)
        fun onBinary(bytes: ByteArray)

        /** The connection ended: the code the server closed it with, or null when it simply went. */
        fun onClosed(code: Int?)
    }

    private val random = SecureRandom()
    @Volatile private var socket: Socket? = null
    @Volatile private var output: OutputStream? = null
    @Volatile private var closed = false
    private val writeLock = Any()

    /** Silence for longer than this ends the connection: the relay pings every thirty seconds. */
    var idleMillis = 75_000

    /**
     * Connects, shakes hands and reads frames until the connection ends, however it ends; [Listener.onClosed] is
     * always the last thing said, once.
     */
    fun run() {
        var code: Int? = null
        try {
            val uri = URI(url)
            val secure = uri.scheme == "wss"
            require(secure || uri.scheme == "ws") { "Not a WebSocket address" }
            val host = uri.host ?: throw IOException("No host")
            val port = if (uri.port > 0) uri.port else if (secure) 443 else 80
            val plain = Socket()
            plain.connect(InetSocketAddress(host, port), 10_000)
            val s: Socket = if (!secure) plain else {
                val tls = (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(plain, host, port, true) as SSLSocket
                tls.startHandshake()
                if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(host, tls.session)) throw IOException("The relay's certificate is not for $host")
                tls
            }
            socket = s
            s.tcpNoDelay = true
            s.soTimeout = 15_000
            val input = DataInputStream(s.getInputStream().buffered())
            val out = s.getOutputStream()

            val key = Base64.getEncoder().encodeToString(ByteArray(16).also { random.nextBytes(it) })
            val path = (uri.rawPath?.ifEmpty { "/" } ?: "/") + (uri.rawQuery?.let { "?$it" } ?: "")
            val hostHeader = if (uri.port > 0) "$host:${uri.port}" else host
            out.write(("GET $path HTTP/1.1\r\nHost: $hostHeader\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n").toByteArray())
            out.flush()
            val head = readHead(input)
            // The server proves it speaks WebSocket by answering with the hash of our key and the protocol's GUID.
            val lines = head.split("\r\n")
            if (!lines[0].contains(" 101")) throw IOException("The relay answered: ${lines[0]}")
            val accept = lines.firstOrNull { it.startsWith("sec-websocket-accept:", ignoreCase = true) }?.substringAfter(':')?.trim()
            val want = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1").digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray()))
            if (accept != want) throw IOException("Not a WebSocket server")

            s.soTimeout = idleMillis
            output = out
            listener.onOpen()

            // A message may come in several frames: the first says its kind (1 text, 2 binary), the rest continue it
            // (0), and the one marked fin ends it. Close (8), ping (9) and pong (A) may come between them.
            val message = ByteArrayOutputStream()
            var kind = 0
            while (!closed) {
                val b0 = input.readUnsignedByte()
                val b1 = input.readUnsignedByte()
                val fin = b0 and 0x80 != 0
                val op = b0 and 0x0F
                var length = (b1 and 0x7F).toLong()
                if (length == 126L) length = input.readUnsignedShort().toLong() else if (length == 127L) length = input.readLong()
                if (length < 0 || length + message.size() > MAX_MESSAGE) throw IOException("Too long")
                val mask = if (b1 and 0x80 != 0) ByteArray(4).also { input.readFully(it) } else null
                val payload = ByteArray(length.toInt()).also { input.readFully(it) }
                if (mask != null) for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
                when (op) {
                    0x8 -> { code = if (payload.size >= 2) ((payload[0].toInt() and 0xFF) shl 8) or (payload[1].toInt() and 0xFF) else null; try { frame(0x8, payload.copyOf(minOf(2, payload.size))) } catch (_: Exception) {}; break }
                    0x9 -> frame(0xA, payload)
                    0xA -> {}
                    0x0, 0x1, 0x2 -> {
                        if (op != 0) kind = op
                        message.write(payload)
                        if (fin) {
                            val whole = message.toByteArray()
                            message.reset()
                            if (kind == 1) listener.onText(String(whole, Charsets.UTF_8)) else listener.onBinary(whole)
                        }
                    }
                    else -> throw IOException("Unknown frame")
                }
            }
        } catch (_: Exception) {
            // Whatever ended it, it ended: the listener is told once, below.
        } finally {
            closed = true
            output = null
            try { socket?.close() } catch (_: Exception) {}
            listener.onClosed(code)
        }
    }

    /** The server's answer to the handshake, up to and with the blank line that ends it; 16 KB at most. */
    private fun readHead(input: InputStream): String {
        val head = ByteArrayOutputStream()
        var state = 0
        while (state < 4) {
            val b = input.read()
            if (b < 0) throw IOException("Closed")
            head.write(b)
            if (head.size() > 16 * 1024) throw IOException("Too long")
            state = when {
                b == '\r'.code && (state == 0 || state == 2) -> state + 1
                b == '\n'.code && (state == 1 || state == 3) -> state + 1
                b == '\r'.code -> 1
                else -> 0
            }
        }
        return String(head.toByteArray(), Charsets.ISO_8859_1)
    }

    /** One frame from this end: whole messages only, masked as a client's must be. */
    private fun frame(op: Int, payload: ByteArray) {
        val out = output ?: throw IOException("Not open")
        val head = ByteArrayOutputStream(14)
        head.write(0x80 or op)
        when {
            payload.size < 126 -> head.write(0x80 or payload.size)
            payload.size < 65536 -> { head.write(0x80 or 126); head.write(payload.size ushr 8); head.write(payload.size and 0xFF) }
            else -> { head.write(0x80 or 127); for (i in 7 downTo 0) head.write(((payload.size.toLong() ushr (8 * i)) and 0xFF).toInt()) }
        }
        val mask = ByteArray(4).also { random.nextBytes(it) }
        head.write(mask)
        val masked = ByteArray(payload.size) { (payload[it].toInt() xor mask[it % 4].toInt()).toByte() }
        synchronized(writeLock) {
            out.write(head.toByteArray())
            out.write(masked)
            out.flush()
        }
    }

    /** False when the message could not go: the connection is over, or about to be. */
    fun sendText(text: String): Boolean = try { frame(0x1, text.toByteArray(Charsets.UTF_8)); true } catch (_: Exception) { close(); false }

    fun sendBinary(bytes: ByteArray): Boolean = try { frame(0x2, bytes); true } catch (_: Exception) { close(); false }

    /** Ends the connection from this end with a normal close (1000); [run] then returns and tells the listener. */
    fun close() {
        if (closed) return
        closed = true
        try { frame(0x8, byteArrayOf(0x03, 0xE8.toByte())) } catch (_: Exception) {}
        try { socket?.close() } catch (_: Exception) {}
    }

    companion object {
        /** The longest message taken, in bytes, all its frames together; a longer one ends the connection. */
        const val MAX_MESSAGE = 2L * 1024 * 1024
    }
}
