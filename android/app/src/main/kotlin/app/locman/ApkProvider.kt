package app.locman

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

/**
 * Отдаёт установленный APK «Лоцмана» напрямую из системы (только на чтение и только тому,
 * кому выдано разрешение через «Поделиться»). Копия в кэш не пишется, подписок и настроек
 * в APK нет.
 */
class ApkProvider : ContentProvider() {
    companion object {
        const val MIME = "application/vnd.android.package-archive"

        fun uri(ctx: Context): Uri = Uri.parse("content://${ctx.packageName}.apk/Locman.apk")
    }

    private fun apk(): File = File(context!!.applicationInfo.sourceDir)

    private fun name(): String {
        val ctx = context!!
        val v = runCatching { ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName }.getOrNull()
        return if (v.isNullOrBlank()) "Locman.apk" else "Locman-$v.apk"
    }

    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String = MIME

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        require(mode == "r") { "только чтение" }
        return ParcelFileDescriptor.open(apk(), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val row = cols.map {
            when (it) {
                OpenableColumns.DISPLAY_NAME -> name()
                OpenableColumns.SIZE -> apk().length()
                else -> null
            }
        }
        return MatrixCursor(cols, 1).apply { addRow(row) }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
