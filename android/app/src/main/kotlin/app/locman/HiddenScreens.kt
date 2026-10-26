package app.locman

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager

/**
 * Скрытые системные экраны настроек сети — то, что открывает код *#*#4636#*#*
 * («Информация о телефоне», выбор предпочтительного типа сети) и инженерное меню MediaTek.
 * На многих прошивках (realme, Xiaomi/HyperOS, Samsung) код не срабатывает, а сам экран есть.
 */
object HiddenScreens {
    data class Candidate(val pkg: String, val cls: String, val title: String)

    val candidates = listOf(
        Candidate("com.android.phone", "com.android.phone.settings.RadioInfo", "Информация о телефоне (Android 11+)"),
        Candidate("com.android.settings", "com.android.settings.RadioInfo", "Информация о телефоне (старые Android)"),
        Candidate("com.android.settings", "com.android.settings.Settings\$TestingSettingsActivity", "Меню тестирования"),
        Candidate("com.android.settings", "com.android.settings.TestingSettings", "Меню тестирования (старое)"),
        Candidate("com.mediatek.engineermode", "com.mediatek.engineermode.EngineerMode", "Инженерное меню MediaTek"),
    )

    /** available — есть и открыт; closed — есть, но закрыт (не exported или нужно разрешение); missing — нет. */
    fun status(ctx: Context, c: Candidate): Pair<String, String?> {
        val info = try {
            ctx.packageManager.getActivityInfo(ComponentName(c.pkg, c.cls), PackageManager.MATCH_DISABLED_COMPONENTS)
        } catch (_: PackageManager.NameNotFoundException) {
            return "missing" to null
        } catch (e: Exception) {
            return "missing" to e.message
        }
        if (!info.enabled || info.applicationInfo?.enabled == false) return "closed" to "экран выключен в прошивке"
        if (!info.exported) return "closed" to "экран закрыт для других приложений (exported=false)"
        val perm = info.permission
        if (perm != null && ctx.checkSelfPermission(perm) != PackageManager.PERMISSION_GRANTED) {
            return "closed" to "нужно системное разрешение $perm"
        }
        return "available" to null
    }

    fun list(ctx: Context): List<Map<String, Any?>> = candidates.map { c ->
        val (st, why) = status(ctx, c)
        mapOf("pkg" to c.pkg, "cls" to c.cls, "title" to c.title, "status" to st, "reason" to why)
    }

    /** null — открылось; иначе текст ошибки. */
    fun open(ctx: Context, pkg: String, cls: String): String? = try {
        ctx.startActivity(
            Intent(Intent.ACTION_MAIN).setComponent(ComponentName(pkg, cls)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        null
    } catch (e: ActivityNotFoundException) {
        "экрана нет в этой прошивке"
    } catch (e: SecurityException) {
        "прошивка не даёт открыть экран: ${e.message ?: "SecurityException"}"
    } catch (e: Exception) {
        e.message ?: e.javaClass.simpleName
    }
}
