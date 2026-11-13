package com.horuseyes.app

import android.graphics.Rect
import com.horuseyes.app.ui.DirectionalAdvisory
import com.horuseyes.app.ui.estimateDirectionalAdvisory
import com.horuseyes.app.vision.DepthEngine
import com.horuseyes.app.vision.DepthResult
import com.horuseyes.app.vision.Obstacle
import com.horuseyes.app.vision.SpatialBin
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.abs

class TensorSpatialIntegrationTest {

    private fun createBaseTensor(w: Int = 192, h: Int = 256, fillVal: Float = 180.0f): FloatArray {
        return FloatArray(w * h) { fillVal }
    }

    @Test
    fun test01_openCentralCorridor() {
        val tensor = createBaseTensor(fillVal = 180.0f)
        val bins = DepthEngine.computeSpatialBins(tensor, w = 192, h = 256, numBins = 24)
        assertEquals(24, bins.size)
        assertTrue(bins.all { it.isValid })

        val depth = DepthResult(
            rawDisparity = tensor, width = 192, height = 256, distCm = 200.0f,
            pan = 0.0f, proximity = 0.2f, uncertaintyScore = 0.1f, isSaturated = false,
            sectorDists = mapOf("LEFT" to 200.0f, "CENTER" to 200.0f, "RIGHT" to 200.0f),
            allObstacles = emptyList(), isValid = true, spatialBins = bins, timestampNanos = 10_000_000_000L
        )
        val adv = estimateDirectionalAdvisory(depth, threat = "SAFE", nowNanos = 10_000_000_000L)
        assertEquals("AVAILABLE", adv.state)
        assertEquals(0.0f, adv.angleDeg ?: -999.0f, 0.01f)
    }

    @Test
    fun test02_nearSidewalls() {
        val tensor = createBaseTensor(fillVal = 180.0f)
        val w = 192
        // Left wall cols 0..50 (raw 750)
        for (y in 0 until 256) {
            for (x in 0..49) tensor[y * w + x] = 750.0f
        }
        // Right wall cols 142..192 (raw 750)
        for (y in 0 until 256) {
            for (x in 142 until 192) tensor[y * w + x] = 750.0f
        }

        val bins = DepthEngine.computeSpatialBins(tensor, w = 192, h = 256, numBins = 24)

        val depth = DepthResult(
            rawDisparity = tensor, width = 192, height = 256, distCm = 200.0f,
            pan = 0.0f, proximity = 0.2f, uncertaintyScore = 0.1f, isSaturated = false,
            sectorDists = mapOf("LEFT" to 28.0f, "CENTER" to 200.0f, "RIGHT" to 28.0f),
            allObstacles = emptyList(), isValid = true, spatialBins = bins, timestampNanos = 10_000_000_000L
        )
        val adv = estimateDirectionalAdvisory(depth, threat = "SAFE", nowNanos = 10_000_000_000L)
        assertEquals("AVAILABLE", adv.state)
        assertTrue(abs(adv.angleDeg ?: 999.0f) <= 3.0f)
    }

    @Test
    fun test03_narrowOpeningBelowClearance() {
        val tensor = createBaseTensor(fillVal = 180.0f)
        val w = 192
        // Obstacles block left cols 0..80 and right cols 112..192, central opening only 32px (4 bins = 10.8 deg < clearance)
        for (y in 51..165) {
            for (x in 0..79) tensor[y * w + x] = 750.0f
            for (x in 112 until 192) tensor[y * w + x] = 750.0f
        }

        val obsL = Obstacle(1, 40, 108, Rect(0, 51, 80, 166), -0.5f, 28.0f, 0.9f, 0.1f, isWall = true)
        val obsR = Obstacle(2, 152, 108, Rect(112, 51, 192, 166), 0.5f, 28.0f, 0.9f, 0.1f, isWall = true)
        val bins = DepthEngine.computeSpatialBins(tensor, w = 192, h = 256, detectedList = listOf(obsL, obsR), numBins = 24)

        val depth = DepthResult(
            rawDisparity = tensor, width = 192, height = 256, distCm = 28.0f,
            pan = 0.0f, proximity = 0.9f, uncertaintyScore = 0.1f, isSaturated = false,
            sectorDists = mapOf("LEFT" to 28.0f, "CENTER" to 28.0f, "RIGHT" to 28.0f),
            allObstacles = listOf(obsL, obsR), isValid = true, spatialBins = bins, timestampNanos = 10_000_000_000L
        )
        val adv = estimateDirectionalAdvisory(depth, threat = "CRITICAL", nowNanos = 10_000_000_000L)
        assertEquals("STOP", adv.state)
    }

