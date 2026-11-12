package com.horuseyes.app

import android.graphics.Rect
import com.horuseyes.app.vision.*
import com.horuseyes.app.kinematics.*
import com.horuseyes.app.budget.*
import com.horuseyes.app.ui.DirectionalAdvisory
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
}
