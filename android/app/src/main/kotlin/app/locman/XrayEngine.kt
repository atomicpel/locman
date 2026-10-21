package app.locman

import android.content.Context
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Ядро Xray из AndroidLibXrayLite (libv2ray.aar). Вызовы через рефлексию — так сборка
 * переживает мелкие изменения сигнатур между версиями библиотеки (подход Farvater).
 */
object XrayEngine {
    private const val LIB = "libv2ray.Libv2ray"
    private const val CALLBACK = "libv2ray.CoreCallbackHandler"
    private const val MEASURE_TIMEOUT_MS = 6000L

    private var controller: Any? = null
    var lastError: String? = null
        private set

    val isAvailable: Boolean by lazy { runCatching { Class.forName(LIB) }.isSuccess }

    val version: String? by lazy {
        if (!isAvailable) null else runCatching { libMethod("checkVersionX")?.invoke(null) as? String }.getOrNull()
    }

    private val measureMethod: Method? by lazy { libMethod("measureOutboundDelay") }
    private val measurers = Executors.newCachedThreadPool { r -> Thread(r, "locman-measure").apply { isDaemon = true } }
    private val ready = CountDownLatch(1)

    private fun libMethod(name: String): Method? =
        runCatching { Class.forName(LIB).methods.firstOrNull { it.name == name } }.getOrNull()

    @Volatile
    private var initStarted = false

    @Synchronized
    fun init(context: Context) {
        if (initStarted) return
        initStarted = true
        val dir = context.filesDir.absolutePath
        thread(name = "xray-init") {
            if (isAvailable) runCatching {
                val m = libMethod("initCoreEnv") ?: libMethod("initV2Env")
                if (m != null && m.parameterCount == 2) m.invoke(null, dir, "")
            }
            ready.countDown()
        }
    }

    val isRunning: Boolean get() = controller != null

    @Synchronized
    fun start(config: String, tunFd: Int = 0): Result<Unit> = runCatching {
        ready.await(10, TimeUnit.SECONDS)
        check(isAvailable) { "ядро Xray не встроено в сборку" }
        stop()
        controller = launch(config, tunFd)
        lastError = null
    }.onFailure { lastError = (it.cause ?: it).message }

    /** Задержка запроса через работающий туннель (то же ядро), мс; -1 — не прошёл. */
    fun measureCurrent(url: String): Long {
        val c = controller ?: return -1
        val m = c.javaClass.methods.firstOrNull { it.name == "measureDelay" && it.parameterCount == 1 } ?: return -1
        val task = measurers.submit<Long> { (m.invoke(c, url) as Number).toLong() }
        return runCatching { task.get(14_000, TimeUnit.MILLISECONDS) }
            .onFailure { task.cancel(true) }
            .getOrDefault(-1L)
    }

    private val probes = java.util.concurrent.ConcurrentHashMap<Int, Any>()
    private val probeIds = java.util.concurrent.atomic.AtomicInteger(1)

    /** Отдельный экземпляр ядра (без TUN) для замера скорости узла. */
    fun startProbe(config: String): Int? = runCatching {
        ready.await(10, TimeUnit.SECONDS)
        check(isAvailable)
        val c = launch(config, 0)
        val id = probeIds.getAndIncrement()
        probes[id] = c
        id
    }.getOrNull()

    fun stopProbe(id: Int) {
        val c = probes.remove(id) ?: return
        runCatching { c.javaClass.methods.first { it.name == "stopLoop" }.invoke(c) }
    }

    /** Байты через все выходы с прошлого вызова: (вверх, вниз). Нужен "stats" в конфиге. */
    fun trafficDelta(): Pair<Long, Long> {
        val c = controller ?: return 0L to 0L
        val text = runCatching {
            c.javaClass.methods.firstOrNull { it.name == "queryAllOutboundTrafficStats" }?.invoke(c) as? String
        }.getOrNull().orEmpty()
        var up = 0L
        var down = 0L
        text.split(';').forEach { item ->
            val parts = item.split(',')
            if (parts.size == 3) {
                val v = parts[2].toLongOrNull() ?: 0L
                if (parts[1] == "uplink") up += v else if (parts[1] == "downlink") down += v
            }
        }
        return up to down
    }

    private fun launch(config: String, tunFd: Int): Any {
        val handlerClass = Class.forName(CALLBACK)
        val handler = Proxy.newProxyInstance(handlerClass.classLoader, arrayOf(handlerClass)) { proxy, method, args ->
            when (method.name) {
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.getOrNull(0)
                "toString" -> "LocmanCoreCallback"
                else -> when (method.returnType) {
                    java.lang.Long.TYPE -> 0L
                    java.lang.Integer.TYPE -> 0
                    java.lang.Boolean.TYPE -> false
                    else -> null
                }
            }
        }
        val ctrl = libMethod("newCoreController")?.invoke(null, handler) ?: error("newCoreController недоступен")
        val startLoop = ctrl.javaClass.methods.first { it.name == "startLoop" }
        when (startLoop.parameterCount) {
            1 -> {
                check(tunFd == 0) { "эта версия ядра не умеет TUN" }
                startLoop.invoke(ctrl, config)
            }
            2 -> startLoop.invoke(ctrl, config, tunFd)
            else -> error("неизвестная сигнатура startLoop")
        }
        return ctrl
    }

    @Synchronized
    fun stop() {
        val c = controller ?: return
        runCatching { c.javaClass.methods.first { it.name == "stopLoop" }.invoke(c) }
        controller = null
    }

    /** Задержка запроса [url] через узел из [config], мс; -1 — не прошёл. */
    fun measureDelay(config: String, url: String): Long {
        val m = measureMethod ?: return -1
        val task = measurers.submit<Long> {
            ready.await(10, TimeUnit.SECONDS)
            (m.invoke(null, config, url) as Number).toLong()
        }
        return runCatching { task.get(MEASURE_TIMEOUT_MS, TimeUnit.MILLISECONDS) }
            .onFailure { task.cancel(true) }
            .getOrDefault(-1L)
    }
}
