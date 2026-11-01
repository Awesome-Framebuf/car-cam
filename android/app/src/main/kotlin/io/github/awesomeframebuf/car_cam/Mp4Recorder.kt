package io.github.awesomeframebuf.car_cam

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File

/**
 * Encodes JPEG frames to an H.264 MP4. Not thread-safe: call every method from
 * one background thread.
 */
class Mp4Recorder(private val output: File) {
    private var codec: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var track = -1
    private var muxerStarted = false
    private var width = 0
    private var height = 0
    private var pixels = IntArray(0)
    private var lastPtsUs = -1L
    private val info = MediaCodec.BufferInfo()

    var framesEncoded = 0
        private set

    fun addFrame(jpeg: ByteArray, ptsMs: Long) {
        val decoded = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return
        if (codec == null) start(decoded.width and 1.inv(), decoded.height and 1.inv())
        val bitmap = if (decoded.width == width && decoded.height == height) {
            decoded
        } else {
            Bitmap.createScaledBitmap(decoded, width, height, true)
        }
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        if (bitmap !== decoded) bitmap.recycle()
        decoded.recycle()

        val encoder = codec!!
        val index = dequeueInput(encoder)
        if (index < 0) return // The encoder is behind: drop this frame.
        val image = encoder.getInputImage(index) ?: return
        writeYuv(image)
        val ptsUs = maxOf(ptsMs * 1000, lastPtsUs + 1000)
        lastPtsUs = ptsUs
        encoder.queueInputBuffer(index, 0, width * height * 3 / 2, ptsUs, 0)
        framesEncoded++
        drain(endOfStream = false)
    }

    /** Finishes the file. Returns false if no video was written. */
    fun finish(): Boolean {
        val encoder = codec ?: return false
        var hasVideo = false
        try {
            val index = dequeueInput(encoder)
            if (index >= 0) {
                encoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                drain(endOfStream = true)
            }
            hasVideo = muxerStarted && framesEncoded > 0
        } finally {
            release()
        }
        return hasVideo
    }

    fun release() {
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        if (muxerStarted) runCatching { muxer?.stop() }
        runCatching { muxer?.release() }
        codec = null
        muxer = null
        muxerStarted = false
    }

    private fun start(w: Int, h: Int) {
        width = w
        height = h
        pixels = IntArray(w * h)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, maxOf(1_500_000, w * h * 16))
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply {
            configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            start()
        }
        muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    }

    private fun dequeueInput(encoder: MediaCodec): Int {
        val index = encoder.dequeueInputBuffer(TIMEOUT_US)
        if (index >= 0) return index
        drain(endOfStream = false)
        return encoder.dequeueInputBuffer(TIMEOUT_US)
    }

    private fun writeYuv(image: android.media.Image) {
        val (yPlane, uPlane, vPlane) = image.planes
        val y = yPlane.buffer
        val u = uPlane.buffer
        val v = vPlane.buffer
        for (row in 0 until height) {
            val rgbRow = row * width
            val yRow = row * yPlane.rowStride
            val uRow = (row / 2) * uPlane.rowStride
            val vRow = (row / 2) * vPlane.rowStride
            for (col in 0 until width) {
                val argb = pixels[rgbRow + col]
                val r = (argb shr 16) and 0xFF
                val g = (argb shr 8) and 0xFF
                val b = argb and 0xFF
                // BT.601 limited range.
                y.put(
                    yRow + col * yPlane.pixelStride,
                    (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).toByte(),
                )
                if (row % 2 == 0 && col % 2 == 0) {
                    val halfCol = col / 2
                    u.put(
                        uRow + halfCol * uPlane.pixelStride,
                        (((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128).toByte(),
                    )
                    v.put(
                        vRow + halfCol * vPlane.pixelStride,
                        (((112 * r - 94 * g - 18 * b + 128) shr 8) + 128).toByte(),
                    )
                }
            }
        }
    }

    private fun drain(endOfStream: Boolean) {
        val encoder = codec ?: return
        val deadline = System.nanoTime() + DRAIN_LIMIT_NS
        while (true) {
            val index = encoder.dequeueOutputBuffer(info, if (endOfStream) TIMEOUT_US else 0)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream || System.nanoTime() > deadline) return
                }
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    track = muxer!!.addTrack(encoder.outputFormat)
                    muxer!!.start()
                    muxerStarted = true
                }
                index >= 0 -> {
                    val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (!isConfig && info.size > 0 && muxerStarted) {
                        val data = encoder.getOutputBuffer(index)!!
                        data.position(info.offset)
                        data.limit(info.offset + info.size)
                        muxer!!.writeSampleData(track, data, info)
                    }
                    val done = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    encoder.releaseOutputBuffer(index, false)
                    if (done) return
                }
            }
        }
    }

    private companion object {
        const val TIMEOUT_US = 20_000L
        const val DRAIN_LIMIT_NS = 5_000_000_000L
    }
}
