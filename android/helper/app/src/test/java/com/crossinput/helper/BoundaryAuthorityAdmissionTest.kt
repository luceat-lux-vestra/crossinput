package com.crossinput.helper

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BoundaryAuthorityAdmissionTest {
    @Test
    fun desktopTargetAcceptsCompositorAuthority() {
        assertTrue(
            BoundaryAuthorityAdmission.allows(
                compositorRequired = true,
                authority = PointerBoundaryAuthority.COMPOSITOR,
            ),
        )
    }

    @Test
    fun desktopTargetRejectsDeliveredCoordinateAuthority() {
        assertFalse(
            BoundaryAuthorityAdmission.allows(
                compositorRequired = true,
                authority = PointerBoundaryAuthority.DELIVERED_COORDINATES,
            ),
        )
    }

    @Test
    fun desktopTargetRejectsUnavailableAuthority() {
        assertFalse(
            BoundaryAuthorityAdmission.allows(
                compositorRequired = true,
                authority = PointerBoundaryAuthority.UNAVAILABLE,
            ),
        )
    }

    @Test
    fun explicitDisplayTargetKeepsDeliveredCoordinateAuthority() {
        assertTrue(
            BoundaryAuthorityAdmission.allows(
                compositorRequired = false,
                authority = PointerBoundaryAuthority.DELIVERED_COORDINATES,
            ),
        )
    }
}
