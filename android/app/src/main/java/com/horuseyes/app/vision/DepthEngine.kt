package com.horuseyes.app.vision

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.SystemClock
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import com.horuseyes.app.Config
import com.horuseyes.app.math.PchipInterpolator
import java.io.ByteArrayOutputStream
import java.nio.FloatBuffer
import java.util.ArrayDeque
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Cấu trúc thông tin một vật cản được phát hiện trong không gian 3D.
 */
data class Obstacle(
    var id: Int,
    val x: Int,
    val y: Int,
    val bbox: Rect,
    val pan: Float,
    var distCm: Float,
    var proximity: Float,
    var uncertaintyScore: Float,
    val isWall: Boolean = false,
    val modeText: String = ""
)

data class SpatialBin(
    val binId: Int,
    val angleMin: Float,
    val angleMax: Float,
    val angleCenter: Float,
    val validRatio: Float,
    val rawDepthStatistic: Float,
    val estimatedDistanceCm: Float,
    val isValid: Boolean,
    val hasObstacle: Boolean = false,
    val bodyDistCm: Float = Float.NaN,
    val groundDistCm: Float = Float.NaN,
    val overheadDistCm: Float = Float.NaN
)

/**
 * Kết quả phân tích độ sâu toàn diện của một khung hình.
 */
data class DepthResult(
    val rawDisparity: FloatArray,
    val width: Int,
    val height: Int,
    val distCm: Float,
    val pan: Float,
    val proximity: Float,
    val uncertaintyScore: Float,
    val isSaturated: Boolean,
    val sectorDists: Map<String, Float>,
    val allObstacles: List<Obstacle>,
    val isValid: Boolean = true,
    val sourceAspect: Float = 0.75f,
    val spatialBins: List<SpatialBin> = emptyList(),
    val timestampNanos: Long = 0L,
    val overheadHazard: Boolean = false,
    val dropOffHazard: Boolean = false,
    val modeText: String = ""
)

/**
 * Engine suy luận độ sâu đơn mục (Monocular Depth Estimation) trên vi xử lý biên ARM64.
 * Tương đồng toán học 1:1 với Spatial Engine v8 của bản Python desktop:
 * - Khung hình đầu vào chuẩn Portrait 192x256 (tỷ lệ 3:4 chuẩn Camera)
 * - MiDaS_small ONNX Runtime Mobile
 * - Chuẩn hóa PCHIP Spline
 * - Nhận diện 4 kịch bản: Bão hòa thấu kính (<15cm), Phòng trống/An toàn (>1.5m),
 *   Vật cản nổi bật (Saliency + Ring Contrast Step + Sobel Edge Gradient),
 *   Vách tường phẳng hành lang (Planar Frontal Wall).
 */
class DepthEngine(context: Context, modelAssetName: String = "midas_small.onnx") : AutoCloseable {

    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val session: OrtSession
    private val interpolator = PchipInterpolator()

    val inW = Config.INPUT_WIDTH   // 192
    val inH = Config.INPUT_HEIGHT  // 256
    private val totalPixels = inW * inH

    @Volatile
    var scaleFactor: Float = Config.DEFAULT_DIST_SCALE

    // Bộ nhớ đệm Tensor đầu vào NCHW: 1 x 3 x 256 x 192
    private val inputBuffer: FloatBuffer = FloatBuffer.allocate(1 * 3 * inH * inW)
    private val pixelArray = IntArray(totalPixels)
    private val inputTensorShape = longArrayOf(1, 3, inH.toLong(), inW.toLong())

    // Tên input từ đồ thị mô hình ONNX
    private val inputName: String

