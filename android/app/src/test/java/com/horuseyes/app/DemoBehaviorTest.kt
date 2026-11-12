package com.horuseyes.app

import android.graphics.Rect
import com.horuseyes.app.vision.*
import com.horuseyes.app.kinematics.*
import com.horuseyes.app.budget.*
import com.horuseyes.app.ui.DirectionalAdvisory
import com.horuseyes.app.ui.estimateDirectionalAdvisory
import org.junit.Assert.*
import org.junit.Test

class DemoBehaviorTest {
    private fun obs(distance: Float = 30f, objects: Boolean = true) = DepthResult(
        floatArrayOf(1f),192,256,distance,0f,1f,.1f,false,
        mapOf("LEFT" to 250f,"CENTER" to distance,"RIGHT" to 250f),
        if(objects) listOf(Obstacle(1,96,128,Rect(76,98,116,158),0f,distance,1f,.1f)) else emptyList())

    @Test fun staticProximityHasUnknownTtc() {
        val kin=KinematicsEngine(); val budget=AuditoryBudgetManager()
        for (i in 1..12) {
            val o=obs();val k=kin.compute(o,10+i*.1f)
            assertEquals("CRITICAL",k.threatLevel);assertTrue(k.primaryTtc.isInfinite())
            assertTrue(budget.coordinate(o,k).isActive)
        }
    }

    @Test fun lostHazardSurvivesRotationAndEmptyAudioCandidates() {
        val kin=KinematicsEngine();val budget=AuditoryBudgetManager()
        kin.compute(obs(),10f)
        for(i in 1..20) {
            val o=obs(250f,false);val k=kin.compute(o,10+i*.1f,.6f)
            assertNotEquals("SAFE",k.threatLevel);assertTrue(k.primaryTtc.isInfinite())
            val d=budget.coordinate(o,k)
            if(i<=6) assertTrue(d.isActive)
            assertNotEquals("SAFE",d.threatLevel)
        }
    }

    @Test fun faultOverridesStandby() {
        val kin=KinematicsEngine();val k=kin.compute(obs(),10f).copy(threatLevel="UNRESOLVED_HAZARD",hazardState="LOST_UNRESOLVED",lostUnresolvedTimestamp=1.0,timestamp=10f)
        assertEquals("SYSTEM_FAULT_TONE",AuditoryBudgetManager().coordinate(obs().copy(isValid=false),k).cueMode)
    }

    @Test fun angleRequiresFreshObservedSupport() {
        val a=DirectionalAdvisory("AVAILABLE",20f,.8f,Pair(-30f,30f),10L)
        assertEquals(20f,a.drawableAngle(20L))
        assertNull(a.copy(angleDeg=60f).drawableAngle(20L))
        assertNull(a.drawableAngle(2_000_000_000L))
    }

    @Test fun directionalEstimatorSteersAwayFromHazards() {
        // 1. Clear corridor -> 0 degrees
        val clearDepth = DepthResult(
            floatArrayOf(1f), 192, 256, 250f, 0f, 0f, 0.1f, false,
            mapOf("LEFT" to 250f, "CENTER" to 250f, "RIGHT" to 250f), emptyList()
        )
        val clearAdv = estimateDirectionalAdvisory(clearDepth, "SAFE", 100L)
        assertEquals("AVAILABLE", clearAdv.state)
        assertEquals(0f, clearAdv.angleDeg ?: -999f, 0.01f)

        // 2. Right-side obstacle (cx=150, camW=192) -> angle < 0 (steer left)
        val rightObs = Obstacle(1, 150, 128, Rect(130, 98, 170, 158), 0.5f, 65f, 0.8f, 0.1f)
        val rightDepth = DepthResult(
            floatArrayOf(1f), 192, 256, 65f, 0.5f, 0.8f, 0.1f, false,
            mapOf("LEFT" to 250f, "CENTER" to 180f, "RIGHT" to 65f), listOf(rightObs)
        )
        val rightAdv = estimateDirectionalAdvisory(rightDepth, "WARNING", 100L)
        assertEquals("AVAILABLE", rightAdv.state)
        assertTrue("Right obstacle must steer left", (rightAdv.angleDeg ?: 0f) < 0f)

        // 3. Left-side obstacle (cx=40, camW=192) -> angle > 0 (steer right)
        val leftObs = Obstacle(2, 40, 128, Rect(20, 98, 60, 158), -0.5f, 65f, 0.8f, 0.1f)
        val leftDepth = DepthResult(
            floatArrayOf(1f), 192, 256, 65f, -0.5f, 0.8f, 0.1f, false,
            mapOf("LEFT" to 65f, "CENTER" to 180f, "RIGHT" to 250f), listOf(leftObs)
        )
        val leftAdv = estimateDirectionalAdvisory(leftDepth, "WARNING", 100L)
        assertEquals("AVAILABLE", leftAdv.state)
        assertTrue("Left obstacle must steer right", (leftAdv.angleDeg ?: 0f) > 0f)

        // 4. Completely obstructed -> STOP
        val blockedDepth = DepthResult(
            floatArrayOf(1f), 192, 256, 35f, 0f, 0.9f, 0.1f, false,
            mapOf("LEFT" to 40f, "CENTER" to 35f, "RIGHT" to 45f), listOf(rightObs)
        )
        val blockedAdv = estimateDirectionalAdvisory(blockedDepth, "CRITICAL", 100L)
        assertEquals("STOP", blockedAdv.state)
        assertNull(blockedAdv.angleDeg)
    }
}
