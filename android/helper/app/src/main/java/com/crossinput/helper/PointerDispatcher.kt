package com.crossinput.helper

import android.view.Display

/** Runtime choice for the semantic pointer backend. */
enum class PointerBackendMode(val token: String) {
    AUTO("auto"),
    UHID("uhid"),
    INPUT_MANAGER("input-manager");

    companion object {
        const val FLAG = "--pointer-backend"

        fun fromArgs(args: Array<out String>): Result<PointerBackendMode> {
            var mode = AUTO
            var i = 0
            while (i < args.size) {
                val arg = args[i]
                val token = when {
                    arg.startsWith("$FLAG=") -> arg.substringAfter('=')
                    arg == FLAG -> args.getOrNull(++i)
                        ?: return Result.failure(IllegalArgumentException("$FLAG requires a value (auto|uhid|input-manager)"))
                    else -> {
                        i++
                        continue
                    }
                }
                mode = entries.firstOrNull { it.token == token.lowercase() }
                    ?: return Result.failure(IllegalArgumentException("invalid $FLAG value: $token (expected auto|uhid|input-manager)"))
                i++
            }
            return Result.success(mode)
        }
    }
}

/**
 * Owns pointer backend selection and failover inside the Android helper.
 * macOS only sends semantic CXI v1 pointer events and never selects UHID
 * descriptors or report formats.
 *
 * AUTO prefers the system-routed UHID mouse for desktop sink targets so the
 * visible pointer sprite follows (injected InputManager events bypass
 * InputReader and never move it), and uses InputManager everywhere else.
 * Runtime failover to InputManager is sticky until the next SELECT_DISPLAY.
 */
class PointerDispatcher(
    private val log: Logger,
    private val uhid: UhidPointerInjector,
    private val inputManager: InputManagerPointerInjector,
    private val mode: PointerBackendMode = PointerBackendMode.AUTO,
    /**
     * Conservative heuristic for whether the target display is a desktop
     * system sink where the system-routed UHID mouse reaches the visible
     * pointer sprite. Must never throw; failures are treated as false.
     */
    private val isSystemRouteCandidate: (Display) -> Boolean = SystemRoutePolicy::isDesktopSink,
) : PointerInjector {
    override val supportsExplicitDisplayRouting: Boolean
        get() = when (mode) {
            PointerBackendMode.UHID -> uhid.supportsExplicitDisplayRouting
            PointerBackendMode.INPUT_MANAGER -> inputManager.supportsExplicitDisplayRouting
            PointerBackendMode.AUTO ->
                uhid.supportsExplicitDisplayRouting || inputManager.supportsExplicitDisplayRouting
        }

    private var selectedDisplay: Display? = null
    private var active: PointerInjector? = null

    @Synchronized
    override fun selectDisplay(display: Display): Boolean {
        selectedDisplay = display
        if (mode == PointerBackendMode.UHID) {
            // Forced UHID deliberately trades away explicit target routing.
            // Warn loudly and drive the system-routed device anyway instead of
            // failing; UhidPointerInjector.selectDisplay keeps its honest
            // target-specific semantics untouched.
            log.warn(TAG, "forced UHID ignores target ${display.displayId}; using system routing")
            return if (uhid.selectSystemRoute()) {
                active = uhid
                log.info(TAG, "pointer backend selected backend=uhid mode=${mode.token}")
                true
            } else {
                active = null
                log.error(TAG, "UHID pointer unavailable in forced mode")
                false
            }
        }

        // Desktop sink candidates route system-level mice through the native
        // InputReader pipeline (the visible pointer sprite follows the UHID
        // device), so prefer UHID there. FLAG_DESKTOP is a heuristic, not a
        // guarantee; every other target keeps explicit InputManager targeting.
        if (mode == PointerBackendMode.AUTO &&
            isSystemRouteCandidate(display) &&
            uhid.selectSystemRoute()
        ) {
            active = uhid
            log.info(
                TAG,
                "pointer backend selected backend=uhid mode=${mode.token} " +
                    "target=${display.displayId} routing=system",
            )
            return true
        }
        if (mode == PointerBackendMode.AUTO) uhid.close()

        if (inputManager.routing != PointerRouting.EXPLICIT_DISPLAY || !inputManager.selectDisplay(display)) {
            active = null
            log.error(TAG, "InputManager pointer backend unavailable")
            return false
        }
        active = inputManager
        log.info(TAG, "pointer backend selected backend=input-manager mode=${mode.token}")
        return true
    }

    @Synchronized
    override fun refreshMetrics(displayId: Int) {
        inputManager.refreshMetrics(displayId)
    }

    @Synchronized
    override fun moveRelative(dx: Int, dy: Int): PointerDelivery =
        deliver { it.moveRelative(dx, dy) }

    @Synchronized
    override fun button(button: Int, down: Boolean): PointerDelivery =
        deliver { it.button(button, down) }

    @Synchronized
    override fun scroll(horizontal: Float, vertical: Float): PointerDelivery =
        deliver { it.scroll(horizontal, vertical) }

    @Synchronized
    override fun close() {
        active?.close()
        if (active !== uhid) uhid.close()
        if (active !== inputManager) inputManager.close()
        active = null
        selectedDisplay = null
    }

    private fun deliver(send: (PointerInjector) -> PointerDelivery): PointerDelivery {
        val backend = active ?: return PointerDelivery.FAILED
        val result = send(backend)
        if (result.status != PointerDelivery.Status.FAILED || backend !== uhid || mode == PointerBackendMode.UHID) {
            if (result.status == PointerDelivery.Status.PARTIALLY_DELIVERED && backend === uhid) {
                activateFallback()
            }
            return result
        }

        // No UHID report was accepted. Fall back and retry this semantic event
        // exactly once; partial delivery is never retried.
        activateFallback()
        val fallback = active ?: return PointerDelivery.FAILED
        return send(fallback)
    }

    private fun activateFallback() {
        val display = selectedDisplay ?: run {
            active = null
            return
        }
        uhid.close()
        if (inputManager.routing == PointerRouting.EXPLICIT_DISPLAY && inputManager.selectDisplay(display)) {
            active = inputManager
            log.warn(TAG, "pointer backend failover backend=input-manager")
        } else {
            active = null
            log.error(TAG, "pointer backend failover unavailable")
        }
    }

    companion object {
        private const val TAG = "PointerDispatcher"
    }
}
