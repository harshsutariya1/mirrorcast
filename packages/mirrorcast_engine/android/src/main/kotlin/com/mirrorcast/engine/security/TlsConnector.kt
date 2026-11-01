package com.mirrorcast.engine.security

import com.mirrorcast.engine.protocol.PacketReader
import com.mirrorcast.engine.protocol.PacketWriter
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509ExtendedTrustManager

/**
 * Raised when the Mac presents a certificate we have not paired with. This is
 * what a man-in-the-middle attempt (or a reinstalled Mac app) looks like.
 */
class UntrustedReceiverException(val presentedFingerprint: String) :
    CertificateException("The receiver's identity does not match any paired Mac")

/** An open, authenticated TLS 1.3 connection to a Mac. */
class SecureChannel(
    private val socket: SSLSocket,
    /** SHA-256 fingerprint of the Mac's certificate (raw bytes). */
    val peerFingerprint: ByteArray,
) : Closeable {
    val reader = PacketReader(BufferedInputStream(socket.inputStream, 64 * 1024))
    val writer = PacketWriter(BufferedOutputStream(socket.outputStream, 64 * 1024))

    val peerFingerprintHex: String get() = Fingerprint.hex(peerFingerprint)

    /** Read timeout in milliseconds; 0 waits forever. */
    var readTimeoutMs: Int
        get() = socket.soTimeout
        set(value) {
            socket.soTimeout = value
        }

    override fun close() {
        try {
            socket.close()
        } catch (_: IOException) {
        }
    }
}

/**
 * Opens TLS 1.3 connections with mutual authentication:
 *  - the phone proves its identity with its Keystore-backed certificate, and
 *  - the Mac's certificate is checked against pinned fingerprints instead of
 *    certificate authorities (there are no CAs on a home network).
 */
class TlsConnector(private val identity: Identity) {

    /**
     * @param trustedFingerprints fingerprints we accept for the Mac. Pass
     *   `null` only for PIN pairing, where the Mac is not known yet and is
     *   authenticated afterwards by the PIN protocol.
     */
    @Throws(IOException::class)
    fun connect(
        host: String,
        port: Int,
        trustedFingerprints: List<ByteArray>?,
        connectTimeoutMs: Int = 4_000,
    ): SecureChannel {
        val trustManager = PinnedTrustManager(trustedFingerprints)
        val context = SSLContext.getInstance("TLS").apply {
            init(arrayOf(IdentityKeyManager(identity)), arrayOf(trustManager), SecureRandom())
        }

        val raw = Socket()
        try {
            raw.tcpNoDelay = true // never wait to coalesce small packets
            raw.keepAlive = true
            raw.trafficClass = 0xB8 // DSCP EF (expedited forwarding), honoured by some routers
            raw.sendBufferSize = 512 * 1024
            raw.connect(InetSocketAddress(host, port), connectTimeoutMs)
            raw.soTimeout = HANDSHAKE_TIMEOUT_MS

            val ssl = context.socketFactory.createSocket(raw, host, port, true) as SSLSocket
            ssl.enabledProtocols = arrayOf("TLSv1.3")
            ssl.useClientMode = true
            ssl.startHandshake()

            val peer = trustManager.acceptedFingerprint
                ?: throw IOException("Receiver did not present a certificate")
            return SecureChannel(ssl, peer)
        } catch (e: Exception) {
            try {
                raw.close()
            } catch (_: IOException) {
            }
            throw e
        }
    }

    companion object {
        const val HANDSHAKE_TIMEOUT_MS = 8_000
    }
}

/** Accepts the Mac only if its certificate fingerprint is in the pinned set. */
private class PinnedTrustManager(private val pins: List<ByteArray>?) : X509ExtendedTrustManager() {
    @Volatile
    var acceptedFingerprint: ByteArray? = null
        private set

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        if (chain.isNullOrEmpty()) throw CertificateException("No certificate presented")
        val fingerprint = Fingerprint.sha256(chain[0].encoded)
        if (pins != null && pins.none { Fingerprint.matches(it, fingerprint) }) {
            throw UntrustedReceiverException(Fingerprint.hex(fingerprint))
        }
        acceptedFingerprint = fingerprint
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) =
        checkServerTrusted(chain, authType)

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) =
        checkServerTrusted(chain, authType)

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
        throw CertificateException("The phone never acts as a TLS server")

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) =
        checkClientTrusted(chain, authType)

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) =
        checkClientTrusted(chain, authType)

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

/** Presents this phone's Keystore certificate when the Mac asks for one. */
private class IdentityKeyManager(private val identity: Identity) : X509ExtendedKeyManager() {
    private val alias = DeviceIdentity.ALIAS

    override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = alias
    override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = alias
    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String> = arrayOf(alias)
    override fun getCertificateChain(alias: String?): Array<X509Certificate> = arrayOf(identity.certificate)
    override fun getPrivateKey(alias: String?): PrivateKey = identity.privateKey

    override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? = null
    override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null
}
