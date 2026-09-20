package com.crossinput.helper

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Looper
import android.util.DisplayMetrics
import kotlin.math.max

internal object VirtualMouseCursorRegion {
    private const val DEFAULT_EDGE_THRESHOLD_PX = 16

    fun classify(
        x: Float,
        y: Float,
        width: Int,
        height: Int,
        thresholdPx: Int = DEFAULT_EDGE_THRESHOLD_PX,
    ): String? {
        if (!x.isFinite() || !y.isFinite() || width <= 0 || height <= 0 || thresholdPx < 0) {
            return null
        }
        if (x < 0f || y < 0f || x > (width - 1).toFloat() || y > (height - 1).toFloat()) {
            return null
        }

        val threshold = max(0, thresholdPx).toFloat()
        val regions = buildList {
            if (x <= threshold) add("left")
            if (x >= (width - 1).toFloat() - threshold) add("right")
            if (y <= threshold) add("top")
            if (y >= (height - 1).toFloat() - threshold) add("bottom")
        }
        return if (regions.isEmpty()) "interior" else regions.joinToString("+")
    }
}

/**
 * Bounded issue #145 capability probe.
 *
 * This intentionally uses reflection because VirtualDevice / VirtualMouse are
 * system APIs and CrossInput must not compile production code against a
 * device-specific hidden surface before the physical capability gate passes.
 *
 * The probe never prints raw cursor coordinates. It only reports whether the
 * selected display cursor position is readable and a coarse edge region.
 *
 * Args:
 *   <association-id> <display-id>
 *
 * The caller owns temporary CDM association setup/cleanup.
 */
object VirtualMouseCursorProbeMain {
    private const val SHELL_PACKAGE = "com.android.shell"
    private const val PROBE_DEVICE_NAME = "CrossInput #145 Cursor Probe"

    @JvmStatic
    fun main(args: Array<String>) {
        if (Looper.myLooper() == null) {
            Looper.prepare()
        }

        val associationId = args.getOrNull(0)?.toIntOrNull()
        val displayId = args.getOrNull(1)?.toIntOrNull()
        if (associationId == null || associationId <= 0 || displayId == null || displayId < 0) {
            fail("invalid-arguments")
            return
        }

        val systemContext = systemContext()
        if (systemContext == null) {
            fail("system-context-unavailable")
            return
        }

        val display = systemContext.getSystemService(DisplayManager::class.java)?.getDisplay(displayId)
        if (display == null) {
            fail("display-unavailable")
            return
        }

        val metrics = DisplayMetrics()
        display.getRealMetrics(metrics)
        if (metrics.widthPixels <= 0 || metrics.heightPixels <= 0) {
            fail("invalid-display-metrics")
            return
        }

        var virtualMouse: Any? = null
        var virtualDevice: Any? = null
        try {
            val shellContext = systemContext.createPackageContext(
                SHELL_PACKAGE,
                Context.CONTEXT_IGNORE_SECURITY,
            )

            val managerClass = Class.forName("android.companion.virtual.VirtualDeviceManager")
            val manager = Context::class.java
                .getMethod("getSystemService", Class::class.java)
                .invoke(shellContext, managerClass)
                ?: run {
                    fail("virtual-device-service-unavailable")
                    return
                }

            val paramsClass = Class.forName("android.companion.virtual.VirtualDeviceParams")
            val paramsBuilderClass = Class.forName(
                "android.companion.virtual.VirtualDeviceParams\$Builder",
            )
            val paramsBuilder = paramsBuilderClass.getConstructor().newInstance()
            paramsBuilderClass.methods
                .firstOrNull { it.name == "setName" && it.parameterCount == 1 }
                ?.invoke(paramsBuilder, PROBE_DEVICE_NAME)
            val params = paramsBuilderClass.getMethod("build").invoke(paramsBuilder)

            virtualDevice = managerClass
                .getMethod("createVirtualDevice", Int::class.javaPrimitiveType!!, paramsClass)
                .invoke(manager, associationId, params)

            val mouseConfigClass = Class.forName("android.hardware.input.VirtualMouseConfig")
            val mouseBuilderClass = Class.forName(
                "android.hardware.input.VirtualMouseConfig\$Builder",
            )
            val mouseBuilder = mouseBuilderClass.getConstructor().newInstance()
            invokeBuilder(mouseBuilderClass, mouseBuilder, "setVendorId", 0x4358)
            invokeBuilder(mouseBuilderClass, mouseBuilder, "setProductId", 0x1450)
            invokeBuilder(mouseBuilderClass, mouseBuilder, "setInputDeviceName", PROBE_DEVICE_NAME)
            invokeBuilder(mouseBuilderClass, mouseBuilder, "setAssociatedDisplayId", displayId)
            val mouseConfig = mouseBuilderClass.getMethod("build").invoke(mouseBuilder)

            virtualMouse = virtualDevice.javaClass
                .getMethod("createVirtualMouse", mouseConfigClass)
                .invoke(virtualDevice, mouseConfig)

            val point = virtualMouse.javaClass.getMethod("getCursorPosition").invoke(virtualMouse)
            val pointClass = Class.forName("android.graphics.PointF")
            val x = pointClass.getField("x").getFloat(point)
            val y = pointClass.getField("y").getFloat(point)

            val region = VirtualMouseCursorRegion.classify(
                x = x,
                y = y,
                width = metrics.widthPixels,
                height = metrics.heightPixels,
            )
            if (region == null) {
                fail("cursor-position-invalid")
                return
            }

            println(
                "VIRTUAL_MOUSE_CURSOR_PROBE result=PASS " +
                    "display_id=$displayId region=$region " +
                    "display=${metrics.widthPixels}x${metrics.heightPixels}",
            )
        } catch (t: Throwable) {
            val cause = rootCause(t)
            val reason = when (cause) {
                is SecurityException -> "permission-denied"
                is ClassNotFoundException, is NoSuchMethodException -> "api-unavailable"
                else -> "virtual-mouse-unavailable"
            }
            System.err.println(
                "VIRTUAL_MOUSE_CURSOR_PROBE result=FAIL " +
                    "reason=$reason cause=${cause.javaClass.simpleName}",
            )
        } finally {
            closeReflectively(virtualMouse)
            closeReflectively(virtualDevice)
        }
    }

    private fun invokeBuilder(
        builderClass: Class<*>,
        builder: Any,
        methodName: String,
        value: Any,
    ) {
        val method = builderClass.methods.firstOrNull {
            it.name == methodName && it.parameterCount == 1
        } ?: throw NoSuchMethodException(methodName)
        method.invoke(builder, value)
    }

    private fun closeReflectively(value: Any?) {
        if (value == null) return
        try {
            value.javaClass.getMethod("close").invoke(value)
        } catch (_: Throwable) {
        }
    }

    private fun rootCause(t: Throwable): Throwable {
        var current = t
        while (current.cause != null && current.cause !== current) {
            current = current.cause!!
        }
        return current
    }

    private fun systemContext(): Context? {
        return try {
            val klass = Class.forName("android.app.ActivityThread")
            val thread = klass.getMethod("systemMain").invoke(null)
            klass.getMethod("getSystemContext").invoke(thread) as Context
        } catch (_: Throwable) {
            null
        }
    }

    private fun fail(reason: String) {
        System.err.println("VIRTUAL_MOUSE_CURSOR_PROBE result=FAIL reason=$reason")
    }
}