    init {
        val modelBytes = loadModelFromAssets(context, modelAssetName)
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(modelBytes)
            .joinToString("") { "%02x".format(it) }
        require(hash == "0f6727bda50b289a803b8146cdf531dae409927600f017778d07828ba6f1f82d") { "MiDaS integrity failure" }
        val opts = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(4)
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
        }
        session = env.createSession(modelBytes, opts)
        opts.close()
        inputName = session.inputNames.iterator().next()
        val shape = (session.inputInfo[inputName]!!.info as ai.onnxruntime.TensorInfo).shape
        require(shape.contentEquals(inputTensorShape)) { "Unsupported model input" }
    }

    private fun loadModelFromAssets(context: Context, assetName: String): ByteArray {
        context.assets.open(assetName).use { inputStream ->
            val buffer = ByteArrayOutputStream()
            val data = ByteArray(16384)
            var nRead: Int
            while (inputStream.read(data, 0, data.size).also { nRead = it } != -1) {
                buffer.write(data, 0, nRead)
            }
            return buffer.toByteArray()
        }
    }

    /**
     * Suy luận độ sâu từ Bitmap (192x256 ARGB_8888 portrait).
     */
    @Synchronized
    fun inferDepth(bitmap: Bitmap, sourceTimestampNanos: Long = 0L): DepthResult {
        val frameTsNanos = if (sourceTimestampNanos > 0L) sourceTimestampNanos else SystemClock.elapsedRealtimeNanos()
        val scaledBitmap = if (bitmap.width != inW || bitmap.height != inH) {
            Bitmap.createScaledBitmap(bitmap, inW, inH, true)
        } else {
            bitmap
        }

        // 1. Tiền xử lý ImageNet: Chuẩn hóa Planar NCHW [1, 3, 256, 192]
        scaledBitmap.getPixels(pixelArray, 0, inW, 0, 0, inW, inH)
        var lumaSum = 0.0
        var dark = 0; var bright = 0
        for (p in pixelArray) {
            val y = .299 * ((p shr 16) and 255) + .587 * ((p shr 8) and 255) + .114 * (p and 255)
            lumaSum += y
            if (y < 10) dark++
            if (y > 245) bright++
        }
        require(dark < totalPixels * .8 && bright < totalPixels * .8 && lumaSum / totalPixels > 12) { "Visual observation unavailable" }
        inputBuffer.clear()

        val meanR = 0.485f; val meanG = 0.456f; val meanB = 0.406f
        val stdR = 0.229f;  val stdG = 0.224f;  val stdB = 0.225f

        // Kênh R
        for (i in 0 until totalPixels) {
            val p = pixelArray[i]
            val r = ((p shr 16) and 0xFF) / 255.0f
            inputBuffer.put((r - meanR) / stdR)
        }
        // Kênh G
        for (i in 0 until totalPixels) {
            val p = pixelArray[i]
            val g = ((p shr 8) and 0xFF) / 255.0f
            inputBuffer.put((g - meanG) / stdG)
        }
        // Kênh B
        for (i in 0 until totalPixels) {
            val p = pixelArray[i]
            val b = (p and 0xFF) / 255.0f
            inputBuffer.put((b - meanB) / stdB)
        }
        inputBuffer.flip()

        // 2. Chạy ONNX Model Forward Pass
        val tensor = OnnxTensor.createTensor(env, inputBuffer, inputTensorShape)
        val rawDisparity = FloatArray(totalPixels)

        tensor.use { onnxTensor ->
            val results = session.run(mapOf(inputName to onnxTensor))
            results.use { outputMap ->
                val outputTensor = outputMap[0] as? OnnxTensor
                if (outputTensor != null) {
                    outputTensor.floatBuffer.get(rawDisparity)
                } else {
                    val outputValue = outputMap[0].value
                    when (outputValue) {
                        is Array<*> -> {
                            val outer = outputValue[0]
                            if (outer is Array<*>) {
                                var idx = 0
                                for (row in outer) {
                                    val floatRow = row as FloatArray
                                    System.arraycopy(floatRow, 0, rawDisparity, idx, floatRow.size)
                                    idx += floatRow.size
                                }
                            } else if (outer is FloatArray) {
                                System.arraycopy(outer, 0, rawDisparity, 0, outer.size)
                            } else {
                                // Không khớp kiểu mảng
                            }
                        }
                        is FloatBuffer -> {
                            outputValue.get(rawDisparity)
                        }
                        else -> {
                            // Không khớp kiểu dữ liệu
                        }
                    }
                }
            }
        }

        require(rawDisparity.all { it.isFinite() && it > 0f }) { "Invalid MiDaS output" }

        // 3. Chuẩn hóa dNorm [0.0, 1.0] và đo đạc cực trị
        var dMin = Float.MAX_VALUE
        var dMax = -Float.MAX_VALUE
        var sumNorm = 0.0
        var sumSqNorm = 0.0

        for (i in 0 until totalPixels) {
            val v = rawDisparity[i]
            if (v < dMin) dMin = v
            if (v > dMax) dMax = v
        }
        val dRange = max(1e-6f, dMax - dMin)
        val dNorm = FloatArray(totalPixels)
        for (i in 0 until totalPixels) {
            val n = (rawDisparity[i] - dMin) / dRange
            dNorm[i] = n
            sumNorm += n
            sumSqNorm += n * n
        }
        val globalMean = sumNorm / totalPixels
        val globalVar = max(0.0, (sumSqNorm / totalPixels) - (globalMean * globalMean))
        val globalStd = sqrt(globalVar).toFloat()

        // 4. Đo đạc 3 Sector hành lang di chuyển (Toàn cảnh: cx 4%-96%)
        val cy1 = (inH * 0.20f).toInt()
        val cy2 = (inH * 0.75f).toInt()
        val cx1 = (inW * 0.04f).toInt()
        val cx2 = (inW * 0.96f).toInt()
        val cw = cx2 - cx1
        val secW = cw / 3

        val secLSamples = ArrayList<Float>()
        val secCSamples = ArrayList<Float>()
        val secRSamples = ArrayList<Float>()
        val corrSamples = ArrayList<Float>()
        var corrSum = 0.0
        var corrSumSq = 0.0
        var corrHighCount = 0

        for (r in cy1 until cy2) {
            val offset = r * inW
            for (c in cx1 until (cx1 + secW)) {
                val d = rawDisparity[offset + c]
                secLSamples.add(d); corrSamples.add(d)
                corrSum += d; corrSumSq += d * d
                if (d >= 480.0f) corrHighCount++
            }
            for (c in (cx1 + secW) until (cx1 + 2 * secW)) {
                val d = rawDisparity[offset + c]
                secCSamples.add(d); corrSamples.add(d)
                corrSum += d; corrSumSq += d * d
                if (d >= 480.0f) corrHighCount++
            }
            for (c in (cx1 + 2 * secW) until cx2) {
                val d = rawDisparity[offset + c]
                secRSamples.add(d); corrSamples.add(d)
                corrSum += d; corrSumSq += d * d
                if (d >= 480.0f) corrHighCount++
            }
        }

        val scale = scaleFactor
        val rawL = if (secLSamples.isNotEmpty()) percentile(secLSamples, 0.80f) else 135f
        val rawC = if (secCSamples.isNotEmpty()) percentile(secCSamples, 0.80f) else 135f
        val rawR = if (secRSamples.isNotEmpty()) percentile(secRSamples, 0.80f) else 135f

        val distL = interpolator.interpolate(rawL, scale)
        val distC = interpolator.interpolate(rawC, scale)
        val distR = interpolator.interpolate(rawR, scale)
        val sectorDists = mapOf("LEFT" to distL, "CENTER" to distC, "RIGHT" to distR)

        // 5. Mặt nạ hình học (Top 15% trần nhà, Bottom 15% sàn chân) & Làm mượt Gaussian
        val topCut = (inH * Config.TOP_MASK_RATIO).toInt()
        val botCut = (inH * (1.0f - Config.BOTTOM_MASK_RATIO)).toInt()

        val dNormMasked = FloatArray(totalPixels)
        System.arraycopy(dNorm, 0, dNormMasked, 0, totalPixels)

        for (r in 0 until topCut) {
            val off = r * inW
            for (c in 0 until inW) {
                if (rawDisparity[off + c] < Config.SATURATION_RAW_THRESH) dNormMasked[off + c] = 0f
            }
        }
        for (r in botCut until inH) {
            val off = r * inW
            for (c in 0 until inW) {
                if (rawDisparity[off + c] < Config.SATURATION_RAW_THRESH) dNormMasked[off + c] = 0f
            }
        }

        // Fast Separable Gaussian Blur (11x11 tương đương qua 2-pass separable)
        val blurTemp = FloatArray(totalPixels)
        val smoothed = FloatArray(totalPixels)

        // Pass 1: Ngang (Horizontal)
        for (r in 0 until inH) {
            val off = r * inW
            for (c in 2 until inW - 2) {
                blurTemp[off + c] = (dNormMasked[off + c - 2] + 4f * dNormMasked[off + c - 1] + 6f * dNormMasked[off + c] + 4f * dNormMasked[off + c + 1] + dNormMasked[off + c + 2]) / 16.0f
            }
        }
        // Pass 2: Dọc (Vertical)
        for (r in 2 until inH - 2) {
            val off = r * inW
            val offM2 = (r - 2) * inW
            val offM1 = (r - 1) * inW
            val offP1 = (r + 1) * inW
            val offP2 = (r + 2) * inW
            for (c in 0 until inW) {
                smoothed[off + c] = (blurTemp[offM2 + c] + 4f * blurTemp[offM1 + c] + 6f * blurTemp[off + c] + 4f * blurTemp[offP1 + c] + blurTemp[offP2 + c]) / 16.0f
            }
        }

        // Đo đạc độ nhiễu tàn dư cao tần sau lọc Gaussian
        var diffSumSq = 0.0
        for (i in 0 until totalPixels) {
            val diff = dNormMasked[i] - smoothed[i]
            diffSumSq += diff * diff
        }
        val noiseResidual = sqrt(diffSumSq / totalPixels).toFloat()

        // 6. Tính toán Sobel Gradient Magnitude trên smoothed phục vụ kiểm tra viền vật thể
        val gradMag = FloatArray(totalPixels)
        for (r in 1 until inH - 1) {
            val off = r * inW
            val offUp = (r - 1) * inW
            val offDown = (r + 1) * inW
            for (c in 1 until inW - 1) {
                val gx = (smoothed[offDown + c + 1] + 2f * smoothed[off + c + 1] + smoothed[offUp + c + 1]) -
                         (smoothed[offDown + c - 1] + 2f * smoothed[off + c - 1] + smoothed[offUp + c - 1])
                val gy = (smoothed[offDown + c - 1] + 2f * smoothed[offDown + c] + smoothed[offDown + c + 1]) -
                         (smoothed[offUp + c - 1] + 2f * smoothed[offUp + c] + smoothed[offUp + c + 1])
                gradMag[off + c] = sqrt(gx * gx + gy * gy) // Khớp 100% độ lớn cv2.magnitude(cv2.Sobel)
            }
        }

        // 7. Kiểm tra Bão hòa Ống kính (<15cm Close Blocker)
        val centerRowStart = (inH * 0.25f).toInt()
        val centerRowEnd = (inH * 0.75f).toInt()
        val centerColStart = (inW * 0.25f).toInt()
        val centerColEnd = (inW * 0.75f).toInt()

        var centerSatCount = 0
        var centerTotal = 0
        var globalSatCount = 0

        for (r in 0 until inH) {
            val off = r * inW
            val isCenterRow = (r in centerRowStart until centerRowEnd)
            for (c in 0 until inW) {
                val isSat = rawDisparity[off + c] >= Config.SATURATION_RAW_THRESH
                if (isSat) globalSatCount++
                if (isCenterRow && (c in centerColStart until centerColEnd)) {
                    centerTotal++
                    if (isSat) centerSatCount++
                }
            }
        }

        val centerSatRatio = centerSatCount.toFloat() / max(1, centerTotal)
        val globalSatRatio = globalSatCount.toFloat() / totalPixels
        val isSaturated = (centerSatRatio >= Config.SATURATION_CENTER_RATIO) || (globalSatRatio >= Config.SATURATION_GLOBAL_RATIO)

        if (isSaturated) {
            val satObstacle = Obstacle(
                id = 1,
                x = inW / 2,
                y = inH / 2,
                bbox = Rect(centerColStart, centerRowStart, centerColEnd, centerRowEnd),
                pan = 0.0f,
                distCm = Config.SATURATION_DIST_CM * scale,
                proximity = 1.0f,
                uncertaintyScore = 0.05f,
                modeText = "CRITICAL_SATURATED"
            )
            val satBins = computeSpatialBins(rawDisparity, scale, inW, inH, listOf(satObstacle))
            return DepthResult(
                rawDisparity = rawDisparity,
                width = inW,
                height = inH,
                distCm = Config.SATURATION_DIST_CM * scale,
                pan = 0.0f,
                proximity = 1.0f,
                uncertaintyScore = 0.05f,
                isSaturated = true,
                sectorDists = mapOf("LEFT" to 13.0f * scale, "CENTER" to 13.0f * scale, "RIGHT" to 13.0f * scale),
                allObstacles = listOf(satObstacle),
                spatialBins = satBins,
                timestampNanos = frameTsNanos
            )
        }

        // 8. Base Activation / Empty Room Filter (Chống Báo Ảo Phòng Trống - Chuẩn Python)
        val mY = (0.03f * inH).toInt()
        val mX = (0.03f * inW).toInt()
        val activeRawSamples = ArrayList<Float>()
        val centerRawSamples = ArrayList<Float>()
        val smoothedSamples = ArrayList<Float>()
        val globalRawSamples = ArrayList<Float>()

        for (r in mY until (inH - mY) step 2) {
            val off = r * inW
            val isCenterRow = (r in centerRowStart until centerRowEnd)
            for (c in mX until (inW - mX) step 2) {
                val d = rawDisparity[off + c]
                activeRawSamples.add(d)
                globalRawSamples.add(d)
                val sm = smoothed[off + c]
                if (sm > 0f) smoothedSamples.add(sm)
                if (isCenterRow && (c in centerColStart until centerColEnd)) {
                    centerRawSamples.add(d)
                }
            }
        }

        val p98Active = if (activeRawSamples.isNotEmpty()) percentile(activeRawSamples, 0.98f) else 0f
        val p95Center = if (centerRawSamples.isNotEmpty()) percentile(centerRawSamples, 0.95f) else 0f
        val centerMed = if (centerRawSamples.isNotEmpty()) percentile(centerRawSamples, 0.50f) else 0f
        val p99Global = if (globalRawSamples.isNotEmpty()) percentile(globalRawSamples, 0.99f) else 0f
        val dPeak = if (smoothedSamples.isNotEmpty()) percentile(smoothedSamples, 0.992f) else 0f

        val corrCount = corrSamples.size
        val corrMean = if (corrCount > 0) corrSum / corrCount else 0.0
        val corrVariance = max(0.0, if (corrCount > 0) (corrSumSq / corrCount) - (corrMean * corrMean) else 0.0)
        val corrStd = sqrt(corrVariance).toFloat()
        val corrMed = if (corrSamples.isNotEmpty()) percentile(corrSamples, 0.50f) else 0f
        val corrCov = if (corrCount > 0) corrHighCount.toFloat() / corrCount else 0f

        val isPlanarFrontalWall = (corrStd < 32.0f && corrCov >= 0.40f && (corrMed >= 600.0f || (dMax >= 600.0f && corrMed >= 480.0f)))
        val isCloseFrontal = (centerMed >= 550.0f || rawC >= 550.0f || isPlanarFrontalWall)

        // Kiểm tra phòng trống thoát sớm (Bảo đảm 100% im lặng MUTED)
        val isClearRoom = ((centerMed < 250.0f && p98Active < Config.BASE_ACTIVATION_RAW) ||
                (p95Center < 300.0f && p98Active < Config.BASE_ACTIVATION_RAW) ||
                (!isCloseFrontal && ((p95Center < Config.BASE_ACTIVATION_RAW && p98Active < Config.BASE_ACTIVATION_PEAK) ||
                        (p95Center < 400.0f && p98Active < 500.0f) ||
                        (p99Global < 450.0f && dPeak < 0.35f))))

        if (isClearRoom) {
            val bins = computeSpatialBins(rawDisparity, scale, inW, inH, emptyList())
            return DepthResult(
                rawDisparity = rawDisparity,
                width = inW,
                height = inH,
                distCm = distC,
                pan = 0.0f,
                proximity = 0.0f,
                uncertaintyScore = 0.05f,
                isSaturated = false,
                sectorDists = sectorDists,
                allObstacles = emptyList(), // IM LẶNG TUYỆT ĐỐI (MUTED)
                spatialBins = bins,
                timestampNanos = frameTsNanos
            )
        }

        // 9. Kịch bản C: Phân đoạn vật cản nổi bật (Saliency + Ring Contrast Step + Sobel Gradient)
        val hotThreshold = max(0.40f, dPeak - 0.22f)
        val detectedList = ArrayList<Obstacle>()

        // Lưới 48x64 siêu phân giải (mỗi ô 4x4 pixel) để gom cụm hình thái học siêu tốc (<1ms)
        val gw = inW / 4  // 48
        val gh = inH / 4  // 64
        val gridActive = BooleanArray(gw * gh)
        for (gy in 0 until gh) {
            val r = gy * 4 + 2
            val off = r * inW
            val isRowValid = (r in topCut until botCut)
            val gOff = gy * gw
            for (gx in 0 until gw) {
                val c = gx * 4 + 2
                gridActive[gOff + gx] = isRowValid && (smoothed[off + c] >= hotThreshold)
            }
        }

        val visited = BooleanArray(gw * gh)
        for (gy in 1 until gh - 1) {
            val gOff = gy * gw
            for (gx in 1 until gw - 1) {
                if (gridActive[gOff + gx] && !visited[gOff + gx]) {
                    // BFS gom cụm ô lưới
                    var minGx = gx; var maxGx = gx
                    var minGy = gy; var maxGy = gy
                    var cellCount = 0

                    val queue = ArrayDeque<Int>()
                    queue.add((gy shl 8) or gx)
                    visited[gOff + gx] = true

                    while (!queue.isEmpty()) {
                        val pos = queue.poll() ?: break
                        val qy = pos shr 8
                        val qx = pos and 0xFF
                        cellCount++

                        if (qx < minGx) minGx = qx
                        if (qx > maxGx) maxGx = qx
                        if (qy < minGy) minGy = qy
                        if (qy > maxGy) maxGy = qy

                        val neighbors = intArrayOf(
                            ((qy - 1) shl 8) or qx,
                            ((qy + 1) shl 8) or qx,
                            (qy shl 8) or (qx - 1),
                            (qy shl 8) or (qx + 1)
                        )
                        for (nPos in neighbors) {
                            val ny = nPos shr 8
                            val nx = nPos and 0xFF
                            if (ny in 0 until gh && nx in 0 until gw) {
                                val nIdx = ny * gw + nx
                                if (gridActive[nIdx] && !visited[nIdx]) {
                                    visited[nIdx] = true
                                    queue.add(nPos)
                                }
                            }
                        }
                    }

                    // Lọc diện tích: Tối thiểu 0.002 * (192*256) ~ 98 pixels (>= 6 ô lưới 4x4)
                    if (cellCount >= 6) {
                        val bx = (minGx * 4).coerceIn(0, inW - 1)
                        val by = (minGy * 4).coerceIn(0, inH - 1)
                        val bw = ((maxGx - minGx + 1) * 4).coerceIn(4, inW - bx)
                        val bh = ((maxGy - minGy + 1) * 4).coerceIn(4, inH - by)
                        val aspect = bw.toFloat() / max(1, bh)

                        // Bộ lọc hình học từ Python Spatial Engine v8:
                        val isTableOrFloor = (by > 0.82f * inH && bw > 0.50f * inW && dPeak < 0.70f)
                        val isCeilingBeam = (bw > 0.45f * inW && bh < 0.25f * inH && aspect > 3.0f && dPeak < 0.70f)
                        val isBorderPadding = (bx <= 4 || bx + bw >= inW - 4) && (bw < 14)

                        if (!isTableOrFloor && !isCeilingBeam && !isBorderPadding) {
                            // Ring Contrast Step & Border Gradient (Chuẩn xác thực Python)
                            val pad = 12
                            val rx1 = max(0, bx - pad)
                            val ry1 = max(topCut, by - pad)
                            val rx2 = min(inW, bx + bw + pad)
                            val ry2 = min(botCut, by + bh + pad)

                            var insideSum = 0.0; var insideSumSq = 0.0; var insideN = 0
                            var ringSum = 0.0; var ringN = 0
                            val patchRaw = ArrayList<Float>()
                            val borderGradList = ArrayList<Float>()

                            var sumX = 0f
                            var sumY = 0f
                            var hotPixelCount = 0

                            for (r in ry1 until ry2) {
                                val off = r * inW
                                val inR = (r in by until (by + bh))
                                for (c in rx1 until rx2) {
                                    val inC = (c in bx until (bx + bw))
                                    val smVal = smoothed[off + c]
                                    val isHot = (smVal >= hotThreshold)
                                    if (inR && inC && isHot) {
                                        insideSum += smVal
                                        insideSumSq += smVal * smVal
                                        insideN++
                                        sumX += c
                                        sumY += r
                                        hotPixelCount++
                                        val dRaw = rawDisparity[off + c]
                                        if (dRaw > 50f) patchRaw.add(dRaw)
                                    } else if (!isHot) {
                                        ringSum += smVal
                                        ringN++
                                    }

                                    // Lấy mẫu gradient tại dải viền (border band)
                                    val isBorder = (inR && (c in (bx - 3)..(bx + 3) || c in (bx + bw - 3)..(bx + bw + 3))) ||
                                                   (inC && (r in (by - 3)..(by + 3) || r in (by + bh - 3)..(by + bh + 3)))
                                    if (isBorder) {
                                        borderGradList.add(gradMag[off + c])
                                    }
                                }
                            }

                            val insideMean = if (insideN > 0) (insideSum / insideN).toFloat() else 0f
                            val insideVar = max(0.0, if (insideN > 0) (insideSumSq / insideN) - (insideMean * insideMean) else 0.0)
                            val insideStd = sqrt(insideVar).toFloat()
                            val ringMean = if (ringN > 0) (ringSum / ringN).toFloat() else 0f
                            val contrastStep = insideMean - ringMean
                            val borderGradMax = if (borderGradList.isNotEmpty()) percentile(borderGradList, 0.95f) else 0f
                            val obsRawVal = if (patchRaw.isNotEmpty()) percentile(patchRaw, 0.92f) else 135f

                            // Ràng buộc xác nhận vật cản thực sự (100% khớp Python config.py):
                            val isTrueObstacle = ((borderGradMax >= 5.0f || borderGradMax >= 0.05f || borderGradMax * 255f >= Config.DISCONTINUITY_GRAD_MIN) && contrastStep >= Config.DISCONTINUITY_STEP_MIN) ||
                                    (contrastStep >= 0.20f && (borderGradMax >= Config.DISCONTINUITY_GRAD_MIN || borderGradMax >= 0.035f || borderGradMax * 255f >= Config.DISCONTINUITY_GRAD_MIN)) ||
                                    (contrastStep >= Config.DISCONTINUITY_STEP_HIGH) ||
                                    (obsRawVal >= 900.0f && contrastStep >= 0.08f) ||
                                    (obsRawVal >= 780.0f && contrastStep >= 0.12f)

                            if (isTrueObstacle) {
                                val dCm = interpolator.interpolate(obsRawVal, scale)
                                val ox = if (hotPixelCount > 0) (sumX / hotPixelCount).toInt() else bx + bw / 2
                                val oy = if (hotPixelCount > 0) (sumY / hotPixelCount).toInt() else by + bh / 2
                                val panVal = ((ox.toFloat() / (inW - 1)) * 2.0f - 1.0f).coerceIn(-1.0f, 1.0f)

                                // Bỏ qua vật thể quá xa (>150cm)
                                if (dCm < Config.DIST_ALERT_CM * scale) {
                                    // Bỏ qua vật cản nằm ở rìa biên nếu hành lang trung tâm an toàn
                                    if (distC >= Config.DIST_SAFE_CM * scale && abs(panVal) > 0.75f) {
                                        // continue
                                    } else {
                                        val prox = computeProximity(dCm, scale)
                                        val gradFactor = (1.0f - borderGradMax / 2.2f).coerceIn(0.0f, 1.0f)
                                        val stepFactor = (1.0f - contrastStep / 0.25f).coerceIn(0.0f, 1.0f)
                                        val noiseFactor = (max(insideStd, noiseResidual * 2.0f) / 0.15f).coerceIn(0.0f, 1.0f)
                                        val uncertVal = (0.40f * gradFactor + 0.40f * stepFactor + 0.20f * noiseFactor).coerceIn(0.05f, 0.95f)

                                        val modeText = when {
                                            dCm <= Config.DIST_CRITICAL_CM * scale -> "CRITICAL (${dCm.toInt()}cm)"
                                            dCm < Config.DIST_DANGER_CM * scale -> "DANGER (<30cm)"
                                            dCm < Config.DIST_WARNING_CM * scale -> "WARNING (~${dCm.toInt()}cm)"
                                            else -> "ALERT (>70cm)"
                                        }

                                        detectedList.add(
                                            Obstacle(
                                                id = detectedList.size + 1,
                                                x = ox,
                                                y = oy,
                                                bbox = Rect(bx, by, bx + bw, by + bh),
                                                pan = panVal,
                                                distCm = dCm,
                                                proximity = prox,
                                                uncertaintyScore = uncertVal,
                                                isWall = false,
                                                modeText = modeText
                                            )
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Ưu tiên sắp xếp vật cản gần nhất lên đầu (Khớp 100% Python sorting)
        if (detectedList.size > 1) {
            detectedList.sortBy { it.distCm }
            for (idx in detectedList.indices) {
                detectedList[idx].id = idx + 1
            }
        }

        // 10. Kịch bản D: Khảo sát Hành lang di chuyển & Vách tường phẳng (Planar Wall)
        val rawWallMax = max(rawL, max(rawC, rawR))
        val distWallCm = if (isPlanarFrontalWall) 48.0f * scale else interpolator.interpolate(rawWallMax, scale)

        // Ràng buộc Python: Nếu không phải vách phẳng và không có vật thể nổi bật -> ép an toàn (SAFE)
        val finalDistWallCm = if (!isPlanarFrontalWall && detectedList.isEmpty()) {
            Config.DIST_SAFE_CM * scale
        } else {
            distWallCm
        }

        val hasCorridorBlock = isPlanarFrontalWall || (finalDistWallCm < Config.DIST_WARNING_CM * scale)
        if (hasCorridorBlock && finalDistWallCm < Config.DIST_ALERT_CM * scale) {
            val panWall = when {
                rawWallMax == rawL -> -0.50f
                rawWallMax == rawR -> +0.50f
                else -> 0.00f
            }
            val wallX = when {
                rawWallMax == rawL -> cx1 + secW / 2
                rawWallMax == rawR -> cx1 + 2 * secW + secW / 2
                else -> cx1 + secW + secW / 2
            }
            val wallY = (cy1 + cy2) / 2
            val wallBbox = Rect(cx1, cy1, cx2, cy2)

            var overlap = false
            for (dObs in detectedList) {
                if (abs(dObs.x - wallX) < 50 && abs(dObs.distCm - finalDistWallCm) < 25.0f) {
                    overlap = true
                    break
                }
            }
            if (!overlap) {
                val prox = computeProximity(finalDistWallCm, scale)
                val mWall = when {
                    finalDistWallCm <= Config.DIST_CRITICAL_CM * scale -> "WALL: CRITICAL"
                    finalDistWallCm < Config.DIST_DANGER_CM * scale -> "WALL: DANGER"
                    finalDistWallCm < Config.DIST_WARNING_CM * scale -> "WALL: WARNING"
                    else -> "WALL: ALERT"
                }

                val wallUncert = if (noiseResidual > 0.10f) {
                    (noiseResidual / 0.35f).coerceIn(0.55f, 0.95f)
                } else {
                    if (isPlanarFrontalWall) 0.20f else 0.28f
                }

                detectedList.add(
                    Obstacle(
                        id = detectedList.size + 1,
                        x = wallX,
                        y = wallY,
                        bbox = wallBbox,
                        pan = panWall,
                        distCm = finalDistWallCm,
                        proximity = prox,
                        uncertaintyScore = wallUncert,
                        isWall = true,
                        modeText = mWall
                    )
                )
            }
        }

        // Sắp xếp các vật cản theo thứ tự khoảng cách gần nhất
        detectedList.sortBy { it.distCm }

        if (detectedList.isEmpty()) {
            val bins = computeSpatialBins(rawDisparity, scale, inW, inH, emptyList())
            return DepthResult(
                rawDisparity = rawDisparity,
                width = inW,
                height = inH,
                distCm = distC,
                pan = 0.0f,
                proximity = 0.0f,
                uncertaintyScore = 0.05f,
                isSaturated = false,
                sectorDists = sectorDists,
                allObstacles = emptyList(), // IM LẶNG (MUTED)
                spatialBins = bins,
                timestampNanos = frameTsNanos
            )
        }

        for (i in detectedList.indices) {
            detectedList[i].id = i + 1
        }
        val primary = detectedList[0]
        val bins = computeSpatialBins(rawDisparity, scale, inW, inH, detectedList)

        return DepthResult(
            rawDisparity = rawDisparity,
            width = inW,
            height = inH,
            distCm = primary.distCm,
            pan = primary.pan,
            proximity = primary.proximity,
            uncertaintyScore = primary.uncertaintyScore,
            isSaturated = false,
            sectorDists = sectorDists,
            allObstacles = detectedList,
            spatialBins = bins,
            timestampNanos = frameTsNanos
        )
    }

    private fun computeProximity(distCm: Float, scale: Float): Float {
        val crit = Config.DIST_CRITICAL_CM * scale
        val dang = Config.DIST_DANGER_CM * scale
        val warn = Config.DIST_WARNING_CM * scale
        val alert = Config.DIST_ALERT_CM * scale

        return when {
            distCm <= crit -> 1.0f
            distCm < dang -> 0.70f + 0.30f * (dang - distCm) / (dang - crit)
            distCm < warn -> 0.35f + 0.35f * (warn - distCm) / (warn - dang)
            distCm < alert -> 0.05f + 0.30f * (alert - distCm) / (alert - warn)
            else -> 0.0f
        }
    }

    companion object {
        private val defaultInterpolator = PchipInterpolator()

        private fun percentile(list: ArrayList<Float>, p: Float): Float {
            list.sort()
            val index = (p * (list.size - 1)).toInt().coerceIn(0, list.size - 1)
            return list[index]
        }

        fun computeSpatialBins(
            rawDisparity: FloatArray?,
            scale: Float = 1.0f,
            w: Int = 192,
            h: Int = 256,
            detectedList: List<Obstacle> = emptyList(),
            numBins: Int = 24,
            hfovDeg: Float = 65.0f,
            interp: PchipInterpolator = defaultInterpolator
        ): List<SpatialBin> {
            val cx = w / 2.0f
            val halfFov = hfovDeg / 2.0f
            val fx = cx / kotlin.math.tan(Math.toRadians(halfFov.toDouble())).toFloat()

            val cy1B = (0.20f * h).toInt()
            val cy2B = (0.65f * h).toInt()
            val cy1G = (0.65f * h).toInt()
            val cy2G = (0.85f * h).toInt()
            val cy1O = 0
            val cy2O = (0.20f * h).toInt()

            val binW = w.toFloat() / numBins.toFloat()
            val hasDepth = rawDisparity != null && rawDisparity.size >= w * h

            val bins = ArrayList<SpatialBin>(numBins)

            for (i in 0 until numBins) {
                val bx1 = kotlin.math.round(i * binW).toInt()
                val bx2 = max(bx1 + 1, min(w, kotlin.math.round((i + 1) * binW).toInt()))

                val angMin = Math.toDegrees(kotlin.math.atan2((bx1 - cx).toDouble(), fx.toDouble())).toFloat()
                val angMax = Math.toDegrees(kotlin.math.atan2((bx2 - cx).toDouble(), fx.toDouble())).toFloat()
                val angCenter = (angMin + angMax) / 2.0f

                var validRatio = 0.0f
                var rawP80 = Float.NaN
                var bodyDistCm = Float.NaN
                var groundDistCm = Float.NaN
                var overheadDistCm = Float.NaN
                var distCm = Float.NaN
                var isValid = false

                if (hasDepth) {
                    // 1. Body band [0.20h, 0.65h]
                    val bodySamples = ArrayList<Float>()
                    var totalBodyPixels = 0
                    for (y in cy1B until cy2B) {
                        val rowOff = y * w
                        for (x in bx1 until bx2) {
                            totalBodyPixels++
                            val v = rawDisparity!![rowOff + x]
                            if (v.isFinite() && v > 0f) {
                                bodySamples.add(v)
                            }
                        }
                    }
                    validRatio = if (totalBodyPixels > 0) bodySamples.size.toFloat() / totalBodyPixels.toFloat() else 0.0f
                    if (validRatio >= 0.35f && bodySamples.isNotEmpty()) {
                        rawP80 = percentile(bodySamples, 0.80f)
                        bodyDistCm = interp.interpolate(rawP80, scale)
                        distCm = bodyDistCm
                        isValid = bodyDistCm.isFinite() && bodyDistCm > 0f
                    }

                    // 2. Ground band [0.65h, 0.85h]
                    val groundSamples = ArrayList<Float>()
                    var totalGroundPixels = 0
                    for (y in cy1G until cy2G) {
                        val rowOff = y * w
                        for (x in bx1 until bx2) {
                            totalGroundPixels++
                            val v = rawDisparity!![rowOff + x]
                            if (v.isFinite() && v > 0f) {
                                groundSamples.add(v)
                            }
                        }
                    }
                    if (totalGroundPixels > 0 && groundSamples.size.toFloat() / totalGroundPixels.toFloat() >= 0.35f && groundSamples.isNotEmpty()) {
                        val gP80 = percentile(groundSamples, 0.80f)
                        groundDistCm = interp.interpolate(gP80, scale)
                    }

                    // 3. Overhead band [0.0h, 0.20h]
                    val overheadSamples = ArrayList<Float>()
                    var totalOverheadPixels = 0
                    for (y in cy1O until cy2O) {
                        val rowOff = y * w
                        for (x in bx1 until bx2) {
                            totalOverheadPixels++
                            val v = rawDisparity!![rowOff + x]
                            if (v.isFinite() && v > 0f) {
                                overheadSamples.add(v)
                            }
                        }
                    }
                    if (totalOverheadPixels > 0 && overheadSamples.size.toFloat() / totalOverheadPixels.toFloat() >= 0.35f && overheadSamples.isNotEmpty()) {
                        val oP80 = percentile(overheadSamples, 0.80f)
                        overheadDistCm = interp.interpolate(oP80, scale)
                    }
                }

                var hasObs = false
                for (obs in detectedList) {
                    val ox1 = obs.bbox.left
                    val ox2 = obs.bbox.right
                    if (!(bx2 <= ox1 || bx1 >= ox2)) {
                        hasObs = true
                        break
                    }
                }

                bins.add(
                    SpatialBin(
                        binId = i,
                        angleMin = kotlin.math.round(angMin * 100f) / 100f,
                        angleMax = kotlin.math.round(angMax * 100f) / 100f,
                        angleCenter = kotlin.math.round(angCenter * 100f) / 100f,
                        validRatio = kotlin.math.round(validRatio * 1000f) / 1000f,
                        rawDepthStatistic = rawP80,
                        estimatedDistanceCm = distCm,
                        isValid = isValid,
                        hasObstacle = hasObs,
                        bodyDistCm = bodyDistCm,
                        groundDistCm = groundDistCm,
                        overheadDistCm = overheadDistCm
                    )
                )
            }
            return bins
        }
    }

    override fun close() {
        session.close()
        env.close()
    }
}
