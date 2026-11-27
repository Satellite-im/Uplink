package com.infamousvague.ghostmessaging

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.DataInputStream
import java.io.OutputStream
import java.net.ServerSocket
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** The phone's WebSocket client against a server written out here, frame by frame, as the RFC has them. */
class WsClientTest {
    /** One frame from a server: unmasked, in as many pieces as [pieces] says. */
    private fun serverFrame(out: OutputStream, op: Int, payload: ByteArray, fin: Boolean = true) {
        out.write((if (fin) 0x80 else 0) or op)
        when {
            payload.size < 126 -> out.write(payload.size)
            payload.size < 65536 -> { out.write(126); out.write(payload.size ushr 8); out.write(payload.size and 0xFF) }
            else -> { out.write(127); for (i in 7 downTo 0) out.write(((payload.size.toLong() ushr (8 * i)) and 0xFF).toInt()) }
        }
        out.write(payload)
        out.flush()
    }

    /** A client's frame, read as a server must: masked, or it is refused. */
    private fun clientFrame(input: DataInputStream): Pair<Int, ByteArray> {
        val b0 = input.readUnsignedByte()
        val b1 = input.readUnsignedByte()
        assertTrue("a client's frames are masked", b1 and 0x80 != 0)
        var length = (b1 and 0x7F).toLong()
        if (length == 126L) length = input.readUnsignedShort().toLong() else if (length == 127L) length = input.readLong()
        val mask = ByteArray(4).also { input.readFully(it) }
        val payload = ByteArray(length.toInt()).also { input.readFully(it) }
        for (i in payload.indices) payload[i] = (payload[i].toInt() xor mask[i % 4].toInt()).toByte()
        return (b0 and 0x0F) to payload
    }

    @Test
    fun itShakesHandsAndCarriesTextAndBytesBothWaysAndAnswersAPing() {
        val server = ServerSocket(0)
        val fromClient = LinkedBlockingQueue<Pair<Int, ByteArray>>()
        var path = ""
        val big = ByteArray(200000) { (it % 251).toByte() }
        val serving = Thread {
            server.accept().use { s ->
                val input = DataInputStream(s.getInputStream().buffered())
                val out = s.getOutputStream()
                val head = StringBuilder()
                while (!head.endsWith("\r\n\r\n")) head.append(input.read().toChar())
                path = head.lines()[0]
                val key = head.lines().first { it.startsWith("Sec-WebSocket-Key:") }.substringAfter(':').trim()
                val accept = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1").digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray()))
                out.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n".toByteArray())
                out.flush()
                fromClient += clientFrame(input)                 // the client's first words
                serverFrame(out, 0x1, "{\"ok\":true}".toByteArray())
                serverFrame(out, 0x9, "hi".toByteArray())        // a ping
                fromClient += clientFrame(input)                 // its pong
                serverFrame(out, 0x2, big.copyOfRange(0, 70000), fin = false)   // a message in three pieces
                serverFrame(out, 0x0, big.copyOfRange(70000, 140000), fin = false)
                serverFrame(out, 0x0, big.copyOfRange(140000, big.size))
                fromClient += clientFrame(input)                 // the client's bytes
                serverFrame(out, 0x8, byteArrayOf(0x11, 0x3A))   // closed, with 4410
                try { clientFrame(input) } catch (_: Exception) {}
            }
        }.also { it.start() }

        val texts = LinkedBlockingQueue<String>()
        val binaries = LinkedBlockingQueue<ByteArray>()
        val closed = CountDownLatch(1)
        var code: Int? = -1
        lateinit var client: WsClient
        client = WsClient("ws://127.0.0.1:${server.localPort}/relay/00ff?x=1", object : WsClient.Listener {
            override fun onOpen() { client.sendText("{\"auth\":\"t\"}") }
            override fun onText(text: String) { texts += text }
            override fun onBinary(bytes: ByteArray) { binaries += bytes; client.sendBinary(big.copyOfRange(0, 66000)) }
            override fun onClosed(c: Int?) { code = c; closed.countDown() }
        })
        Thread { client.run() }.start()

        assertEquals("{\"ok\":true}", texts.poll(5, TimeUnit.SECONDS))
        assertArrayEquals(big, binaries.poll(5, TimeUnit.SECONDS))
        assertTrue(closed.await(5, TimeUnit.SECONDS))
        serving.join(5000)
        assertEquals(4410, code)
        assertEquals("GET /relay/00ff?x=1 HTTP/1.1", path)
        val first = fromClient.poll(1, TimeUnit.SECONDS)!!
        assertEquals(0x1, first.first)
        assertEquals("{\"auth\":\"t\"}", String(first.second))
        val pong = fromClient.poll(1, TimeUnit.SECONDS)!!
        assertEquals(0xA, pong.first)
        assertEquals("hi", String(pong.second))
        val bytes = fromClient.poll(1, TimeUnit.SECONDS)!!
        assertEquals(0x2, bytes.first)
        assertArrayEquals(big.copyOfRange(0, 66000), bytes.second)
        // Once it is over nothing more goes out, and saying so does not throw.
        assertTrue(!client.sendText("late"))
        server.close()
    }

    @Test
    fun aServerThatIsNoWebSocketOrIsNotThereEndsItWithoutOpening() {
        val server = ServerSocket(0)
        Thread {
            server.accept().use { s ->
                val input = s.getInputStream()
                val head = StringBuilder()
                while (!head.endsWith("\r\n\r\n")) head.append(input.read().toChar())
                s.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi".toByteArray())
            }
        }.start()
        for (url in listOf("ws://127.0.0.1:${server.localPort}/x", "ws://127.0.0.1:1/x", "http://127.0.0.1/x")) {
            var opened = false
            val closed = CountDownLatch(1)
            WsClient(url, object : WsClient.Listener {
                override fun onOpen() { opened = true }
                override fun onText(text: String) {}
                override fun onBinary(bytes: ByteArray) {}
                override fun onClosed(code: Int?) { closed.countDown() }
            }).run()
            assertTrue(url, closed.await(1, TimeUnit.SECONDS))
            assertTrue(url, !opened)
        }
        server.close()
    }
}
