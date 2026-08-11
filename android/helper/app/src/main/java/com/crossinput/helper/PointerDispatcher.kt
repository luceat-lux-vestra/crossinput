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
 */
class PointerDispatcher(
    private val log: Logger,
    private val uhid: UhidPointerInjector,
    private val inputManager: InputManagerPointerInjector,
    private val mode: PointerBackendMode = PointerBackendMode.AUTO,
) : PointerInjector {
    override val supportsExplicitDisplayRouting: Boolean
        get() = inputManager.supportsExplicitDisplayRouting

    private var selectedDisplay: Display? = null
    private var active: PointerInjector? = null

    override fun selectDisplay(display: Display): Boolean {
        selectedDisplay = display
        val selected = when (mode) {
            PointerBackendMode.UHID -> if (uhid.routing == PointerRouting.EXPLICIT_DISPLAY && uhid.create()) uhid else null
            PointerBackendMode.INPUT_MANAGER -> inputManager
            // UHID cannot carry a selected display ID. For a target-selection
            // request, prefer only a backend that can make that routing
            // explicit; otherwise use InputManager directly.
            PointerBackendMode.AUTO -> if (uhid.routing == PointerRouting.EXPLICIT_DISPLAY && uhid.create()) uhid else null
        }
        if (selected != null && selected.selectDisplay(display)) {
            active = selected
            log.info(TAG, "pointer backend selected backend=${backendName(selected)} mode=${mode.token}")
            return true
        }

        if (mode == PointerBackendMode.UHID) {
            active = null
            log.error(TAG, "UHID cannot guarantee explicit target routing in forced mode")
            return false
        }
        if (selected !== inputManager) uhid.close()
        if (inputManager.routing != PointerRouting.EXPLICIT_DISPLAY || !inputManager.selectDisplay(display)) {
            active = null
            log.error(TAG, "InputManager pointer backend unavailable")
            return false
        }
        active = inputManager
        log.info(TAG, "pointer backend selected backend=input-manager mode=${mode.token}")
        return true
    }

    override fun refreshMetrics(displayId: Int) {
        inputManager.refreshMetrics(displayId)
    }

    override fun moveRelative(dx: Int, dy: Int): PointerDelivery =
        deliver { it.moveRelative(dx, dy) }

    override fun button(button: Int, down: Boolean): PointerDelivery =
        deliver { it.button(button, down) }

    override fun scroll(horizontal: Float, vertical: Float): PointerDelivery =
        deliver { it.scroll(horizontal, vertical) }

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

    private fun backendName(injector: PointerInjector): String = when (injector) {
        uhid -> "uhid"
        else -> "input-manager"
    }

    companion object {
        private const val TAG = "PointerDispatcher"
    }
}
