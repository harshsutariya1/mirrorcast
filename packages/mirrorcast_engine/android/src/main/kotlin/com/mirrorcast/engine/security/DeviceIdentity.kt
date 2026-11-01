package com.mirrorcast.engine.security

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.security.auth.x500.X500Principal

/**
 * This phone's long-term identity: an ECDSA P-256 key pair plus a self-signed
 * certificate, both created on first launch.
 *
 * The private key is generated inside Android Keystore (hardware-backed on
 * almost every phone) and can never be exported. The Mac remembers this phone
 * by the SHA-256 fingerprint of the certificate.
 */
class Identity(
    val privateKey: PrivateKey,
    val certificate: X509Certificate,
) {
    /** SHA-256 of the DER certificate, as raw bytes. */
    val fingerprintBytes: ByteArray = Fingerprint.sha256(certificate.encoded)

    /** SHA-256 of the DER certificate, as 64 lowercase hex characters. */
    val fingerprint: String = Fingerprint.hex(fingerprintBytes)
}

object DeviceIdentity {
    private const val KEYSTORE = "AndroidKeyStore"
    const val ALIAS = "mirrorcast_device_identity_v1"
    private const val VALIDITY_YEARS = 25L

    @Volatile
    private var cached: Identity? = null

    /** Returns the identity, creating it the first time. Safe from any thread. */
    @Synchronized
    fun get(): Identity {
        cached?.let { return it }
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        if (!keyStore.containsAlias(ALIAS)) generate()

        val key = keyStore.getKey(ALIAS, null) as? PrivateKey
        val cert = keyStore.getCertificate(ALIAS) as? X509Certificate
        val identity = if (key != null && cert != null) {
            Identity(key, cert)
        } else {
            // A half-written entry should never happen, but recover by starting over.
            keyStore.deleteEntry(ALIAS)
            generate()
            Identity(
                keyStore.getKey(ALIAS, null) as PrivateKey,
                keyStore.getCertificate(ALIAS) as X509Certificate,
            )
        }
        cached = identity
        return identity
    }

    private fun generate() {
        val now = System.currentTimeMillis()
        val day = 24L * 60 * 60 * 1000
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            // TLS 1.3 signs with SHA-256; NONE is listed because some TLS
            // stacks hash first and ask the key to sign the raw digest.
            .setDigests(
                KeyProperties.DIGEST_NONE,
                KeyProperties.DIGEST_SHA256,
                KeyProperties.DIGEST_SHA384,
                KeyProperties.DIGEST_SHA512,
            )
            .setCertificateSubject(X500Principal("CN=MirrorCast Sender"))
            .setCertificateSerialNumber(BigInteger(63, SecureRandom()).add(BigInteger.ONE))
            .setCertificateNotBefore(Date(now - day))
            .setCertificateNotAfter(Date(now + VALIDITY_YEARS * 365 * day))
            .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE).run {
            initialize(spec)
            generateKeyPair()
        }
    }
}

object Fingerprint {
    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    fun hex(bytes: ByteArray): String = buildString(bytes.size * 2) {
        for (b in bytes) append("%02x".format(b.toInt() and 0xFF))
    }

    /** Parses 64 hex characters (colons/spaces allowed). Returns null if invalid. */
    fun parse(text: String): ByteArray? {
        val clean = text.filter { !it.isWhitespace() && it != ':' }.lowercase()
        if (clean.length != 64 || clean.any { it !in '0'..'9' && it !in 'a'..'f' }) return null
        return ByteArray(32) { i -> clean.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }

    /** Constant-time comparison of two fingerprints. */
    fun matches(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)
}
