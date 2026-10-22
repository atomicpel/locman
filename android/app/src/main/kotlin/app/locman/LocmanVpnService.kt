package app.locman

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class LocmanVpnService : VpnService() {
    companion object {
        const val ACTION_START = "app.locman.action.START"
        const val ACTION_STOP = "app.locman.action.STOP"
        private const val CHANNEL = "vpn"
        private const val NOTIFICATION_ID = 7
        private const val PROBE_URL_2 = "https://cp.cloudflare.com/generate_204"

        fun start(ctx: Context, spec: StartSpec) {
            StartSpec.save(ctx, spec)
            ctx.startForegroundService(Intent(ctx, LocmanVpnService::class.java).setAction(ACTION_START))
        }

        /** Поднять последний туннель (плитка, загрузка). */
        fun restart(ctx: Context): Boolean {
            if (StartSpec.load(ctx) == null || prepare(ctx) != null) return false
            ctx.startForegroundService(Intent(ctx, LocmanVpnService::class.java).setAction(ACTION_START))
            return true
        }

        fun stop(ctx: Context) {
            StartSpec.setWasOn(ctx, false)
            ctx.startService(Intent(ctx, LocmanVpnService::class.java).setAction(ACTION_STOP))
        }
    }

    private val worker = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "locman-vpn") }

    /** Сторож туннеля: свой поток, чтобы долгие проверки не мешали службе. */
    private val watcher = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "locman-watch") }
    private var watchdog: ScheduledFuture<*>? = null
    @Volatile private var watchGen = 0
    private var tun: ParcelFileDescriptor? = null
    private var monitor: ScheduledFuture<*>? = null
    private var lastText: String? = null

    override fun onCreate() {
        super.onCreate()
        VpnBus.app = applicationContext
        XrayEngine.init(this)
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Подключение", NotificationManager.IMPORTANCE_LOW))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            worker.execute { stopVpn() }
            return START_NOT_STICKY
        }
        val spec = StartSpec.load(this)
        startForegroundCompat(notification(spec?.name ?: "Лоцман", "Поднимаю туннель"))
        if (spec == null) {
            worker.execute { fail("Сначала подключитесь в приложении") }
            return START_NOT_STICKY
        }
        worker.execute { connect(spec) }
        return START_STICKY
    }

    private fun connect(spec: StartSpec) {
        val previous = tun
        tun = null
        teardown(closeTun = false)
        VpnBus.set(VpnState.Connecting(spec.name, spec.nodeId))

        val xrayTun = spec.tunMode == "xray"
        if (!xrayTun) {
            XrayEngine.start(spec.config).onFailure {
                runCatching { previous?.close() }
                return fail("Ядро не запустилось: ${it.message}")
            }
        }

        val builder = Builder()
            .setSession(spec.name)
            .setMtu(spec.mtu)
            .addAddress("10.10.14.1", 30)
            .addDnsServer("1.1.1.1")
        // Локальная сеть (роутер, камеры, принтеры) остаётся мимо туннеля, всё остальное — в туннель.
        Routes.publicIpv4().forEach { (addr, len) -> builder.addRoute(addr, len) }
        // IPv6 тоже заворачиваем, чтобы он не утекал мимо узла; DNS отдаёт только IPv4.
        runCatching { builder.addAddress("fd66:6c6f:6373::1", 126).addRoute("2000::", 3) }
        runCatching { builder.addDisallowedApplication(packageName) }
        spec.bypass.forEach { pkg -> runCatching { builder.addDisallowedApplication(pkg) } }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        val fd = runCatching { builder.establish() }.getOrNull()
        runCatching { previous?.close() }
        if (fd == null) return fail("Нет разрешения на VPN")
        tun = fd

        if (xrayTun) {
            XrayEngine.start(spec.config, fd.fd).onFailure {
                return fail("Ядро не запустилось: ${it.message}")
            }
        } else {
            TunBridge.start(this, fd.fd, spec.mtu, spec.socksPort, spec.user, spec.pass).onFailure {
                return fail("TUN не запустился: ${it.message}")
            }
        }
        val since = System.currentTimeMillis()
        VpnBus.set(VpnState.Connected(spec.name, spec.nodeId, since))
        StartSpec.setWasOn(this, true)
        update(spec.name, "Подключено")
        startMonitor(spec.name, xrayTun)
        startWatchdog(spec.nodeId, spec.testUrl)
        watchNetwork()
    }

    private var netCallback: ConnectivityManager.NetworkCallback? = null

    /** Следим за сменой сети: при переходе Wi-Fi ↔ мобильная режим сети может смениться. */
    private fun watchNetwork() {
        if (netCallback != null) return
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        var current: Network? = null
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val before = current
                current = network
                if (before != null && before != network) VpnBus.network()
            }
        }
        if (runCatching { cm.registerDefaultNetworkCallback(cb) }.isSuccess) netCallback = cb
    }

    private fun unwatchNetwork() {
        val cb = netCallback ?: return
        netCallback = null
        runCatching { getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(cb) }
    }

    /**
     * Каждые 20 секунд (при выключенном экране — раз в минуту) делаем запрос через сам туннель.
     * Два провала подряд — проверяем запасные узлы и переключаемся на первый живой.
     * Работает без открытого приложения.
     */
    private fun startWatchdog(nodeId: String, testUrl: String) {
        watchdog?.cancel(false)
        val gen = ++watchGen
        var fails = 0
        var tick = 0
        var stalledSince = 0L
        val power = getSystemService(android.os.PowerManager::class.java)
        watchdog = watcher.scheduleWithFixedDelay({
            if (gen != watchGen) return@scheduleWithFixedDelay
            tick++
            val screenOn = runCatching { power.isInteractive }.getOrDefault(true)
            if (!screenOn && tick % 3 != 0) return@scheduleWithFixedDelay
            val ok = XrayEngine.measureCurrent(testUrl) > 0 || XrayEngine.measureCurrent(PROBE_URL_2) > 0
            if (gen != watchGen) return@scheduleWithFixedDelay
            if (ok) {
                if (fails > 0 || stalledSince > 0) VpnBus.watch("alive", nodeId = nodeId)
                fails = 0
                stalledSince = 0
                return@scheduleWithFixedDelay
            }
            fails++
            if (fails < 2) return@scheduleWithFixedDelay
            // Запасные не дёргаем чаще раза в 2 минуты, если они уже не помогли.
            val now = System.currentTimeMillis()
            if (stalledSince > 0 && now - stalledSince < 120_000) return@scheduleWithFixedDelay
            if (!failover(gen)) {
                stalledSince = now
                update("Узел не отвечает", "Ищу рабочий — откройте «Лоцман», если не найдётся")
                VpnBus.watch("stalled", nodeId = nodeId)
            }
        }, 20, 20, TimeUnit.SECONDS)
    }

    /** Проверяем запасные параллельно, переключаемся на самый быстрый из ответивших. */
    private fun failover(gen: Int): Boolean {
        val spec = StartSpec.load(this) ?: return false
        val candidates = spec.backups.filter { it.nodeId != spec.nodeId }.take(10)
        if (candidates.isEmpty()) return false
        update(spec.name, "Узел не отвечает — проверяю запасные")
        val pool = Executors.newFixedThreadPool(5)
        val results = try {
            candidates.map { b -> b to pool.submit<Long> { XrayEngine.measureDelay(b.test, spec.testUrl) } }
                .map { (b, f) -> b to runCatching { f.get(15, TimeUnit.SECONDS) }.getOrDefault(-1L) }
        } finally {
            pool.shutdownNow()
        }
        if (gen != watchGen) return true
        val best = results.filter { it.second > 0 }.minByOrNull { it.second }?.first ?: return false
        val rest = spec.backups.filter { it.nodeId != best.nodeId }
        val next = spec.copy(config = best.config, name = best.name, nodeId = best.nodeId, backups = rest)
        StartSpec.save(this, next)
        VpnBus.watch("failover", name = best.name, nodeId = best.nodeId)
        worker.execute { connect(next) }
        return true
    }

    private fun startMonitor(name: String, xrayTun: Boolean) {
        var base: LongArray? = null
        var lastUp = -1L
        var lastDown = -1L
        var tick = 0
        var sumUp = 0L
        var sumDown = 0L
        val power = getSystemService(android.os.PowerManager::class.java)
        var asleep = false
        monitor = worker.scheduleWithFixedDelay({
            // При выключенном экране не считаем и не перерисовываем — бережём батарею.
            // Счётчики ядра копятся и догонят при включении.
            if (!runCatching { power.isInteractive }.getOrDefault(true)) {
                asleep = true
                return@scheduleWithFixedDelay
            }
            val woke = asleep
            asleep = false
            if (xrayTun) {
                var (up, down) = XrayEngine.trafficDelta()
                sumUp += up
                sumDown += down
                if (woke) {
                    // Накопленное за время сна — в итоги, но не в скорость.
                    up = 0L
                    down = 0L
                }
                VpnBus.traffic(up, down, sumUp, sumDown)
                if (tick++ % 5 == 0) update(name, "↓ ${rate(down)}   ↑ ${rate(up)}   за сеанс ${bytes(sumUp + sumDown)}")
                return@scheduleWithFixedDelay
            }
            val s = TunBridge.stats()?.takeIf { it.size >= 4 } ?: return@scheduleWithFixedDelay
            val b = base ?: longArrayOf(s[1], s[3]).also { base = it }
            val upTotal = (s[1] - b[0]).coerceAtLeast(0)
            val downTotal = (s[3] - b[1]).coerceAtLeast(0)
            val up = if (lastUp < 0 || woke) 0 else (s[1] - lastUp).coerceAtLeast(0)
            val down = if (lastDown < 0 || woke) 0 else (s[3] - lastDown).coerceAtLeast(0)
            lastUp = s[1]
            lastDown = s[3]
            VpnBus.traffic(up, down, upTotal, downTotal)
            if (tick++ % 5 == 0) update(name, "↓ ${rate(down)}   ↑ ${rate(up)}   за сеанс ${bytes(upTotal + downTotal)}")
        }, 1, 1, TimeUnit.SECONDS)
    }

    private fun teardown(closeTun: Boolean = true) {
        watchGen++
        watchdog?.cancel(false)
        watchdog = null
        monitor?.cancel(false)
        monitor = null
        if (closeTun) unwatchNetwork()
        TunBridge.stop()
        XrayEngine.stop()
        if (closeTun) {
            runCatching { tun?.close() }
            tun = null
        }
    }

    private fun stopVpn() {
        teardown()
        VpnBus.set(VpnState.Idle)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun fail(message: String) {
        teardown()
        StartSpec.setWasOn(this, false)
        VpnBus.set(VpnState.Failed(message))
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() {
        StartSpec.setWasOn(this, false)
        worker.execute { stopVpn() }
    }

    override fun onDestroy() {
        runCatching { worker.submit { teardown() }.get(3, TimeUnit.SECONDS) }
        worker.shutdown()
        watcher.shutdownNow()
        if (VpnBus.state !is VpnState.Failed) VpnBus.set(VpnState.Idle)
        super.onDestroy()
    }

    private fun notification(title: String, text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, LocmanVpnService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_locman)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null as android.graphics.drawable.Icon?, "Отключить", stop).build())
            .build()
    }

    private fun update(title: String, text: String) {
        val key = "$title\n$text"
        if (key == lastText) return
        lastText = key
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(title, text))
    }

    private fun startForegroundCompat(n: Notification) {
        lastText = null
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun rate(bps: Long): String = when {
        bps < 1024 -> "$bps Б/с"
        bps < 1024 * 1024 -> "${bps / 1024} КБ/с"
        else -> String.format("%.1f МБ/с", bps / 1048576.0)
    }

    private fun bytes(b: Long): String = when {
        b < 1024 * 1024 -> "${b / 1024} КБ"
        b < 1024L * 1024 * 1024 -> String.format("%.1f МБ", b / 1048576.0)
        else -> String.format("%.2f ГБ", b / 1073741824.0)
    }
}
