package com.horuseyes.app

import android.graphics.Rect
import com.horuseyes.app.ui.estimateDirectionalAdvisory
import com.horuseyes.app.vision.DepthResult
import com.horuseyes.app.vision.Obstacle
import com.horuseyes.app.vision.SpatialBin
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.InputStreamReader

class DirectionalGoldenTest {

    private fun loadJson(): JSONObject {
        val stream = javaClass.classLoader?.getResourceAsStream("golden_directional_scenarios.json")
        val content = if (stream != null) {
            InputStreamReader(stream, Charsets.UTF_8).use { it.readText() }
        } else {
            val file = File("../../tests/golden_directional_scenarios.json")
            if (file.exists()) file.readText(Charsets.UTF_8)
            else File("tests/golden_directional_scenarios.json").readText(Charsets.UTF_8)
        }
        return JSONObject(content)
    }

    @Test
    fun testAll16GoldenDirectionalScenarios() {
        val root = loadJson()
        val scenarios = root.getJSONArray("scenarios")
        assertEquals("Must contain 16 golden scenarios", 16, scenarios.length())

        for (i in 0 until scenarios.length()) {
            val s = scenarios.getJSONObject(i)
            val id = s.getInt("id")
            val name = s.getString("name")
            val threat = s.getString("threat")
            val camW = s.getInt("cam_width")
            val camH = s.getInt("cam_height")
            val hfovDeg = s.getDouble("hfov_deg").toFloat()
            val prevAngle = if (s.isNull("prev_angle")) null else s.getDouble("prev_angle").toFloat()
            val nowSec = s.getDouble("now")
            val nowNanos = (nowSec * 1_000_000_000.0).toLong()
            val isValid = s.getBoolean("is_valid")

            // Spatial bins
            val binsJson = s.getJSONArray("spatial_bins")
            val spatialBins = ArrayList<SpatialBin>()
            for (bIdx in 0 until binsJson.length()) {
                val b = binsJson.getJSONObject(bIdx)
                val distCm = if (b.isNull("dist_cm")) Float.NaN else b.getDouble("dist_cm").toFloat()
                spatialBins.add(
                    SpatialBin(
                        binId = b.getInt("bin_id"),
                        angleMin = b.getDouble("angle_min").toFloat(),
                        angleMax = b.getDouble("angle_max").toFloat(),
                        angleCenter = b.getDouble("angle_center").toFloat(),
                        validRatio = b.getDouble("valid_ratio").toFloat(),
                        rawDepthStatistic = if (b.isNull("raw_depth_statistic")) Float.NaN else b.getDouble("raw_depth_statistic").toFloat(),
                        estimatedDistanceCm = distCm,
                        isValid = b.getBoolean("is_valid"),
                        hasObstacle = if (b.has("has_obstacle")) b.getBoolean("has_obstacle") else false
                    )
                )
            }

            // Obstacles
            val obsJson = s.getJSONArray("all_obstacles")
            val obstacles = ArrayList<Obstacle>()
            for (oIdx in 0 until obsJson.length()) {
                val o = obsJson.getJSONObject(oIdx)
                val bboxArr = o.getJSONArray("bbox")
                val bx = bboxArr.getInt(0)
                val by = bboxArr.getInt(1)
                val bw = bboxArr.getInt(2)
                val bh = bboxArr.getInt(3)
                obstacles.add(
                    Obstacle(
                        id = o.getInt("id"),
                        x = o.getInt("x"),
                        y = o.getInt("y"),
                        bbox = Rect(bx, by, bx + bw, by + bh),
                        pan = o.getDouble("pan").toFloat(),
                        distCm = o.getDouble("dist_cm").toFloat(),
                        proximity = o.getDouble("proximity").toFloat(),
                        uncertaintyScore = o.getDouble("uncertainty_score").toFloat(),
                        isWall = o.getBoolean("is_wall"),
                        modeText = o.getString("mode_text")
                    )
                )
            }

            // Sector dists
            val secJson = s.getJSONObject("sector_dists")
            val secDists = mutableMapOf<String, Float>()
            for (key in secJson.keys()) {
                if (!secJson.isNull(key)) {
                    secDists[key] = secJson.getDouble(key).toFloat()
                }
            }

            val depth = DepthResult(
                rawDisparity = floatArrayOf(1f),
                width = camW,
                height = camH,
                distCm = secDists["CENTER"] ?: 200f,
                pan = 0f,
                proximity = 0.5f,
                uncertaintyScore = 0.1f,
                isSaturated = false,
                sectorDists = secDists,
                allObstacles = obstacles,
                isValid = isValid,
                spatialBins = spatialBins,
                timestampNanos = (s.getDouble("obs_timestamp") * 1_000_000_000.0).toLong()
            )

            val adv = estimateDirectionalAdvisory(
                depth = depth,
                threat = threat,
                nowNanos = nowNanos,
                hfovDeg = hfovDeg,
                prevAngle = prevAngle
            )

            val expected = s.getJSONObject("expected")
            val expectedState = expected.getString("state")
            assertEquals("Scenario $id ($name) state mismatch", expectedState, adv.state)

            if (expectedState == "AVAILABLE") {
                assertNotNull("Scenario $id ($name) expected angle", adv.angleDeg)
                val sign = expected.getString("direction_sign")
                when (sign) {
                    "FORWARD" -> assertTrue("Scenario $id ($name) expected FORWARD, got ${adv.angleDeg}", kotlin.math.abs(adv.angleDeg!!) <= 2.0f)
                    "LEFT" -> assertTrue("Scenario $id ($name) expected LEFT, got ${adv.angleDeg}", adv.angleDeg!! < 0.0f)
                    "RIGHT" -> assertTrue("Scenario $id ($name) expected RIGHT, got ${adv.angleDeg}", adv.angleDeg!! > 0.0f)
                }

                if (!expected.isNull("angle_range")) {
                    val rangeArr = expected.getJSONArray("angle_range")
                    val minA = rangeArr.getDouble(0).toFloat()
                    val maxA = rangeArr.getDouble(1).toFloat()
                    assertTrue("Scenario $id ($name) angle ${adv.angleDeg} outside range [$minA, $maxA]", adv.angleDeg!! in minA..maxA)
                }
            } else {
                assertNull("Scenario $id ($name) non-AVAILABLE state must have null angle", adv.angleDeg)
            }
        }
    }
}
