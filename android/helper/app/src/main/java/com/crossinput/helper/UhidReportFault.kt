package com.crossinput.helper

import java.util.concurrent.atomic.AtomicLong

/**
 * Test-only deterministic UHID report fault injector (issue #60).
 *
 * Disabled unless an explicit N (> 0) is provided at helper startup
 * (`--fail-uhid-report=N`); the production path never constructs a non-zero
 * instance, so normal behavior is unchanged. When enabled, exactly the Nth
 * [com.crossinput.helper.HidDeviceManager.sendReport] attempt is failed at the
 * write boundary so the real error-handling path (injector cleanup, held-button
 * release, dispatcher failover) is exercised end-to-end instead of a simulated
 * copy of it. Counts attempts, not successes, so the trigger is deterministic
 * regardless of prior write outcomes. Metadata only — payloads are never
 * logged (AGENTS.md rule 4).
 */
class UhidReportFault(nth: Int) {
    val enabled: Boolean = nth > 0

    private val threshold: Long = nth.toLong()
    private val attempts = AtomicLong(0)

    /** True exactly once, on the Nth report-write attempt. */
    fun shouldFail(): Boolean = enabled && attempts.incrementAndGet() == threshold
}
