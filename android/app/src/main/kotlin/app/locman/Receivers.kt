package app.locman

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** После перезагрузки поднимаем туннель, если он был включён. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (StartSpec.wasOn(context)) runCatching { LocmanVpnService.restart(context) }
    }
}

/** Плитка в шторке: включить/выключить последний узел. */
class QsTileService : TileService() {
    private val listener: (Map<String, Any?>) -> Unit = { refresh() }

    override fun onStartListening() {
        super.onStartListening()
        VpnBus.listen(listener)
        refresh()
    }

    override fun onStopListening() {
        VpnBus.unlisten(listener)
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        val state = VpnBus.state
        if (state is VpnState.Connected || state is VpnState.Connecting) {
            LocmanVpnService.stop(this)
        } else if (!LocmanVpnService.restart(this)) {
            val open = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (android.os.Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(
                    android.app.PendingIntent.getActivity(this, 3, open, android.app.PendingIntent.FLAG_IMMUTABLE),
                )
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(open)
            }
        }
    }

    private fun refresh() {
        val tile = qsTile ?: return
        val state = VpnBus.state
        tile.state = if (state is VpnState.Connected) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "Лоцман"
        if (android.os.Build.VERSION.SDK_INT >= 29) {
            tile.subtitle = when (state) {
                is VpnState.Connected -> state.name
                is VpnState.Connecting -> "Подключение"
                else -> "Выключен"
            }
        }
        tile.updateTile()
    }
}
