package com.horuseyes.app.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.util.AttributeSet
import android.view.View
import com.horuseyes.app.Config
import com.horuseyes.app.budget.BudgetDecision
import com.horuseyes.app.kinematics.KinematicsResult
import com.horuseyes.app.vision.DepthResult
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

/**
 * Custom View hiển thị Telemetry HUD trực quan chuẩn ViSEF:
 * - Viền hộp bao nổi bật, tương phản cao, bo tròn góc với hiệu ứng ánh sáng (Glowing Tint Fill)
 * - Khung ngắm góc vuông (Corner Brackets) dày 8px tạo cảm giác khóa mục tiêu hiện đại
 * - Tâm ngắm Reticle (Crosshair & Target Circle) ngay tại trọng tâm vật cản
 * - Huy hiệu thông số chi tiết: ID mục tiêu, Trạng thái (TIẾN TỚI / LÙI XA / TĨNH), Cự ly cm, Vận tốc v_z, TTC
 * - Mũi tên vector chỉ hướng chuyển động tiếp cận / lùi xa
 * - Chỉ dẫn né thoát an toàn (Safe Escape Guidance Pill)
 * - Banner báo đường thoáng an toàn (Clear Path Indicator) khi phòng trống
 * - Màn hình trạng thái Tạm dừng (Paused Overlay)
 */
class OverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private var depthResult: DepthResult? = null
    private var kinematicsResult: KinematicsResult? = null
    private var decision: BudgetDecision? = null
    private var fps: Float = 30.0f
    private var latencyMs: Float = 35.0f

    @Volatile
    var isPaused: Boolean = false
        set(value) {
            field = value
            postInvalidate()
        }

    // ── Paint cho Mục tiêu chính (Primary Target) ──
    private val primaryBoxPaint = Paint().apply {
        style = Paint.Style.STROKE
        strokeWidth = 6f
        isAntiAlias = true
    }

    private val primaryFillPaint = Paint().apply {
        style = Paint.Style.FILL
        isAntiAlias = true
    }

    private val cornerBracketPaint = Paint().apply {
        style = Paint.Style.STROKE
        strokeWidth = 8f
        strokeCap = Paint.Cap.ROUND
        isAntiAlias = true
    }

    private val reticleCirclePaint = Paint().apply {
        style = Paint.Style.STROKE
        strokeWidth = 2.5f
        isAntiAlias = true
    }

    private val reticleCenterPaint = Paint().apply {
        style = Paint.Style.FILL
        isAntiAlias = true
    }

    // ── Paint cho Mục tiêu phụ (Secondary Targets) ──
    private val secondaryBoxPaint = Paint().apply {
        color = Color.parseColor("#00E5FF") // Electric Cyan nổi bật
        style = Paint.Style.STROKE
        strokeWidth = 4f
        isAntiAlias = true
    }

    private val secondaryFillPaint = Paint().apply {
        color = Color.parseColor("#1800E5FF") // Tint nhẹ Cyan
        style = Paint.Style.FILL
        isAntiAlias = true
    }

    // ── Paint Huy hiệu (Badge) & Chữ (Text) ──
    private val badgeBgPaint = Paint().apply {
        color = Color.parseColor("#E60F172A") // Nền kính tối sâu 90%
        style = Paint.Style.FILL
        isAntiAlias = true
    }

    private val badgeBorderPaint = Paint().apply {
        style = Paint.Style.STROKE
        strokeWidth = 2f
        isAntiAlias = true
    }

    private val badgeTextPaint = Paint().apply {
        textSize = 28f
        isAntiAlias = true
        typeface = Typeface.DEFAULT_BOLD
    }

    private val secBadgeTextPaint = Paint().apply {
        color = Color.parseColor("#00E5FF")
        textSize = 24f
        isAntiAlias = true
        typeface = Typeface.DEFAULT_BOLD
    }

    // ── Paint Mũi tên vector chuyển động (Motion Arrow) ──
    private val arrowPaint = Paint().apply {
        style = Paint.Style.STROKE
        strokeWidth = 5f
        strokeCap = Paint.Cap.ROUND
        isAntiAlias = true
    }

    private val arrowHeadPaint = Paint().apply {
        style = Paint.Style.FILL
        isAntiAlias = true
    }

    private val arrowPath = Path()

    // ── Paint Chỉ dẫn né thoát an toàn (Guidance Pill) ──
    private val guidanceBgPaint = Paint().apply {
        color = Color.parseColor("#E60F172A")
        style = Paint.Style.FILL
        isAntiAlias = true
    }

    private val guidanceBorderPaint = Paint().apply {
        color = Color.parseColor("#00E676")
        style = Paint.Style.STROKE
        strokeWidth = 3f
        isAntiAlias = true
    }

    private val guidanceTextPaint = Paint().apply {
        color = Color.parseColor("#00E676")
        textSize = 32f
        textAlign = Paint.Align.CENTER
        isAntiAlias = true
        typeface = Typeface.DEFAULT_BOLD
    }

    // ── Paint Banner An toàn (Clear Path) ──
    private val safeBannerPaint = Paint().apply {
        color = Color.parseColor("#00E676")
        textSize = 30f
        textAlign = Paint.Align.CENTER
        isAntiAlias = true
        typeface = Typeface.DEFAULT_BOLD
    }

    // ── Paint Màn hình Tạm dừng (Paused Overlay) ──
    private val pausedBgPaint = Paint().apply {
        color = Color.parseColor("#B3000000")
        style = Paint.Style.FILL
    }

    private val pausedTextTitlePaint = Paint().apply {
        color = Color.parseColor("#FFA000")
        textSize = 52f
        textAlign = Paint.Align.CENTER
        isAntiAlias = true
        typeface = Typeface.DEFAULT_BOLD
    }

    private val pausedTextSubPaint = Paint().apply {
        color = Color.parseColor("#CBD5E1")
        textSize = 32f
        textAlign = Paint.Align.CENTER
        isAntiAlias = true
    }

    fun updateTelemetry(
        depthRes: DepthResult,
        kinRes: KinematicsResult,
        dec: BudgetDecision,
        currentFps: Float,
        currentLatency: Float
    ) {
        this.depthResult = depthRes
        this.kinematicsResult = kinRes
        this.decision = dec
        this.fps = currentFps
        this.latencyMs = currentLatency
        postInvalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val viewW = width.toFloat()
        val viewH = height.toFloat()

        // ── 0. Hiển thị màn hình Tạm dừng nếu đang PAUSED ──
        if (isPaused) {
            canvas.drawRect(0f, 0f, viewW, viewH, pausedBgPaint)
            val centerY = viewH * 0.45f
            canvas.drawText("❚❚ ĐÃ TẠM DỪNG", viewW / 2f, centerY, pausedTextTitlePaint)
            canvas.drawText("Nhấn nút START bên dưới để tiếp tục quét", viewW / 2f, centerY + 65f, pausedTextSubPaint)
            return
        }

        val dRes = depthResult ?: return
        val kRes = kinematicsResult ?: return

        // Căn chỉnh khung hình chuẩn tỷ lệ CameraX FILL_CENTER
        val dW = dRes.width.toFloat()   // 192f
        val dH = dRes.height.toFloat()  // 256f

        val scale = max(viewW / dW, viewH / dH)
        val offsetX = (viewW - dW * scale) / 2f
        val offsetY = (viewH - dH * scale) / 2f

        fun toScreenX(x: Float): Float = offsetX + x * scale
        fun toScreenY(y: Float): Float = offsetY + y * scale

        val allObs = dRes.allObstacles

        // ── 1. Trường hợp không phát hiện vật cản nào (Phòng trống / Thoáng an toàn >1.5m) ──
        if (allObs.isEmpty()) {
            val safePillW = 500f
            val safePillH = 54f
            val safePillX = (viewW - safePillW) / 2f
            val safePillY = 170f
            val safeRect = RectF(safePillX, safePillY, safePillX + safePillW, safePillY + safePillH)

            canvas.drawRoundRect(safeRect, 27f, 27f, guidanceBgPaint)
            canvas.drawRoundRect(safeRect, 27f, 27f, guidanceBorderPaint)
            canvas.drawText("● AN TOÀN — ĐƯỜNG THOÁNG (>1.5m)", viewW / 2f, safePillY + 38f, safeBannerPaint)
            return
        }

        // ── 2. Vẽ các mục tiêu phụ (Secondary Obstacles) trước để không che mục tiêu chính ──
        if (allObs.size > 1) {
            for (i in 1 until allObs.size) {
                val secObs = allObs[i]
                val sLeft = toScreenX(secObs.bbox.left.toFloat())
                val sTop = toScreenY(secObs.bbox.top.toFloat())
                val sRight = toScreenX(secObs.bbox.right.toFloat())
                val sBottom = toScreenY(secObs.bbox.bottom.toFloat())
                val sRect = RectF(sLeft, sTop, sRight, sBottom)

                // Vùng phủ bán trong suốt màu Cyan
                canvas.drawRoundRect(sRect, 12f, 12f, secondaryFillPaint)
                // Khung viền nét liền 4px màu Cyan
                canvas.drawRoundRect(sRect, 12f, 12f, secondaryBoxPaint)

                // Huy hiệu mục tiêu phụ
                val secDetail = kRes.trackDetails[secObs.id]
                val secMotion = secDetail?.motionStatus ?: "STATIC"
                val secMotionTag = when (secMotion) {
                    "APPROACHING" -> "TIẾN TỚI"
                    "RECEDING" -> "LÙI XA"
                    else -> "TĨNH"
                }
                val secBadgeText = "[#${secObs.id}] PHỤ: ${secObs.distCm.toInt()}cm | $secMotionTag"
                val secTextW = secBadgeTextPaint.measureText(secBadgeText)
                val secBadgeH = 38f
                val secBadgeTop = (sTop - secBadgeH - 8f).coerceAtLeast(160f)
                val secBadgeRect = RectF(sLeft, secBadgeTop, sLeft + secTextW + 24f, secBadgeTop + secBadgeH)

                canvas.drawRoundRect(secBadgeRect, 8f, 8f, badgeBgPaint)
                badgeBorderPaint.color = Color.parseColor("#00E5FF")
                canvas.drawRoundRect(secBadgeRect, 8f, 8f, badgeBorderPaint)
                canvas.drawText(secBadgeText, sLeft + 12f, secBadgeTop + 27f, secBadgeTextPaint)
            }
        }

        // ── 3. Vẽ mục tiêu chính (Primary Threat Target) ──
        val primaryObs = allObs.first()
        val pLeft = toScreenX(primaryObs.bbox.left.toFloat())
        val pTop = toScreenY(primaryObs.bbox.top.toFloat())
        val pRight = toScreenX(primaryObs.bbox.right.toFloat())
        val pBottom = toScreenY(primaryObs.bbox.bottom.toFloat())
        val pRect = RectF(pLeft, pTop, pRight, pBottom)

        val pDetail = kRes.trackDetails[primaryObs.id]
        val pMotion = pDetail?.motionStatus ?: "STATIC"
        val pVz = pDetail?.vzSmooth ?: (kRes.obstacleVzs[primaryObs.id] ?: 0f)
        val pTtc = pDetail?.ttc ?: (kRes.obstacleTtcs[primaryObs.id] ?: Float.POSITIVE_INFINITY)

        val isCritical = kRes.threatLevel == "CRITICAL" || primaryObs.distCm <= Config.DIST_CRITICAL_CM
        val isWarning = kRes.threatLevel == "WARNING" || pMotion == "APPROACHING" || primaryObs.distCm <= Config.DIST_DANGER_CM

        // Bảng màu trạng thái
        val themeColor = when {
            isCritical -> Color.parseColor("#FF1744") // Đỏ Neon Khẩn Cấp
            isWarning -> Color.parseColor("#FF9100")  // Cam Neon Cảnh Báo
            else -> Color.parseColor("#00E676")       // Xanh Lá Neon An Toàn
        }

        val fillColor = when {
            isCritical -> Color.parseColor("#33FF1744")
            isWarning -> Color.parseColor("#28FF9100")
            else -> Color.parseColor("#2000E676")
        }

        // 3a. Phủ vùng đệm màu bán trong suốt để vật cản tách biệt khỏi hậu cảnh
        primaryFillPaint.color = fillColor
        canvas.drawRoundRect(pRect, 14f, 14f, primaryFillPaint)

        // 3b. Đường viền bao quanh nét liền dày 6px
        primaryBoxPaint.color = themeColor
        canvas.drawRoundRect(pRect, 14f, 14f, primaryBoxPaint)

        // 3c. Khung ngắm góc vuông (Corner Brackets) dày 8px tạo điểm nhấn khóa mục tiêu
        drawCornerBrackets(canvas, pLeft, pTop, pRight, pBottom, themeColor)

        // 3d. Tâm ngắm Reticle (Crosshair & Circle) tại tọa độ trọng tâm vật thể
        val ox = toScreenX(primaryObs.x.toFloat())
        val oy = toScreenY(primaryObs.y.toFloat())
        reticleCirclePaint.color = themeColor
        reticleCenterPaint.color = themeColor

        canvas.drawCircle(ox, oy, 22f, reticleCirclePaint)
        canvas.drawCircle(ox, oy, 5f, reticleCenterPaint)
        // 4 vạch dấu thập ngắn
        canvas.drawLine(ox - 30f, oy, ox - 18f, oy, reticleCirclePaint)
        canvas.drawLine(ox + 18f, oy, ox + 30f, oy, reticleCirclePaint)
        canvas.drawLine(ox, oy - 30f, ox, oy - 18f, reticleCirclePaint)
        canvas.drawLine(ox, oy + 18f, ox, oy + 30f, reticleCirclePaint)

        // 3e. Mũi tên vector chỉ hướng chuyển động tiếp cận / lùi xa
        if (pMotion == "APPROACHING") {
            val arrowLen = (pVz * 0.8f).coerceIn(28f, 90f)
            drawMotionArrow(canvas, ox, oy, isApproaching = true, length = arrowLen, color = Color.parseColor("#FF1744"))
        } else if (pMotion == "RECEDING") {
            val arrowLen = (kotlin.math.abs(pVz) * 0.8f).coerceIn(28f, 90f)
            drawMotionArrow(canvas, ox, oy, isApproaching = false, length = arrowLen, color = Color.parseColor("#38BDF8"))
        }

        // 3f. Huy hiệu thông số mục tiêu chính (Primary Target Badge)
        val statusPrefix = when {
            isCritical -> "● NGUY HIỂM"
            isWarning -> "▲ CẢNH BÁO"
            else -> "✓ AN TOÀN"
        }

        val motionText = when (pMotion) {
            "APPROACHING" -> "TIẾN TỚI +${pVz.toInt()}cm/s"
            "RECEDING" -> "LÙI XA ${pVz.toInt()}cm/s"
            else -> "VẬT TĨNH"
        }

        val ttcText = if (pTtc < 10.0f) " | TTC: ${String.format(Locale.US, "%.1fs", pTtc)}" else ""
        val badgeText = "[#${primaryObs.id}] $statusPrefix: ${primaryObs.distCm.toInt()}cm | $motionText$ttcText"

        val textWidth = badgeTextPaint.measureText(badgeText)
        val badgeH = 46f
        val badgeTop = (pTop - badgeH - 12f).coerceAtLeast(160f)
        val badgeRect = RectF(pLeft, badgeTop, pLeft + textWidth + 28f, badgeTop + badgeH)

        canvas.drawRoundRect(badgeRect, 10f, 10f, badgeBgPaint)
        badgeBorderPaint.color = themeColor
        canvas.drawRoundRect(badgeRect, 10f, 10f, badgeBorderPaint)

        badgeTextPaint.color = themeColor
        canvas.drawText(badgeText, pLeft + 14f, badgeTop + 32f, badgeTextPaint)

        // ── 4. Chỉ dẫn hướng né an toàn (Safe Escape Direction Pill) & Deadlock STOP ──
        if (kRes.guidanceState == "HAZARD_BLOCKED" || kRes.safeDirection == "STOP") {
            val stopW = 520f
            val stopH = 64f
            val stopY = viewH - 240f
            val midX = viewW * 0.5f
            val flashOn = (System.currentTimeMillis() / 250) % 2 == 0L
            val stopBorderColor = if (flashOn) Color.parseColor("#FF1744") else Color.parseColor("#B71C1C")
            val stopTextColor = if (flashOn) Color.parseColor("#FF1744") else Color.parseColor("#E57373")

            val stopRect = RectF((viewW - stopW) / 2f, stopY, (viewW + stopW) / 2f, stopY + stopH)
            canvas.drawRoundRect(stopRect, 32f, 32f, guidanceBgPaint)
            guidanceBorderPaint.color = stopBorderColor
            guidanceBorderPaint.strokeWidth = 4f
            canvas.drawRoundRect(stopRect, 32f, 32f, guidanceBorderPaint)
            guidanceTextPaint.color = stopTextColor
            canvas.drawText("[STOP - PATH BLOCKED]", midX, stopY + 43f, guidanceTextPaint)
        } else if (kRes.threatLevel != "SAFE") {
            val guideW = 460f
            val guideH = 56f
            val guideY = viewH - 240f
            val midX = viewW * 0.5f

            val hazardDir = if (dRes.pan < -0.33f) "BÊN TRÁI" else if (dRes.pan > 0.33f) "BÊN PHẢI" else "TRỰC DIỆN"
            val distCmInt = dRes.distCm.toInt()
            val hazardText = "MỐI NGUY: $hazardDir (${distCmInt}cm)"

            val escRect = RectF((viewW - guideW) / 2f, guideY, (viewW + guideW) / 2f, guideY + guideH)
            canvas.drawRoundRect(escRect, 28f, 28f, guidanceBgPaint)
            val bannerColor = if (kRes.threatLevel == "CRITICAL") Color.parseColor("#FF1744") else Color.parseColor("#FFA000")
            guidanceBorderPaint.color = bannerColor
            guidanceBorderPaint.strokeWidth = 3f
            canvas.drawRoundRect(escRect, 28f, 28f, guidanceBorderPaint)
            guidanceTextPaint.color = bannerColor
            canvas.drawText(hazardText, midX, guideY + 39f, guidanceTextPaint)
        }
    }

    private fun drawCornerBrackets(
        canvas: Canvas,
        left: Float,
        top: Float,
        right: Float,
        bottom: Float,
        color: Int
    ) {
        cornerBracketPaint.color = color
        val len = min(36f, min((right - left) / 3f, (bottom - top) / 3f))
        // Góc trên-trái
        canvas.drawLine(left, top, left + len, top, cornerBracketPaint)
        canvas.drawLine(left, top, left, top + len, cornerBracketPaint)
        // Góc trên-phải
        canvas.drawLine(right, top, right - len, top, cornerBracketPaint)
        canvas.drawLine(right, top, right, top + len, cornerBracketPaint)
        // Góc dưới-trái
        canvas.drawLine(left, bottom, left + len, bottom, cornerBracketPaint)
        canvas.drawLine(left, bottom, left, bottom - len, cornerBracketPaint)
        // Góc dưới-phải
        canvas.drawLine(right, bottom, right - len, bottom, cornerBracketPaint)
        canvas.drawLine(right, bottom, right, bottom - len, cornerBracketPaint)
    }

    private fun drawMotionArrow(
        canvas: Canvas,
        cx: Float,
        cy: Float,
        isApproaching: Boolean,
        length: Float,
        color: Int
    ) {
        arrowPaint.color = color
        arrowHeadPaint.color = color
        val dir = if (isApproaching) 1f else -1f
        val startY = cy + dir * 26f
        val endY = startY + dir * length
        canvas.drawLine(cx, startY, cx, endY, arrowPaint)

        // Đầu mũi tên hình tam giác
        arrowPath.reset()
        val headSize = 14f
        arrowPath.moveTo(cx, endY + dir * 8f)
        arrowPath.lineTo(cx - headSize, endY)
        arrowPath.lineTo(cx + headSize, endY)
        arrowPath.close()
        canvas.drawPath(arrowPath, arrowHeadPaint)
    }
}
