package app.locman

import android.content.Context
import hev.sockstun.TProxyService
import java.io.File

/** TUN → SOCKS5: hev-socks5-tunnel превращает IP-пакеты в соединения к локальному входу Xray. */
object TunBridge {
    val isAvailable: Boolean by lazy { runCatching { System.loadLibrary("hev-socks5-tunnel") }.isSuccess }

    private var running = false

    @Synchronized
    fun start(context: Context, fd: Int, mtu: Int, port: Int, user: String, pass: String): Result<Unit> = runCatching {
        check(isAvailable) { "в сборке нет libhev-socks5-tunnel.so" }
        val config = File(context.filesDir, "hev.yml")
        config.writeText(
            """
            tunnel:
              mtu: $mtu
            socks5:
              port: $port
              address: 127.0.0.1
              udp: 'udp'
              username: '$user'
              password: '$pass'
            misc:
              task-stack-size: 81920
              log-level: warn
            """.trimIndent(),
        )
        check(TProxyService.TProxyStartService(config.absolutePath, fd)) { "hev-socks5-tunnel не принял конфиг" }
        running = true
    }

    @Synchronized
    fun stop() {
        if (!running) return
        runCatching { TProxyService.TProxyStopService() }
        running = false
    }

    /** [пакеты вверх, байты вверх, пакеты вниз, байты вниз] */
    fun stats(): LongArray? = if (running) runCatching { TProxyService.TProxyGetStats() }.getOrNull() else null
}
