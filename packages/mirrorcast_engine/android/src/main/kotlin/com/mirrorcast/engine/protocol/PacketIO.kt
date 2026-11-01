package com.mirrorcast.engine.protocol

import org.json.JSONObject
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** One decoded packet. */
class Packet(
    val type: Int,
    val flags: Int,
    val ptsUs: Long,
    val payload: ByteArray,
) {
    val isKeyframe: Boolean get() = (flags and Wire.FLAG_KEYFRAME) != 0

    /** Parses the payload of a control packet as JSON. */
    fun json(): JSONObject = Control.decode(payload)
}

/** Thrown when the peer sends something that violates the protocol. */
class ProtocolException(message: String) : IOException(message)

/**
 * Reads packets from a stream. Not thread-safe: use from one thread only.
 */
class PacketReader(input: InputStream) {
    private val stream = DataInputStream(input)
    private val header = ByteArray(Wire.HEADER_SIZE)

    @Throws(IOException::class)
    fun read(): Packet {
        stream.readFully(header)
        val buffer = ByteBuffer.wrap(header).order(ByteOrder.BIG_ENDIAN)
        val type = buffer.get().toInt() and 0xFF
        val flags = buffer.get().toInt() and 0xFF
        val pts = buffer.long
        val length = buffer.int

        if (!PacketType.isKnown(type)) throw ProtocolException("Unknown packet type 0x%02x".format(type))
        if (length < 0 || length > Wire.maxPayloadFor(type)) {
            throw ProtocolException("Payload of $length bytes is too large for type 0x%02x".format(type))
        }
        val payload = ByteArray(length)
        stream.readFully(payload)
        return Packet(type, flags, pts, payload)
    }
}

/**
 * Writes packets to a stream. Writes are serialized with a lock so that a
 * header and its payload are never interleaved with another packet.
 */
class PacketWriter(private val output: OutputStream) {
    private val header = ByteBuffer.allocate(Wire.HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
    private val lock = Any()

    @Throws(IOException::class)
    fun write(
        type: Int,
        payload: ByteArray,
        ptsUs: Long = 0L,
        flags: Int = 0,
        flush: Boolean = true,
    ) {
        require(payload.size <= Wire.maxPayloadFor(type)) { "Payload too large: ${payload.size}" }
        synchronized(lock) {
            header.clear()
            header.put(type.toByte())
            header.put(flags.toByte())
            header.putLong(ptsUs)
            header.putInt(payload.size)
            output.write(header.array(), 0, Wire.HEADER_SIZE)
            output.write(payload)
            if (flush) output.flush()
        }
    }

    @Throws(IOException::class)
    fun writeControl(type: Int, body: JSONObject = JSONObject(), flush: Boolean = true) {
        write(type, Control.encode(body), flush = flush)
    }

    @Throws(IOException::class)
    fun flush() {
        synchronized(lock) { output.flush() }
    }
}

/** Helpers for JSON control payloads. */
object Control {
    fun encode(body: JSONObject): ByteArray = body.toString().toByteArray(Charsets.UTF_8)

    @Throws(ProtocolException::class)
    fun decode(payload: ByteArray): JSONObject = try {
        if (payload.isEmpty()) JSONObject() else JSONObject(String(payload, Charsets.UTF_8))
    } catch (e: Exception) {
        throw ProtocolException("Malformed control message")
    }
}