    @Test
    fun test04_centralNearObstruction() {
        val tensor = createBaseTensor(fillVal = 180.0f)
        val w = 192
        // Center block cols 72..120 high disparity ~55cm (raw 600)
        for (y in 51..165) {
            for (x in 72..119) tensor[y * w + x] = 600.0f
        }

        val obsItem = Obstacle(1, 96, 108, Rect(72, 51, 120, 166), 0.0f, 55.0f, 0.7f, 0.1f)
        val bins = DepthEngine.computeSpatialBins(tensor, w = 192, h = 256, detectedList = listOf(obsItem), numBins = 24)

        val depth = DepthResult(
            rawDisparity = tensor, width = 192, height = 256, distCm = 55.0f,
            pan = 0.0f, proximity = 0.7f, uncertaintyScore = 0.1f, isSaturated = false,
            sectorDists = mapOf("LEFT" to 200.0f, "CENTER" to 55.0f, "RIGHT" to 200.0f),
            allObstacles = listOf(obsItem), isValid = true, spatialBins = bins, timestampNanos = 10_000_000_000L
        )
        val adv = estimateDirectionalAdvisory(depth, threat = "WARNING", nowNanos = 10_000_000_000L)
        assertEquals("AVAILABLE", adv.state)
        assertTrue("Must steer away from central obstruction", abs(adv.angleDeg ?: 0.0f) >= 5.0f)
    }

    @Test
    fun test05_invalidOuterBins() {
        val tensor = createBaseTensor(fillVal = 180.0f)
        val w = 192
        // Left 24 cols (first 3 bins) and right 24 cols (last 3 bins) NaN
        for (y in 0 until 256) {
            for (x in 0..23) tensor[y * w + x] = Float.NaN
            for (x in 168 until 192) tensor[y * w + x] = Float.NaN
        }

        val bins = DepthEngine.computeSpatialBins(tensor, w = 192, h = 256, numBins = 24)
        assertFalse(bins[0].isValid)
        assertFalse(bins[1].isValid)
        assertFalse(bins[2].isValid)
        assertFalse(bins[21].isValid)
        assertFalse(bins[22].isValid)
        assertFalse(bins[23].isValid)
        assertTrue(bins[11].isValid)
        assertTrue(bins[12].isValid)

        val depth = DepthResult(
            rawDisparity = tensor, width = 192, height = 256, distCm = 180.0f,
            pan = 0.0f, proximity = 0.2f, uncertaintyScore = 0.2f, isSaturated = false,
            sectorDists = mapOf("LEFT" to Float.NaN, "CENTER" to 180.0f, "RIGHT" to Float.NaN),
            allObstacles = emptyList(), isValid = true, spatialBins = bins, timestampNanos = 10_000_000_000L
        )
        val adv = estimateDirectionalAdvisory(depth, threat = "SAFE", nowNanos = 10_000_000_000L)
        assertEquals("AVAILABLE", adv.state)
        assertEquals(0.0f, adv.angleDeg ?: -999.0f, 0.01f)
    }

    @Test
    fun test06_invalidCentralBins() {
        val tensor = createBaseTensor(fillVal = 180.0f)
        val w = 192
        // Center cols 88..104 (bins 11, 12) NaN
        for (y in 0 until 256) {
            for (x in 88..103) tensor[y * w + x] = Float.NaN
        }

        val bins = DepthEngine.computeSpatialBins(tensor, w = 192, h = 256, numBins = 24)
        assertFalse(bins[11].isValid)
        assertFalse(bins[12].isValid)

        val depth = DepthResult(
            rawDisparity = tensor, width = 192, height = 256, distCm = Float.NaN,
            pan = 0.0f, proximity = 0.0f, uncertaintyScore = 0.9f, isSaturated = false,
            sectorDists = mapOf("LEFT" to 200.0f, "CENTER" to Float.NaN, "RIGHT" to 200.0f),
            allObstacles = emptyList(), isValid = true, spatialBins = bins, timestampNanos = 10_000_000_000L
        )
        val adv = estimateDirectionalAdvisory(depth, threat = "SAFE", nowNanos = 10_000_000_000L)
        assertEquals("UNAVAILABLE", adv.state)
    }

