package app.locman

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

/** Что нужно службе, чтобы поднять туннель. Сохраняется на диск — для плитки, загрузки и «постоянного VPN». */
data class StartSpec(
    val config: String,
    val name: String,
    val nodeId: String,
    val socksPort: Int,
    val httpPort: Int,
    val user: String,
    val pass: String,
    val bypass: List<String>,
    val mtu: Int,
    /** "xray" — TUN читает само ядро Xray; "hev" — через hev-socks5-tunnel и SOCKS5. */
    val tunMode: String = "xray",
) {
    fun toJson(): String = JSONObject()
        .put("config", config).put("name", name).put("nodeId", nodeId)
        .put("socksPort", socksPort).put("httpPort", httpPort).put("user", user).put("pass", pass)
        .put("bypass", JSONArray(bypass)).put("mtu", mtu).put("tunMode", tunMode)
        .toString()

    companion object {
        private fun file(ctx: Context) = File(ctx.filesDir, "last_start.json")

        fun save(ctx: Context, spec: StartSpec) {
            val f = file(ctx)
            val tmp = File(f.path + ".tmp")
            tmp.writeText(spec.toJson())
            tmp.renameTo(f)
        }

        fun load(ctx: Context): StartSpec? = runCatching {
            val j = JSONObject(file(ctx).readText())
            val bypass = j.optJSONArray("bypass") ?: JSONArray()
            StartSpec(
                config = j.getString("config"),
                name = j.optString("name", "Лоцман"),
                nodeId = j.optString("nodeId", ""),
                socksPort = j.getInt("socksPort"),
                httpPort = j.optInt("httpPort", 0),
                user = j.getString("user"),
                pass = j.getString("pass"),
                bypass = (0 until bypass.length()).map { bypass.getString(it) },
                mtu = j.optInt("mtu", 1500),
                tunMode = j.optString("tunMode", "xray"),
            )
        }.getOrNull()

        private fun flag(ctx: Context) = File(ctx.filesDir, "vpn_on")
        fun setWasOn(ctx: Context, on: Boolean) {
            runCatching { if (on) flag(ctx).writeText("1") else flag(ctx).delete() }
        }
        fun wasOn(ctx: Context): Boolean = flag(ctx).exists()
    }
}

sealed class VpnState {
    object Idle : VpnState()
    data class Connecting(val name: String, val nodeId: String) : VpnState()
    data class Connected(val name: String, val nodeId: String, val since: Long) : VpnState()
    data class Failed(val error: String) : VpnState()

    fun toMap(): Map<String, Any?> = when (this) {
        Idle -> mapOf("type" to "state", "phase" to "idle")
        is Connecting -> mapOf("type" to "state", "phase" to "connecting", "name" to name, "nodeId" to nodeId)
        is Connected -> mapOf("type" to "state", "phase" to "connected", "name" to name, "nodeId" to nodeId, "since" to since)
        is Failed -> mapOf("type" to "state", "phase" to "failed", "error" to error)
    }
}

/** Шина между службой и экраном. События доставляются в главный поток. */
object VpnBus {
    private val main = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArrayList<(Map<String, Any?>) -> Unit>()

    @Volatile
    var state: VpnState = VpnState.Idle
        private set

    fun set(s: VpnState) {
        state = s
        emit(s.toMap())
    }

    fun traffic(up: Long, down: Long, upTotal: Long, downTotal: Long) {
        emit(mapOf("type" to "traffic", "up" to up, "down" to down, "upTotal" to upTotal, "downTotal" to downTotal))
    }

    private fun emit(event: Map<String, Any?>) {
        if (listeners.isEmpty()) return
        main.post { listeners.forEach { runCatching { it(event) } } }
    }

    fun listen(l: (Map<String, Any?>) -> Unit) = listeners.add(l)
    fun unlisten(l: (Map<String, Any?>) -> Unit) = listeners.remove(l)
}
