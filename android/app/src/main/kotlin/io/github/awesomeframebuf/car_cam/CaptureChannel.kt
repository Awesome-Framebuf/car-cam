package io.github.awesomeframebuf.car_cam

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Saves photos and videos to the phone's gallery for the Dart side. */
class CaptureChannel(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val queuedFrames = AtomicInteger(0)
    private var recorder: Mp4Recorder? = null
    private var tempFile: File? = null
    private var pendingPermission: ((Boolean) -> Unit)? = null

    init {
        MethodChannel(messenger, "car_cam/capture").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "savePhoto" -> withStorage(result) {
                val jpeg = call.arguments as ByteArray
                inBackground(result) {
                    save(isVideo = false) { it.write(jpeg) }
                    null
                }
            }
            "startRecording" -> withStorage(result) { startRecording(result) }
            "frame" -> {
                addFrame(call.argument<ByteArray>("jpeg")!!, call.argument<Number>("ptsMs")!!.toLong())
                result.success(null)
            }
            "stopRecording" -> stopRecording(result)
            "openWifiSettings" -> {
                activity.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                result.success(null)
            }
            "openAppSettings" -> {
                activity.startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:${activity.packageName}"),
                    ),
                )
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startRecording(result: MethodChannel.Result) {
        if (recorder != null) {
            result.error("already_recording", "Already recording", null)
            return
        }
        val file = File.createTempFile("recording", ".mp4", activity.cacheDir)
        tempFile = file
        recorder = Mp4Recorder(file)
        queuedFrames.set(0)
        result.success(null)
    }

    private fun addFrame(jpeg: ByteArray, ptsMs: Long) {
        val active = recorder ?: return
        if (queuedFrames.get() >= MAX_QUEUED_FRAMES) return
        queuedFrames.incrementAndGet()
        worker.execute {
            try {
                active.addFrame(jpeg, ptsMs)
            } catch (_: Exception) {
                // A bad frame shouldn't end the recording.
            } finally {
                queuedFrames.decrementAndGet()
            }
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        val active = recorder
        val file = tempFile
        recorder = null
        tempFile = null
        if (active == null || file == null) {
            result.error("not_recording", "Not recording", null)
            return
        }
        inBackground(result) {
            try {
                if (!active.finish()) throw IllegalStateException("No video was recorded")
                save(isVideo = true) { out -> file.inputStream().use { it.copyTo(out) } }
                mapOf("frames" to active.framesEncoded)
            } finally {
                file.delete()
            }
        }
    }

    private fun inBackground(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("save_failed", e.message, null) }
            }
        }
    }

    private fun save(isVideo: Boolean, write: (OutputStream) -> Unit) {
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val extension = if (isVideo) "mp4" else "jpg"
        val name = "CarCam_$stamp.$extension"
        val mime = if (isVideo) "video/mp4" else "image/jpeg"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveWithMediaStore(isVideo, name, mime, write)
        } else {
            saveToPublicFolder(isVideo, name, mime, write)
        }
    }

    private fun saveWithMediaStore(
        isVideo: Boolean,
        name: String,
        mime: String,
        write: (OutputStream) -> Unit,
    ) {
        val resolver = activity.contentResolver
        val collection = if (isVideo) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val folder = if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "$folder/$ALBUM")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Couldn't create the file")
        try {
            resolver.openOutputStream(uri)!!.use(write)
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }

    @Suppress("DEPRECATION")
    private fun saveToPublicFolder(
        isVideo: Boolean,
        name: String,
        mime: String,
        write: (OutputStream) -> Unit,
    ) {
        val folder = if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
        val directory = File(Environment.getExternalStoragePublicDirectory(folder), ALBUM)
        directory.mkdirs()
        val file = File(directory, name)
        FileOutputStream(file).use(write)
        MediaScannerConnection.scanFile(activity, arrayOf(file.path), arrayOf(mime), null)
    }

    // Android 9 and older need a permission to write to shared folders.
    private fun withStorage(result: MethodChannel.Result, action: () -> Unit) {
        val needsPermission = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        if (!needsPermission) {
            action()
            return
        }
        pendingPermission = { granted ->
            if (granted) action() else result.error("permission_denied", "Storage access denied", null)
        }
        activity.requestPermissions(
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            STORAGE_REQUEST,
        )
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != STORAGE_REQUEST) return
        pendingPermission?.invoke(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        pendingPermission = null
    }

    fun dispose() {
        val active = recorder
        val file = tempFile
        recorder = null
        tempFile = null
        worker.execute {
            active?.release()
            file?.delete()
        }
        worker.shutdown()
    }

    private companion object {
        const val ALBUM = "Car Cam"
        const val STORAGE_REQUEST = 4101
        const val MAX_QUEUED_FRAMES = 8
    }
}
