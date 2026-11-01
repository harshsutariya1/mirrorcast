package com.mirrorcast.engine.pairing

import android.util.Base64
import com.mirrorcast.engine.EngineException
import com.mirrorcast.engine.protocol.Packet
import com.mirrorcast.engine.protocol.PacketType
import com.mirrorcast.engine.protocol.ProtocolException
import com.mirrorcast.engine.protocol.SessionIntent
import com.mirrorcast.engine.protocol.Wire
import com.mirrorcast.engine.security.Fingerprint
import com.mirrorcast.engine.security.Identity
import com.mirrorcast.engine.security.SecureChannel
import com.mirrorcast.engine.security.TlsConnector
import org.json.JSONObject
import java.io.IOException

/** Result of a successful pairing. */
data class PairingResult(
    val receiverName: String,
    val fingerprint: String,
    val host: String,
    val port: Int,
)

/**
 * Runs the phone side of pairing. Each call opens its own short-lived TLS
 * connection and closes it when done. Blocking: call from a background thread.
 */
class PairingClient(
    private val identity: Identity,
    private val deviceName: String,
) {
    private val connector = TlsConnector(identity)

    /** Pair by typing the 6-digit code shown on the Mac. */
    fun pairWithPin(host: String, port: Int, pinText: String): PairingResult {
        val pin = parsePin(pinText)
        // The Mac is still unknown, so accept any certificate here. The PIN
        // rounds below authenticate it (and bind the TLS session to it).
        val channel = connector.connect(host, port, trustedFingerprints = null)
        channel.use {
            channel.readTimeoutMs = STEP_TIMEOUT_MS
            hello(channel, SessionIntent.PAIR_PIN)

            val phoneFp = identity.fingerprintBytes
            val macFp = channel.peerFingerprint
            for (round in 0 until PairingCrypto.PIN_ROUNDS) {
                val bit = PairingCrypto.pinBit(pin, round)

                // 1. Commit to our nonce + PIN bit before seeing anything from the Mac.
                val ourNonce = PairingCrypto.nonce()
                val ourCommit = PairingCrypto.senderCommit(ourNonce, phoneFp, macFp, bit)
                sendRoundValue(channel, PacketType.PAIR_COMMIT, round, ourCommit)

                // 2. Receive the Mac's commitment.
                val theirCommit = expectRoundValue(channel, PacketType.PAIR_COMMIT, round, 32)

                // 3. Reveal our nonce so the Mac can check our commitment.
                sendRoundValue(channel, PacketType.PAIR_REVEAL, round, ourNonce)

                // 4. The Mac reveals its nonce; check that it used the same PIN bit.
                val theirNonce = expectRoundValue(channel, PacketType.PAIR_REVEAL, round, PairingCrypto.NONCE_SIZE)
                val expected = PairingCrypto.receiverCommit(theirNonce, macFp, phoneFp, bit)
                if (!PairingCrypto.constantTimeEquals(expected, theirCommit)) {
                    throw EngineException(
                        "code_mismatch",
                        "The code didn't match. Check the code on your Mac and try again.",
                    )
                }
            }
            return finish(channel, host, port)
        }
    }

    /** Pair using the contents of the QR code shown on the Mac. */
    fun pairWithQr(hosts: List<String>, port: Int, macFingerprint: String, secret: ByteArray): PairingResult {
        val pinned = Fingerprint.parse(macFingerprint)
            ?: throw EngineException("invalid_args", "The QR code contains an invalid fingerprint.")
        if (secret.size < PairingCrypto.QR_SECRET_MIN_SIZE) {
            throw EngineException("invalid_args", "The QR code is incomplete.")
        }
        if (hosts.isEmpty()) throw EngineException("invalid_args", "The QR code has no address.")

        // Try every address advertised in the QR code (Wi-Fi, Ethernet, hotspot...).
        var lastError: Exception? = null
        for (host in hosts) {
            val channel = try {
                connector.connect(host, port, trustedFingerprints = listOf(pinned), connectTimeoutMs = 2_500)
            } catch (e: Exception) {
                lastError = e
                continue
            }
            channel.use {
                channel.readTimeoutMs = STEP_TIMEOUT_MS
                hello(channel, SessionIntent.PAIR_QR)
                val proof = PairingCrypto.qrProof(secret, identity.fingerprintBytes, channel.peerFingerprint)
                channel.writer.writeControl(PacketType.PAIR_PROOF, JSONObject().put("proof", b64(proof)))
                return finish(channel, host, port)
            }
        }
        throw lastError ?: IOException("Could not reach the Mac")
    }

    private fun hello(channel: SecureChannel, intent: String) {
        val body = JSONObject()
            .put("protocol", Wire.PROTOCOL_VERSION)
            .put("intent", intent)
            .put("deviceName", deviceName)
        channel.writer.writeControl(PacketType.HELLO, body)
        expect(channel, PacketType.WELCOME)
    }

    private fun finish(channel: SecureChannel, host: String, port: Int): PairingResult {
        val result = expect(channel, PacketType.PAIR_RESULT).json()
        if (!result.optBoolean("ok", false)) throw EngineException("pairing_failed", "The Mac did not accept the pairing.")
        return PairingResult(
            receiverName = result.optString("receiverName", "Mac").take(MAX_NAME_LENGTH),
            fingerprint = channel.peerFingerprintHex,
            host = host,
            port = port,
        )
    }

    private fun sendRoundValue(channel: SecureChannel, type: Int, round: Int, value: ByteArray) {
        channel.writer.writeControl(type, JSONObject().put("round", round).put("value", b64(value)))
    }

    private fun expectRoundValue(channel: SecureChannel, type: Int, round: Int, size: Int): ByteArray {
        val body = expect(channel, type).json()
        if (body.optInt("round", -1) != round) throw ProtocolException("Pairing round out of order")
        val value = try {
            Base64.decode(body.optString("value"), Base64.NO_WRAP)
        } catch (e: IllegalArgumentException) {
            throw ProtocolException("Malformed pairing value")
        }
        if (value.size != size) throw ProtocolException("Pairing value has the wrong size")
        return value
    }

    private fun expect(channel: SecureChannel, type: Int): Packet {
        val packet = channel.reader.read()
        if (packet.type == PacketType.REJECT) throw EngineException.fromReject(packet.json())
        if (packet.type != type) throw ProtocolException("Unexpected packet 0x%02x".format(packet.type))
        return packet
    }

    private fun parsePin(text: String): Int {
        val digits = text.filter { it.isDigit() }
        if (digits.length != 6 || digits.length != text.trim().replace(" ", "").length) {
            throw EngineException("invalid_args", "Enter the 6-digit code shown on your Mac.")
        }
        return digits.toInt()
    }

    private fun b64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

    companion object {
        private const val STEP_TIMEOUT_MS = 10_000
        const val MAX_NAME_LENGTH = 64
    }
}
