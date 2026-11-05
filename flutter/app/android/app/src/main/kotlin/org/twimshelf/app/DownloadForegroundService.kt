package org.twimshelf.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

class DownloadForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var title = ""
    private var body = ""
    private var channelName = ""
    private var total = 0
    private var done = 0
    override fun onCreate() {
        super.onCreate(); instance = this
    }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) { stopSelf(); return START_NOT_STICKY }
        title = intent.getStringExtra("title") ?: run { stopSelf(); return START_NOT_STICKY }
        body = intent.getStringExtra("body") ?: run { stopSelf(); return START_NOT_STICKY }
        channelName = intent.getStringExtra("channelName") ?: run { stopSelf(); return START_NOT_STICKY }
        total = intent.getIntExtra("total", 0).coerceAtLeast(0)
        done = intent.getIntExtra("done", 0).coerceIn(0, total)
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, channelName, NotificationManager.IMPORTANCE_LOW))
            startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            active = true
            if (wakeLock?.isHeld != true) {
                wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "twimshelf:downloads").also {
                        it.setReferenceCounted(false); it.acquire()
                    }
            }
            signalStarted(true)
        } catch (_: Exception) {
            signalStarted(false)
            stopSelf()
        }
        // Core persists interrupted jobs. Never silently restart a dead process
        // and attempt to open an unknown user library without its Dart owner.
        return START_NOT_STICKY
    }
    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title).setContentText(body).setContentIntent(open)
            .setCategory(Notification.CATEGORY_PROGRESS).setOnlyAlertOnce(true)
            .setOngoing(true).setShowWhen(false)
            .setProgress(total, done, total == 0).build()
    }
    private fun progress(data: Map<*, *>) {
        if (!active) return
        title = data["title"] as? String ?: title
        body = data["body"] as? String ?: body
        total = ((data["total"] as? Number)?.toInt() ?: total).coerceAtLeast(0)
        done = ((data["done"] as? Number)?.toInt() ?: done).coerceIn(0, total)
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIFICATION_ID, notification())
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android15+ dataSync quota: stop within the system deadline, then ask
        // the living Dart owner to durably pause the native download queue.
        stopping = true
        AndroidBackgroundBridge.channel?.invokeMethod("backgroundTimeout", null)
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }
    override fun onDestroy() {
        active = false
        signalStarted(false)
        wakeLock?.let { if (it.isHeld) it.release() }; wakeLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (instance === this) instance = null
        stopping = false
        val callbacks = stopped.toList(); stopped.clear()
        callbacks.forEach { it() }
        super.onDestroy()
    }
    companion object {
        private const val CHANNEL_ID = "downloads"
        private const val NOTIFICATION_ID = 8711
        @Volatile var active = false
            private set
        private var instance: DownloadForegroundService? = null
        @Volatile var stopping = false
            private set
        private val stopped = mutableListOf<() -> Unit>()
        fun requestStop(context: Context, complete: () -> Unit) {
            if (instance == null) { complete(); return }
            stopping = true; stopped.add(complete)
            context.stopService(Intent(context, DownloadForegroundService::class.java))
        }
        var started: ((Boolean) -> Unit)? = null
        private fun signalStarted(ok: Boolean) { val callback = started; started = null; callback?.invoke(ok) }
        fun update(data: Map<*, *>) {
            Handler(Looper.getMainLooper()).post { instance?.progress(data) }
        }
    }
}
