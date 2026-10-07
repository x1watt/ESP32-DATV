package org.sp8esa.esp32_datv

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

/**
 * Screen capture for the Dart side: MethodChannel "datv/screen" (start/stop) and
 * EventChannel "datv/screen/frames" (maps with data/w/h/stride, RGBA, or "ended").
 *
 * start: asks the user through the MediaProjection consent dialog, then starts
 * ScreenCaptureService (a mediaProjection foreground service, which must be running
 * before getMediaProjection on Android 14) that owns the projection.
 */
class ScreenCaptureChannel(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler, ScreenCaptureService.Listener {

    companion object {
        const val REQUEST_CODE = 0x5C4E
        private const val MAX_IN_FLIGHT = 2
    }

    private val method = MethodChannel(messenger, "datv/screen")
    private val events = EventChannel(messenger, "datv/screen/frames")
    private val main = Handler(Looper.getMainLooper())
    private val inFlight = AtomicInteger(0)
    private var sink: EventChannel.EventSink? = null
    private var pending: MethodChannel.Result? = null
    private var maxWidth = 960
    private var fps = 15

    init {
        method.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                if (pending != null) return result.error("busy", "A screen capture request is already open", null)
                maxWidth = call.argument<Int>("maxWidth") ?: 960
                fps = call.argument<Int>("fps") ?: 15
                val mpm = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                pending = result
                try {
                    @Suppress("DEPRECATION")
                    activity.startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST_CODE)
                } catch (e: Exception) {
                    pending = null
                    result.error("unavailable", "Screen capture is not available: ${e.message}", null)
                }
            }
            "stop" -> {
                ScreenCaptureService.listener = null
                ScreenCaptureService.stop(activity)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Called by MainActivity; returns true when the result was ours. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val r = pending ?: return true
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending = null
            r.error("denied", "Screen capture permission denied", null)
            return true
        }
        val (w, h, dpi) = screenSize()
        ScreenCaptureService.listener = this
        val intent = Intent(activity, ScreenCaptureService::class.java)
            .putExtra(ScreenCaptureService.EXTRA_CODE, resultCode)
            .putExtra(ScreenCaptureService.EXTRA_DATA, data)
            .putExtra(ScreenCaptureService.EXTRA_WIDTH, w)
            .putExtra(ScreenCaptureService.EXTRA_HEIGHT, h)
            .putExtra(ScreenCaptureService.EXTRA_DPI, dpi)
            .putExtra(ScreenCaptureService.EXTRA_MAX_WIDTH, maxWidth)
            .putExtra(ScreenCaptureService.EXTRA_FPS, fps)
        try {
            if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(intent) else activity.startService(intent)
        } catch (e: Exception) {
            pending = null
            ScreenCaptureService.listener = null
            r.error("service", "Cannot start the screen capture service: ${e.message}", null)
        }
        // the service answers through onStarted/onError
        return true
    }

    private fun screenSize(): Triple<Int, Int, Int> {
        val dpi = activity.resources.displayMetrics.densityDpi
        return if (Build.VERSION.SDK_INT >= 30) {
            val b = activity.windowManager.maximumWindowMetrics.bounds
            Triple(b.width(), b.height(), dpi)
        } else {
            val dm = DisplayMetrics()
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay.getRealMetrics(dm)
            Triple(dm.widthPixels, dm.heightPixels, dpi)
        }
    }

    // ------------------------------------------------------------ EventChannel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // ------------------------------------------------------------ service callbacks (any thread)

    override fun onStarted(width: Int, height: Int) {
        main.post {
            pending?.success(mapOf("w" to width, "h" to height))
            pending = null
        }
    }

    override fun onError(message: String) {
        main.post {
            ScreenCaptureService.listener = null
            val p = pending
            pending = null
            if (p != null) p.error("failed", message, null) else sink?.success(mapOf("ended" to message))
        }
    }

    override fun onEnded(message: String) {
        main.post {
            ScreenCaptureService.listener = null
            sink?.success(mapOf("ended" to message))
        }
    }

    override fun wantsFrame(): Boolean = inFlight.get() < MAX_IN_FLIGHT

    override fun onFrame(data: ByteArray, width: Int, height: Int, stride: Int) {
        inFlight.incrementAndGet()
        main.post {
            try {
                sink?.success(mapOf("data" to data, "w" to width, "h" to height, "stride" to stride))
            } finally {
                inFlight.decrementAndGet()
            }
        }
    }
}
