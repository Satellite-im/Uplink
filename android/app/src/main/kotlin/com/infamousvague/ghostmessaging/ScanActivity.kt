package com.infamousvague.ghostmessaging

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.ImageReader
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Gravity
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.util.concurrent.Executor

/** Reading a QR code out of a camera frame's brightness (ZXing), apart from Android so it is tested (ScanTest). */
object Scan {
    private val hints = mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true)

    /** The words of the QR code in a frame of [width] by [height] brightness values, or null where there is none. */
    fun read(luminance: ByteArray, width: Int, height: Int): String? = try {
        QRCodeReader().decode(BinaryBitmap(HybridBinarizer(PlanarYUVLuminanceSource(luminance, width, height, 0, 0, width, height, false))), hints).text
    } catch (_: Exception) { null }
}

/**
 * The camera, looking for the QR code a computer shows to pair with (docs/desktop.md). The picture never leaves the
 * phone: each frame's brightness is read here by ZXing, and the first code that is one of ours ends the screen with
 * its words. Opened by `deskScan` (MainActivity); the camera permission is asked for here, the first time.
 */
class ScanActivity : Activity() {
    companion object {
        /** The result's extra holding the code's words. */
        const val RESULT_TEXT = "text"
        private const val TAG = "GhostDesk"
        private const val PERMISSION = 51
        /** What a new device's sign-in code starts with (HandoverCode.tag in lib/account/handover.dart). */
        private const val SIGN_IN_TAG = "GHOSTSIGNIN1:"
    }

    private lateinit var preview: TextureView
    private lateinit var hint: TextView
    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var background: Handler? = null
    /** The camera's picture size, as the sensor lies (wider than tall). */
    private var size = Size(1280, 720)
    /** When a frame was last looked through, in milliseconds: frames sooner than 120 ms after are let go. */
    private var lastRead = 0L
    @Volatile private var finished = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        preview = TextureView(this)
        hint = TextView(this).apply {
            text = "Point the camera at the code on the other screen"
            setTextColor(Color.WHITE)
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(48, 32, 48, 32)
            setBackgroundColor(0x99000000.toInt())
        }
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        root.addView(preview, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        root.addView(hint, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply { bottomMargin = 160 })
        setContentView(root)
    }

