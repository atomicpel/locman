package app.locman

import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * Проверка «данные идут»: скачиваем через туннель (локальный SOCKS5 ядра) 64 КБ.
 * Короткий запрос generate_204 проходит и тогда, когда ТСПУ «замораживает» соединение
 * после первых ~16 КБ, — поэтому для решения «узел заморожен» нужен настоящий объём.
 */
object DataProbe {
    private val targets = listOf(
        "speed.cloudflare.com" to "/__down?bytes=65536",
        "proof.ovh.net" to "/files/1Mb.dat",
    )

    /** true — пришло не меньше 48 КБ хотя бы с одного адреса. */
    fun passes(spec: StartSpec): Boolean = targets.any { (host, path) ->
        runCatching { fetch(spec, host, path) }.getOrDefault(0) >= 48 * 1024
    }

    private fun fetch(spec: StartSpec, host: String, path: String): Int {
        val sock = Socket()
        sock.soTimeout = 7000
        sock.connect(InetSocketAddress("127.0.0.1", spec.socksPort), 3000)
        sock.use { raw ->
            val out = raw.getOutputStream()
            val inp = raw.getInputStream()
            // SOCKS5 с логином и паролем (RFC 1928/1929)
            out.write(byteArrayOf(5, 1, 2))
            out.flush()
            val greet = inp.readN(2)
            if (greet[0].toInt() != 5 || greet[1].toInt() != 2) return 0
            val u = spec.user.toByteArray()
            val p = spec.pass.toByteArray()
            out.write(byteArrayOf(1, u.size.toByte()) + u + byteArrayOf(p.size.toByte()) + p)
            out.flush()
            if (inp.readN(2)[1].toInt() != 0) return 0
            val h = host.toByteArray()
            out.write(byteArrayOf(5, 1, 0, 3, h.size.toByte()) + h + byteArrayOf(1, 0xBB.toByte()))
            out.flush()
            val head = inp.readN(4)
            if (head[1].toInt() != 0) return 0
            when (head[3].toInt()) {
                1 -> inp.readN(4 + 2)
                4 -> inp.readN(16 + 2)
                3 -> inp.readN((inp.read() and 0xFF) + 2)
                else -> return 0
            }
            val tls = (SSLSocketFactory.getDefault() as SSLSocketFactory)
                .createSocket(raw, host, 443, true) as SSLSocket
            tls.use { s ->
                s.soTimeout = 7000
                s.startHandshake()
                s.outputStream.write(
                    "GET $path HTTP/1.1\r\nHost: $host\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                        .toByteArray()
                )
                s.outputStream.flush()
                val buf = ByteArray(16 * 1024)
                var total = 0
                val started = System.currentTimeMillis()
                while (total < 72 * 1024 && System.currentTimeMillis() - started < 12_000) {
                    val n = s.inputStream.read(buf)
                    if (n < 0) break
                    total += n
                }
                return total
            }
        }
    }

    private fun InputStream.readN(n: Int): ByteArray {
        val b = ByteArray(n)
        var off = 0
        while (off < n) {
            val r = read(b, off, n - off)
            if (r < 0) error("eof")
            off += r
        }
        return b
    }
}
