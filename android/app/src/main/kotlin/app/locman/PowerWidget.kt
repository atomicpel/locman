package app.locman

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/** Виджет 1×1 на рабочем столе: включает и выключает VPN, не открывая приложение. */
class PowerWidget : AppWidgetProvider() {
    companion object {
        private const val ACTION_TOGGLE = "app.locman.action.WIDGET_TOGGLE"

        fun refresh(ctx: Context) {
            val manager = AppWidgetManager.getInstance(ctx) ?: return
            val ids = runCatching { manager.getAppWidgetIds(ComponentName(ctx, PowerWidget::class.java)) }.getOrNull()
            if (ids == null || ids.isEmpty()) return
            manager.updateAppWidget(ids, views(ctx))
        }

        private fun views(ctx: Context): RemoteViews {
            val v = RemoteViews(ctx.packageName, R.layout.locman_widget)
            val bg = when (VpnBus.state) {
                is VpnState.Connected -> R.drawable.locman_widget_on
                is VpnState.Connecting -> R.drawable.locman_widget_wait
                else -> R.drawable.locman_widget_off
            }
            v.setInt(R.id.widget_button, "setBackgroundResource", bg)
            val toggle = PendingIntent.getBroadcast(
                ctx, 11,
                Intent(ctx, PowerWidget::class.java).setAction(ACTION_TOGGLE),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            v.setOnClickPendingIntent(R.id.widget_root, toggle)
            return v
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        manager.updateAppWidget(ids, views(context))
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_TOGGLE) return
        val state = VpnBus.state
        if (state is VpnState.Connected || state is VpnState.Connecting) {
            LocmanVpnService.stop(context)
        } else if (!LocmanVpnService.restart(context)) {
            // Нет разрешения на VPN или ещё ни разу не подключались — откроем приложение.
            runCatching {
                context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
    }
}
