package app.locman

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.util.Size
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Сканер QR-кода внутри «Лоцмана»: камера (CameraX) + распознавание (ZXing), всё на телефоне.
 * Кадры никуда не сохраняются и не отправляются. Результат — текст в extra "text".
 */
class ScanActivity : ComponentActivity() {
    companion object {
        const val EXTRA_TEXT = "text"
        private const val REQ_CAMERA = 51
    }

    private val analyzer = Executors.newSingleThreadExecutor()
    private val done = AtomicBoolean(false)
    private lateinit var preview: PreviewView
    private val reader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true,
                DecodeHintType.CHARACTER_SET to "UTF-8",
            ),
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        preview = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
        root.addView(preview, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        val frame = android.view.View(this).apply {
            background = android.graphics.drawable.GradientDrawable().apply {
                setStroke(dp(3), Color.WHITE)
                cornerRadius = dp(20).toFloat()
                setColor(Color.TRANSPARENT)
            }
        }
        root.addView(frame, FrameLayout.LayoutParams(dp(260), dp(260), Gravity.CENTER))
        val hint = TextView(this).apply {
            text = "Наведите камеру на QR-код «Поделиться своими» с другого телефона"
            setTextColor(Color.WHITE)
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(24), dp(24), dp(24))
            setShadowLayer(6f, 0f, 0f, Color.BLACK)
        }
        root.addView(hint, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP).apply {
            topMargin = dp(48)
        })
        val close = TextView(this).apply {
            text = "Закрыть"
            setTextColor(Color.WHITE)
            textSize = 17f
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(16), dp(24), dp(16))
            background = android.graphics.drawable.GradientDrawable().apply {
                cornerRadius = dp(28).toFloat()
                setColor(0x66000000)
            }
            setOnClickListener { finish() }
        }
        root.addView(close, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
            bottomMargin = dp(48)
        })
        setContentView(root)

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), REQ_CAMERA)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_CAMERA) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            setResult(RESULT_CANCELED, Intent().putExtra("error", "camera"))
            finish()
        }
    }

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider = runCatching { future.get() }.getOrNull() ?: return@addListener finish()
            val shown = Preview.Builder().build().also { it.setSurfaceProvider(preview.surfaceProvider) }
            @Suppress("DEPRECATION")
            val analysis = ImageAnalysis.Builder()
                .setTargetResolution(Size(1280, 720))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            analysis.setAnalyzer(analyzer) { image -> decode(image) }
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, shown, analysis)
            }.onFailure { finish() }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun decode(image: ImageProxy) {
        try {
            if (done.get()) return
            val plane = image.planes[0]
            val buffer = plane.buffer
            val data = ByteArray(buffer.remaining()).also { buffer.get(it) }
            val stride = plane.rowStride
            val source = PlanarYUVLuminanceSource(data, stride, image.height, 0, 0, image.width, image.height, false)
            val text = try {
                reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
            } catch (_: NotFoundException) {
                // Камера могла дать перевёрнутую картинку — пробуем инверсию.
                runCatching { reader.decodeWithState(BinaryBitmap(HybridBinarizer(source.invert()))).text }.getOrNull()
            } finally {
                reader.reset()
            }
            if (!text.isNullOrBlank() && done.compareAndSet(false, true)) {
                runOnUiThread {
                    setResult(RESULT_OK, Intent().putExtra(EXTRA_TEXT, text))
                    finish()
                }
            }
        } catch (_: Exception) {
            // следующий кадр
        } finally {
            image.close()
        }
    }

    override fun onDestroy() {
        analyzer.shutdown()
        super.onDestroy()
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
}