    @Test
    fun test07_upperHazardMultiBand() {
        val tensor = createBaseTensor(fillVal = 180.0f)
        val w = 192
        // Top 40 rows high disparity ~40cm (raw 650)
        for (y in 0..39) {
            for (x in 0 until w) tensor[y * w + x] = 650.0f
        }

        val obsItem = Obstacle(1, 96, 20, Rect(30, 0, 162, 40), 0.0f, 40.0f, 0.8f, 0.1f, modeText = "OVERHEAD")
        val bins = DepthEngine.computeSpatialBins(tensor, w = 192, h = 256, detectedList = listOf(obsItem), numBins = 24)
        assertTrue(bins.any { it.overheadDistCm.isFinite() && it.overheadDistCm < 60.0f })

        val depth = DepthResult(
            rawDisparity = tensor, width = 192, height = 256, distCm = 40.0f,
            pan = 0.0f, proximity = 0.8f, uncertaintyScore = 0.1f, isSaturated = false,
            sectorDists = mapOf("LEFT" to 40.0f, "CENTER" to 40.0f, "RIGHT" to 40.0f),
            allObstacles = listOf(obsItem), isValid = true, overheadHazard = true, modeText = "OVERHEAD",
            spatialBins = bins, timestampNanos = 10_000_000_000L
        )
        val adv = estimateDirectionalAdvisory(depth, threat = "CRITICAL", nowNanos = 10_000_000_000L)
        assertEquals("STOP", adv.state)
    }

    @Test
    fun test08_lowObstructionMultiBand() {
        val tensor = createBaseTensor(fillVal = 180.0f)
        val w = 192
        // Ground band (rows 166..217) high disparity ~30cm (raw 700)
        for (y in 166..217) {
            for (x in 72..119) tensor[y * w + x] = 700.0f
        }

        val bins = DepthEngine.computeSpatialBins(tensor, w = 192, h = 256, numBins = 24)
        assertTrue(bins.any { it.groundDistCm.isFinite() && it.groundDistCm < 50.0f })
    }

    @Test
    fun test09_partlyVisibleLateralObject() {
        val tensor = createBaseTensor(fillVal = 180.0f)
        val w = 192
        // Right edge obstacle cols 160..192 (raw 600)
        for (y in 51..165) {
            for (x in 160 until 192) tensor[y * w + x] = 600.0f
        }

        val obsItem = Obstacle(1, 176, 108, Rect(160, 51, 192, 166), 0.8f, 55.0f, 0.6f, 0.15f)
        val bins = DepthEngine.computeSpatialBins(tensor, w = 192, h = 256, detectedList = listOf(obsItem), numBins = 24)

        val depth = DepthResult(
            rawDisparity = tensor, width = 192, height = 256, distCm = 180.0f,
            pan = 0.0f, proximity = 0.3f, uncertaintyScore = 0.1f, isSaturated = false,
            sectorDists = mapOf("LEFT" to 200.0f, "CENTER" to 180.0f, "RIGHT" to 55.0f),
            allObstacles = listOf(obsItem), isValid = true, spatialBins = bins, timestampNanos = 10_000_000_000L
        )
        val adv = estimateDirectionalAdvisory(depth, threat = "WARNING", nowNanos = 10_000_000_000L)
        assertEquals("AVAILABLE", adv.state)
        assertTrue(abs(adv.angleDeg ?: 999.0f) <= 15.0f)
    }

    @Test
    fun test10_entirelyInvalidTensor() {
        val tensor = FloatArray(192 * 256) { Float.NaN }
        val bins = DepthEngine.computeSpatialBins(tensor, w = 192, h = 256, numBins = 24)
        assertTrue(bins.all { !it.isValid })

        val depth = DepthResult(
            rawDisparity = tensor, width = 0, height = 0, distCm = Float.NaN,
            pan = 0.0f, proximity = 0.0f, uncertaintyScore = 1.0f, isSaturated = false,
            sectorDists = emptyMap(), allObstacles = emptyList(), isValid = false,
            spatialBins = bins, timestampNanos = 10_000_000_000L
        )
        val adv = estimateDirectionalAdvisory(depth, threat = "SENSOR_FAULT", nowNanos = 10_000_000_000L)
        assertEquals("UNKNOWN", adv.state)
    }
}
