package app.locman

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private companion object {
        const val REQ_VPN = 41
        const val REQ_NOTIFY = 42
    }

    private val main = Handler(Looper.getMainLooper())
    private val background = Executors.newFixedThreadPool(48) { r -> Thread(r, "locman-call").apply { isDaemon = true } }
    private var pendingPrepare: MethodChannel.Result? = null
    private var sinkListener: ((Map<String, Any?>) -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        XrayEngine.init(applicationContext)
        VpnBus.app = applicationContext
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "locman/core").setMethodCallHandler(::onCall)
        EventChannel(messenger, "locman/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val l: (Map<String, Any?>) -> Unit = { events.success(it) }
                sinkListener?.let { VpnBus.unlisten(it) }
                sinkListener = l
                VpnBus.listen(l)
            }

            override fun onCancel(arguments: Any?) {
                sinkListener?.let { VpnBus.unlisten(it) }
                sinkListener = null
            }
        })
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        takeLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        takeLink(intent)
    }

    /** locman://import?url=https://… или locman://import/https://… — добавить подписку или ключ. */
    private fun takeLink(intent: Intent?) {
        val data = intent?.data ?: return
        if (intent.action != Intent.ACTION_VIEW || data.scheme != "locman" || data.host != "import") return
        val raw = data.toString()
        if (raw.length > 4200) return
        val value = runCatching { data.getQueryParameter("url") }.getOrNull()
            ?: raw.substringAfter("://import", "").trimStart('/').takeIf { it.isNotEmpty() }
            ?: return
        VpnBus.link(value)
    }

    override fun onDestroy() {
        sinkListener?.let { VpnBus.unlisten(it) }
        sinkListener = null
        super.onDestroy()
    }

    /** Долгую работу уводим с главного потока, ответ возвращаем на него. */
    private fun async(result: MethodChannel.Result, work: () -> Any?) {
        background.execute {
            val outcome = runCatching(work)
            main.post {
                outcome.fold({ result.success(it) }, { result.error("native", it.message ?: it.javaClass.simpleName, null) })
            }
        }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "info" -> {
                val pkg = packageManager.getPackageInfo(packageName, 0)
                @Suppress("DEPRECATION")
                val code = if (Build.VERSION.SDK_INT >= 28) pkg.longVersionCode.toInt() else pkg.versionCode
                async(result) {
                    mapOf(
                        "filesDir" to filesDir.absolutePath,
                        "cacheDir" to cacheDir.absolutePath,
                        "versionName" to (pkg.versionName ?: "1.0.0"),
                        "versionCode" to code,
                        "xray" to XrayEngine.version,
                        "abis" to Build.SUPPORTED_ABIS.toList(),
                        "smoke" to (intent?.getBooleanExtra("smoke", false) ?: false),
                        "skin" to intent?.getStringExtra("skin"),
                        "tun" to intent?.getStringExtra("tun"),
                        "extDir" to getExternalFilesDir(null)?.absolutePath,
                        "model" to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
                        "release" to Build.VERSION.RELEASE,
                    )
                }
            }

            "prepare" -> {
                val intent = VpnService.prepare(this)
                if (intent == null) {
                    result.success(true)
                } else {
                    pendingPrepare?.success(false)
                    pendingPrepare = result
                    try {
                        startActivityForResult(intent, REQ_VPN)
                    } catch (e: ActivityNotFoundException) {
                        pendingPrepare = null
                        result.success(false)
                    }
                }
            }

            "notifications" -> {
                if (Build.VERSION.SDK_INT >= 33 &&
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
                }
                result.success(null)
            }

            "start" -> {
                val spec = StartSpec(
                    config = call.argument<String>("config")!!,
                    name = call.argument<String>("name") ?: "Лоцман",
                    nodeId = call.argument<String>("nodeId") ?: "",
                    socksPort = call.argument<Int>("socksPort")!!,
                    httpPort = call.argument<Int>("httpPort") ?: 0,
                    user = call.argument<String>("user")!!,
                    pass = call.argument<String>("pass")!!,
                    bypass = call.argument<List<String>>("bypass") ?: emptyList(),
                    mtu = call.argument<Int>("mtu") ?: 1500,
                    tunMode = call.argument<String>("tunMode") ?: "xray",
                    backups = Backup.fromMaps(call.argument<List<Map<String, Any?>>>("backups")),
                    testUrl = call.argument<String>("testUrl") ?: DEFAULT_TEST_URL,
                )
                try {
                    LocmanVpnService.start(this, spec)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("start", e.message, null)
                }
            }

            "setBackups" -> {
                val backups = Backup.fromMaps(call.argument<List<Map<String, Any?>>>("backups"))
                StartSpec.load(this)?.let { StartSpec.save(this, it.copy(backups = backups)) }
                result.success(null)
            }

            "stop" -> {
                LocmanVpnService.stop(this)
                result.success(null)
            }

            "state" -> {
                val map = VpnBus.state.toMap().toMutableMap()
                if (VpnBus.state is VpnState.Connected) {
                    StartSpec.load(this)?.let {
                        map["socksPort"] = it.socksPort
                        map["httpPort"] = it.httpPort
                        map["user"] = it.user
                        map["pass"] = it.pass
                    }
                }
                result.success(map)
            }

            "measure" -> {
                val config = call.argument<String>("config")!!
                val url = call.argument<String>("url")!!
                async(result) { XrayEngine.measureDelay(config, url).toInt() }
            }

            "probeStart" -> {
                val config = call.argument<String>("config")!!
                async(result) { XrayEngine.startProbe(config) }
            }

            "probeStop" -> {
                val id = call.argument<Int>("id")!!
                async(result) { XrayEngine.stopProbe(id); null }
            }

            "takeLink" -> {
                val link = VpnBus.pendingLink
                VpnBus.pendingLink = null
                result.success(link)
            }

            "battery" -> {
                val bm = getSystemService(android.os.BatteryManager::class.java)
                val level = runCatching { bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY) }.getOrDefault(-1)
                result.success(mapOf("level" to level, "charging" to bm.isCharging))
            }

            "apps" -> async(result) { Apps.list(this) }

            "appIcon" -> {
                val pkg = call.argument<String>("package")!!
                async(result) { icon(pkg) }
            }

            "batteryRestricted" -> {
                val pm = getSystemService(PowerManager::class.java)
                result.success(!pm.isIgnoringBatteryOptimizations(packageName))
            }

            "openBattery" -> {
                open(
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")),
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
                )
                result.success(null)
            }

            "openAutostart" -> {
                open(
                    Intent().setComponent(
                        ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
                    ),
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")),
                )
                result.success(null)
            }

            "openVpnSettings" -> {
                open(Intent(Settings.ACTION_VPN_SETTINGS), Intent(Settings.ACTION_WIRELESS_SETTINGS))
                result.success(null)
            }

            "openUrl" -> {
                open(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url")!!)))
                result.success(null)
            }

            "verifyApk" -> {
                val path = call.argument<String>("path")!!
                val sha = call.argument<String>("sha256")!!
                val code = call.argument<Int>("versionCode")!!
                async(result) { Updater.verify(this, File(path), sha, code) }
            }

            "installApk" -> {
                val path = call.argument<String>("path")!!
                result.success(Updater.install(this, File(path)))
            }

            else -> result.notImplemented()
        }
    }

    private fun open(vararg intents: Intent) {
        for (intent in intents) {
            try {
                startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (_: Exception) {
            }
        }
    }

    private fun icon(pkg: String): ByteArray? = runCatching {
        val d = packageManager.getApplicationIcon(pkg)
        val size = 96
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        d.setBounds(0, 0, size, size)
        d.draw(canvas)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        out.toByteArray()
    }.getOrNull()

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN) {
            val r = pendingPrepare
            pendingPrepare = null
            r?.success(resultCode == RESULT_OK && VpnService.prepare(this) == null)
        }
    }
}
