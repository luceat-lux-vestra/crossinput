package com.crossinput.helper

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PointerResultReplyPolicyTest {
    @Test
    fun requestIdZeroIsOneWay() {
        assertFalse(PointerResultReplyPolicy.shouldReply(0))
    }

    @Test
    fun correlatedRequestIdsStillReceivePointerResults() {
        assertTrue(PointerResultReplyPolicy.shouldReply(1))
        assertTrue(PointerResultReplyPolicy.shouldReply(Int.MAX_VALUE))
    }
}
