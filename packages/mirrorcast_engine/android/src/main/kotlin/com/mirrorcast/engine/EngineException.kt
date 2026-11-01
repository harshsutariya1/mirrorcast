package com.mirrorcast.engine

import com.mirrorcast.engine.protocol.ProtocolException
import com.mirrorcast.engine.protocol.RejectCode
import com.mirrorcast.engine.security.UntrustedReceiverException
import org.json.JSONObject
import java.io.EOFException
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/**
 * An error with a stable machine-readable [code] (used by Dart to choose what
 * to show) and a human-readable message.
 */
class EngineException(val code: String, message: String, cause: Throwable? = null) :
    IOException(message, cause) {

    companion object {
        /** Turns a REJECT packet from the Mac into an exception. */
        fun fromReject(body: JSONObject): EngineException {
            val code = body.optString("code", "rejected")
            val message = when (code) {
                RejectCode.NOT_PAIRED -> "This Mac doesn't trust this phone anymore. Pair again."
                RejectCode.BUSY -> "The Mac is already mirroring another phone."
                RejectCode.PAIRING_CLOSED -> "Click \"Pair new phone\" on your Mac first."
                RejectCode.CODE_MISMATCH -> "The code didn't match. A new code is shown on your Mac."
                RejectCode.VERSION -> "Update MirrorCast on both devices to the same version."
                else -> body.optString("message", "The Mac refused the connection.")
            }
            return EngineException(code, message)
        }

        /** Maps any failure to an [EngineException] with a friendly message. */
        fun from(error: Throwable): EngineException {
            if (error is EngineException) return error
            findCause<UntrustedReceiverException>(error)?.let {
                return EngineException(
                    "untrusted_receiver",
                    "This Mac's identity changed or it isn't paired. Pair again to continue.",
                    error,
                )
            }
            return when (error) {
                is SocketTimeoutException -> EngineException("timeout", "The Mac didn't respond in time.", error)
                is ConnectException, is NoRouteToHostException, is UnknownHostException ->
                    EngineException("unreachable", "Couldn't reach the Mac. Is MirrorCast open on it and on the same network?", error)
                is SSLException -> EngineException("tls_failed", "Secure connection failed: ${error.message}", error)
                is ProtocolException ->
                    EngineException("protocol_error", "Unexpected data from the Mac (${error.message}). Update both apps.", error)
                is EOFException -> EngineException("disconnected", "The Mac closed the connection.", error)
                is SecurityException -> EngineException("permission_denied", error.message ?: "Permission denied.", error)
                is IOException -> EngineException("network", error.message ?: "Network error.", error)
                else -> EngineException("internal", error.message ?: error.javaClass.simpleName, error)
            }
        }

        private inline fun <reified T : Throwable> findCause(error: Throwable): T? {
            var current: Throwable? = error
            var depth = 0
            while (current != null && depth < 10) {
                if (current is T) return current
                current = current.cause
                depth++
            }
            return null
        }
    }
}