    override fun onResume() {
        super.onResume()
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), PERMISSION)
            return
        }
        thread = HandlerThread("ghost-scan").also { it.start(); background = Handler(it.looper) }
        if (preview.isAvailable) open() else preview.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(s: SurfaceTexture, w: Int, h: Int) = open()
            override fun onSurfaceTextureSizeChanged(s: SurfaceTexture, w: Int, h: Int) = fit()
            override fun onSurfaceTextureDestroyed(s: SurfaceTexture) = true
            override fun onSurfaceTextureUpdated(s: SurfaceTexture) {}
        }
    }

    override fun onPause() {
        try { session?.close() } catch (_: Exception) {}
        try { camera?.close() } catch (_: Exception) {}
        try { reader?.close() } catch (_: Exception) {}
        session = null; camera = null; reader = null
        thread?.quitSafely(); thread = null; background = null
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode != PERMISSION) return
        // Granted: onResume runs again as the permission sheet leaves, and opens the camera. Refused: nothing to scan with.
        if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) {
            setResult(RESULT_CANCELED, Intent().putExtra("denied", true))
            finish()
        }
    }

    /** Opens the back camera (or the only one), on the scanning thread, at the size nearest 1280 by 720. */
    private fun open() {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        try {
            val id = manager.cameraIdList.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK }
                ?: manager.cameraIdList.firstOrNull() ?: return fail("This phone has no camera to scan with.")
            val map = manager.getCameraCharacteristics(id).get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            // About 1280 by 720: enough to read a code across a desk, and quick to look through.
            size = map?.getOutputSizes(SurfaceTexture::class.java)?.filter { it.width <= 1920 && it.height <= 1080 }
                ?.minByOrNull { Math.abs(it.width * it.height - 1280 * 720) } ?: Size(1280, 720)
            if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) { camera = device; start(device) }
                override fun onDisconnected(device: CameraDevice) { device.close(); camera = null }
                override fun onError(device: CameraDevice, error: Int) { device.close(); camera = null; fail("The camera could not be opened.") }
            }, background)
        } catch (e: Exception) {
            Log.e(TAG, "camera", e)
            fail("The camera could not be opened.")
        }
    }

    /** Sends the camera's frames two ways: to the screen, and to a reader whose frames are searched for a code. */
    private fun start(device: CameraDevice) {
        try {
            val texture = preview.surfaceTexture ?: return
            texture.setDefaultBufferSize(size.width, size.height)
            runOnUiThread { fit() }
            val surface = Surface(texture)
            val frames = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
            reader = frames
            frames.setOnImageAvailableListener({ r ->
                val image = try { r.acquireLatestImage() } catch (_: Exception) { null } ?: return@setOnImageAvailableListener
                try {
                    val now = System.currentTimeMillis()
                    if (finished || now - lastRead < 120) return@setOnImageAvailableListener
                    lastRead = now
                    // The brightness plane, without the padding some cameras put at the end of each row.
                    val plane = image.planes[0]
                    val w = image.width
                    val h = image.height
                    val luminance = ByteArray(w * h)
                    val buffer = plane.buffer
                    if (plane.rowStride == w) buffer.get(luminance, 0, minOf(buffer.remaining(), w * h))
                    else for (row in 0 until h) { buffer.position(row * plane.rowStride); buffer.get(luminance, row * w, minOf(w, buffer.remaining())) }
                    val text = Scan.read(luminance, w, h)
                    // A computer's pairing code, or a new device's sign-in code (GMFB-45; lib/account/handover.dart):
                    // whoever opened the camera tells the two apart.
                    if (text != null && (DeskCrypto.isOffer(text) || text.trim().startsWith(SIGN_IN_TAG))) found(text)
                    else if (text != null) runOnUiThread { hint.text = "That code isn't one of Uplink's" }
                } catch (e: Exception) { Log.w(TAG, "frame", e) } finally { image.close() }
            }, background)
            val request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(surface)
                addTarget(frames.surface)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            }
            val executor = Executor { background?.post(it) }
            device.createCaptureSession(SessionConfiguration(SessionConfiguration.SESSION_REGULAR, listOf(OutputConfiguration(surface), OutputConfiguration(frames.surface)), executor,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) {
                        session = s
                        try { s.setRepeatingRequest(request.build(), null, background) } catch (e: Exception) { Log.e(TAG, "preview", e) }
                    }
                    override fun onConfigureFailed(s: CameraCaptureSession) = fail("The camera could not be started.")
                }))
        } catch (e: Exception) {
            Log.e(TAG, "camera session", e)
            fail("The camera could not be started.")
        }
    }

    /** Draws the camera's picture filling the screen without stretching it, whichever way the phone is held. */
    private fun fit() {
        val vw = preview.width.toFloat()
        val vh = preview.height.toFloat()
        if (vw == 0f || vh == 0f) return
        @Suppress("DEPRECATION")
        val rotation = windowManager.defaultDisplay.rotation
        val matrix = Matrix()
        val cx = vw / 2
        val cy = vh / 2
        if (rotation == Surface.ROTATION_90 || rotation == Surface.ROTATION_270) {
            val view = RectF(0f, 0f, vw, vh)
            val buffer = RectF(0f, 0f, size.height.toFloat(), size.width.toFloat())
            buffer.offset(cx - buffer.centerX(), cy - buffer.centerY())
            matrix.setRectToRect(view, buffer, Matrix.ScaleToFit.FILL)
            val scale = maxOf(vh / size.height, vw / size.width)
            matrix.postScale(scale, scale, cx, cy)
            matrix.postRotate(90f * (rotation - 2), cx, cy)
        } else {
            // Upright, the camera's picture is its height wide and its width tall.
            val scale = maxOf(vw / size.height, vh / size.width)
            matrix.setScale(size.height * scale / vw, size.width * scale / vh, cx, cy)
            if (rotation == Surface.ROTATION_180) matrix.postRotate(180f, cx, cy)
        }
        preview.setTransform(matrix)
    }

    /** A pairing code was read: the screen ends with it, once, whatever later frames hold. */
    private fun found(text: String) {
        if (finished) return
        finished = true
        runOnUiThread {
            setResult(RESULT_OK, Intent().putExtra(RESULT_TEXT, text))
            finish()
        }
    }

    /** Says what went wrong where the hint was; the screen stays until the person goes back. */
    private fun fail(why: String) {
        runOnUiThread { hint.text = why }
    }
}
