package com.horuseyes.app.math

import com.horuseyes.app.Config
import kotlin.math.abs
import kotlin.math.sign

/**
 * Fritsch-Carlson Piecewise Cubic Hermite Interpolating Polynomial (PCHIP).
 * Triển khai thuần Kotlin bảo toàn tính đơn điệu ngặt, d(D) giảm dần theo D,
 * loại bỏ triệt để hiện tượng dao động Runge.
 */
class PchipInterpolator(
    private val xKnots: FloatArray = Config.RAW_KNOTS,
    private val yKnots: FloatArray = Config.CM_KNOTS
) {
    private val n: Int = xKnots.size
    private val h = FloatArray(n - 1)
    private val delta = FloatArray(n - 1)
    private val d = FloatArray(n)

    init {
        require(n >= 2) { "PCHIP yêu cầu tối thiểu 2 điểm nút (knots)." }
        require(xKnots.size == yKnots.size) { "Kích thước xKnots và yKnots phải bằng nhau." }

        // 1. Tính độ dài khoảng h_k và hệ số góc secant delta_k
        for (i in 0 until n - 1) {
            h[i] = xKnots[i + 1] - xKnots[i]
            require(h[i] > 0f) { "Các giá trị xKnots phải tăng ngặt." }
            delta[i] = (yKnots[i + 1] - yKnots[i]) / h[i]
        }

        // 2. Tính đạo hàm tại các điểm nút bên trong (Internal Knots)
        for (i in 1 until n - 1) {
            if (sign(delta[i - 1]) * sign(delta[i]) <= 0f) {
                // Điểm cực trị cục bộ hoặc đổi dấu -> Đặt đạo hàm = 0 để giữ tính đơn điệu
                d[i] = 0f
            } else {
                // Trung bình điều hòa có trọng số Fritsch-Carlson
                val w1 = 2f * h[i] + h[i - 1]
                val w2 = h[i] + 2f * h[i - 1]
                d[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
            }
        }

        // 3. Đạo hàm tại 2 điểm biên (Endpoints)
        // Điểm đầu x[0]
        d[0] = ((2f * h[0] + h[1]) * delta[0] - h[0] * delta[1]) / (h[0] + h[1])
        if (sign(d[0]) != sign(delta[0])) {
            d[0] = 0f
        } else if (sign(delta[0]) != sign(delta[1]) && abs(d[0]) > abs(3f * delta[0])) {
            d[0] = 3f * delta[0]
        }

        // Điểm cuối x[n-1]
        val last = n - 1
        d[last] = ((2f * h[last - 1] + h[last - 2]) * delta[last - 1] - h[last - 1] * delta[last - 2]) / (h[last - 1] + h[last - 2])
        if (sign(d[last]) != sign(delta[last - 1])) {
            d[last] = 0f
        } else if (sign(delta[last - 1]) != sign(delta[last - 2]) && abs(d[last]) > abs(3f * delta[last - 1])) {
            d[last] = 3f * delta[last - 1]
        }
    }

    /**
     * Nội suy cự ly metric (cm) từ giá trị raw disparity có kèm hệ số bù tiêu cự scaleFactor.
     * Tự động kẹp biên trong dải an toàn [13.0cm, 350.0cm].
     */
    fun interpolate(rawDisp: Float, scaleFactor: Float = 1.0f): Float {
        val s = scaleFactor.coerceIn(0.50f, 2.00f)
        // Xử lý ngoài biên
        if (rawDisp <= xKnots[0]) {
            return (yKnots[0] * s).coerceIn(Config.SATURATION_DIST_CM * s, 350.0f * s)
        }
        if (rawDisp >= xKnots[n - 1]) {
            return (yKnots[n - 1] * s).coerceIn(Config.SATURATION_DIST_CM * s, 350.0f * s)
        }

        // Tìm đoạn [x_k, x_{k+1}] bằng Binary Search
        var low = 0
        var high = n - 2
        var k = 0
        while (low <= high) {
            val mid = (low + high) ushr 1
            if (rawDisp >= xKnots[mid]) {
                k = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        // Tọa độ chuẩn hóa t in [0, 1]
        val t = (rawDisp - xKnots[k]) / h[k]
        val t2 = t * t
        val t3 = t2 * t

        // Các hàm đa thức Hermite cơ sở
        val h00 = 2f * t3 - 3f * t2 + 1f
        val h10 = t3 - 2f * t2 + t
        val h01 = -2f * t3 + 3f * t2
        val h11 = t3 - t2

        val yVal = h00 * yKnots[k] +
                h10 * h[k] * d[k] +
                h01 * yKnots[k + 1] +
                h11 * h[k] * d[k + 1]

        return (yVal * s).coerceIn(Config.SATURATION_DIST_CM * s, 350.0f * s)
    }
}
