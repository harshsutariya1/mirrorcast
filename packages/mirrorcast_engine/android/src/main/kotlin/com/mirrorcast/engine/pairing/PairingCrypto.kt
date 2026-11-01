package com.mirrorcast.engine.pairing

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The math behind pairing. Must stay byte-for-byte identical to
 * `PairingCrypto.swift` on the Mac.
 *
 * PIN pairing uses the "passkey entry" idea from Bluetooth LE Secure
 * Connections: the 6-digit PIN is checked one bit per round. In every round
 * each side commits to (nonce, PIN bit, both certificate fingerprints) before
 * seeing the other's nonce. A man-in-the-middle has to guess each bit before
 * it is revealed, so it is caught with probability 1/2 per round. Over 20
 * rounds that's a 1 in 1,048,576 chance of going unnoticed, and since the PIN
 * changes after every attempt, it gets exactly one try.
 *
 * Binding the fingerprints into every commitment means that a successful run
 * proves both sides saw the *same* two TLS certificates, so the TLS
 * connection itself is authenticated, not just the PIN.
 */
object PairingCrypto {
    const val PIN_ROUNDS = 20 // 2^20 = 1,048,576 > 999,999
    const val NONCE_SIZE = 16
    const val QR_SECRET_MIN_SIZE = 16

    private const val LABEL_SENDER = "MirrorCast-PIN-v1/sender"
    private const val LABEL_RECEIVER = "MirrorCast-PIN-v1/receiver"
    private const val LABEL_QR = "MirrorCast-QR-v1"

    private val random = SecureRandom()

    fun nonce(): ByteArray = ByteArray(NONCE_SIZE).also { random.nextBytes(it) }

    /** Bit [round] of the PIN, as 0 or 1. */
    fun pinBit(pin: Int, round: Int): Int = (pin shr round) and 1

    /** Commitment sent by the phone in each round. */
    fun senderCommit(nonce: ByteArray, phoneFp: ByteArray, macFp: ByteArray, bit: Int): ByteArray =
        hmac(nonce, LABEL_SENDER.toByteArray(Charsets.UTF_8), phoneFp, macFp, byteArrayOf((0x80 or bit).toByte()))

    /** Commitment sent by the Mac in each round. */
    fun receiverCommit(nonce: ByteArray, macFp: ByteArray, phoneFp: ByteArray, bit: Int): ByteArray =
        hmac(nonce, LABEL_RECEIVER.toByteArray(Charsets.UTF_8), macFp, phoneFp, byteArrayOf((0x80 or bit).toByte()))

    /** Proof that the phone scanned the Mac's QR code. */
    fun qrProof(secret: ByteArray, phoneFp: ByteArray, macFp: ByteArray): ByteArray =
        hmac(secret, LABEL_QR.toByteArray(Charsets.UTF_8), phoneFp, macFp)

    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    private fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        for (part in parts) mac.update(part)
        return mac.doFinal()
    }
}
