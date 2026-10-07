package org.sp8esa.esp32_datv

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock

/**
 * Foreground service (type mediaProjection) that owns the MediaProjection, a VirtualDisplay
 * and an ImageReader (RGBA_8888, width <= maxWidth). Frames are throttled to the requested
 * rate, stripped of row padding and handed to [listener] on the capture thread.
 */
class ScreenCaptureService : Service() {

    interface Listener {
        fun onStarted(width: Int, height: Int)
        fun onError(message: String)
        fun onEnded(message: String)
        fun wantsFrame(): Boolean
        fun onFrame(data: ByteArray, width: Int, height: Int, stride: Int)
    }

    companion object {
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        const val EXTRA_WIDTH = "width"
        const val EXTRA_HEIGHT = "height"
        const val EXTRA_DPI = "dpi"
        const val EXTRA_MAX_WIDTH = "maxWidth"
        const val EXTRA_FPS = "fps"
        private const val CHANNEL_ID = "datv_screen_capture"
        private const val NOTIFICATION_ID = 0x5C4E

        @Volatile
        var listener: Listener? = null

        fun stop(context: Context) {
            context.stopService(Intent(context, ScreenCaptureService::class.java))
        }
    }

    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var periodNs = 66_000_000L
    private var lastNs = 0L
    private var stopping = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // must be in the foreground before getMediaProjection (Android 14)
        try {
            goForeground()
        } catch (e: Exception) {
            listener?.onError("Cannot start the capture service: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent == null) return START_NOT_STICKY
        try {
            if (projection != null) {
                // a new consent replaces the running projection
                stopping = true
                teardown()
            }
            stopping = false
            begin(intent)
        } catch (e: Exception) {
            listener?.onError("Screen capture failed: ${e.message}")
            stopping = true
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun goForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Screen capture", NotificationManager.IMPORTANCE_LOW)
            )
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("DATV")
            .setContentText("The screen is being transmitted")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun begin(intent: Intent) {
        val code = intent.getIntExtra(EXTRA_CODE, Activity.RESULT_CANCELED)
        val data: Intent = (if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<Intent>(EXTRA_DATA)
        }) ?: throw IllegalStateException("no projection data")
        val screenW = intent.getIntExtra(EXTRA_WIDTH, 1280)
        val screenH = intent.getIntExtra(EXTRA_HEIGHT, 720)
        val dpi = intent.getIntExtra(EXTRA_DPI, 160)
        val maxWidth = intent.getIntExtra(EXTRA_MAX_WIDTH, 960)
        val fps = intent.getIntExtra(EXTRA_FPS, 15).coerceIn(1, 60)
        periodNs = 1_000_000_000L / fps - 3_000_000L

        // keep the aspect ratio, even sizes
        var w = minOf(screenW, maxWidth)
        var h = (screenH.toLong() * w / screenW).toInt()
        w = w and 1.inv()
        h = h and 1.inv()
        if (w < 2 || h < 2) throw IllegalStateException("bad screen size ${screenW}x$screenH")

        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val p = mpm.getMediaProjection(code, data) ?: throw IllegalStateException("projection refused")
        projection = p
        val t = HandlerThread("datv-screen").also { it.start() }
        thread = t
        val handler = Handler(t.looper)
        // required before createVirtualDisplay on Android 14
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                if (!stopping) listener?.onEnded("Screen capture was stopped")
                stopping = true
                stopSelf()
            }
        }, handler)
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        reader = r
        r.setOnImageAvailableListener({ onImage(it) }, handler)
        display = p.createVirtualDisplay(
            "datv-screen", w, h, dpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, handler
        )
        listener?.onStarted(w, h)
    }

    private fun onImage(r: ImageReader) {
        val img = try {
            r.acquireLatestImage()
        } catch (e: Exception) {
            null
        } ?: return
        try {
            val l = listener ?: return
            val now = SystemClock.elapsedRealtimeNanos()
            if (now - lastNs < periodNs || !l.wantsFrame()) return
            lastNs = now
            val plane = img.planes[0]
            val buf = plane.buffer
            val w = img.width
            val h = img.height
            val rowBytes = w * 4
            val rowStride = plane.rowStride
            val out = ByteArray(rowBytes * h)
            if (rowStride == rowBytes && plane.pixelStride == 4) {
                buf.position(0)
                buf.get(out, 0, minOf(out.size, buf.remaining()))
            } else {
                // rows are padded to rowStride; the last row may lack its padding
                for (y in 0 until h) {
                    buf.position(y * rowStride)
                    buf.get(out, y * rowBytes, rowBytes)
                }
            }
            l.onFrame(out, w, h, rowBytes)
        } catch (e: Exception) {
            // a frame lost to a rotation or teardown race is harmless
        } finally {
            img.close()
        }
    }

    private fun teardown() {
        try {
            display?.release()
        } catch (e: Exception) {
        }
        try {
            reader?.close()
        } catch (e: Exception) {
        }
        try {
            projection?.stop()
        } catch (e: Exception) {
        }
        display = null
        reader = null
        projection = null
        thread?.quitSafely()
        thread = null
    }

    override fun onDestroy() {
        stopping = true
        teardown()
        super.onDestroy()
    }
}
