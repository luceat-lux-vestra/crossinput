package com.crossinput.helper

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method

/**
 * Research-only issue #145 probe.
 *
 * Runs under the exact adb shell/app_process identity used by the production
 * helper. It answers only whether that identity can create a display-scoped
 * gesture input monitor. A successful monitor is disposed immediately.
 *
 * No input events, coordinates, key data, clipboard data, or HID payloads are
 * received or logged by this probe.
 */
object InputMonitorProbeMain {
    private const val MONITOR_INPUT = "android.permission.MONITOR_INPUT"
    private const val MONITOR_NAME = "CrossInputBoundaryProbe"

    @JvmStatic
    fun main(vararg args: String) {
        val displayId = args.singleOrNull()?.toIntOrNull()
        if (displayId == null || displayId < 0) {
            System.err.println("PROBE_RESULT=INVALID_ARGUMENT expected_display_id")
            return
        }

        val context = systemContext()
        if (context == null) {
            System.err.println("PROBE_RESULT=NO_SYSTEM_CONTEXT")
            return
        }

        val uid = Process.myUid()
        val pid = Process.myPid()
        val permission = context.checkPermission(MONITOR_INPUT, pid, uid)
        val permissionText =
            if (permission == PackageManager.PERMISSION_GRANTED) "granted" else "denied"

        System.err.println(
            "PROBE_ENV sdk=${Build.VERSION.SDK_INT} model=${sanitize(Build.MODEL)} " +
                "uid=$uid displayId=$displayId monitorInput=$permissionText",
        )

        val attempts = listOf(
            ::probeContextInputManager,
            ::probeInputManagerGlobal,
        )
        var lastUnavailable: ProbeOutcome.Unavailable? = null

        for (attempt in attempts) {
            when (val outcome = attempt(context, displayId)) {
                is ProbeOutcome.Allowed -> {
                    System.err.println(
                        "PROBE_RESULT=ALLOWED api=${outcome.api} " +
                            "monitorClass=${sanitize(outcome.monitorClass)}",
                    )
                    return
                }

                is ProbeOutcome.Denied -> {
                    System.err.println(
                        "PROBE_RESULT=DENIED api=${outcome.api} " +
                            "exception=${outcome.exceptionClass} " +
                            "message=${sanitize(outcome.message)}",
                    )
                    return
                }

                is ProbeOutcome.Unavailable -> lastUnavailable = outcome
            }
        }

        val unavailable = lastUnavailable
        System.err.println(
            "PROBE_RESULT=UNAVAILABLE " +
                "exception=${unavailable?.exceptionClass ?: "none"} " +
                "message=${sanitize(unavailable?.message)}",
        )
    }

    private fun probeContextInputManager(context: Context, displayId: Int): ProbeOutcome {
        return try {
            val manager = context.getSystemService(Context.INPUT_SERVICE)
                ?: return ProbeOutcome.Unavailable(
                    "context-input-manager",
                    "NoInputManager",
                    "Context.INPUT_SERVICE returned null",
                )
            val klass = Class.forName("android.hardware.input.InputManager")
            val method = klass.getMethod(
                "monitorGestureInput",
                String::class.java,
                Integer.TYPE,
            )
            invokeAndDispose(
                api = "InputManager.monitorGestureInput",
                target = manager,
                method = method,
                arguments = arrayOf(MONITOR_NAME, displayId),
            )
        } catch (t: Throwable) {
            classifyFailure("InputManager.monitorGestureInput", t)
        }
    }

    /**
     * Newer Android releases moved client plumbing behind InputManagerGlobal.
     * The S10 5G evidence baseline is Android 12, so this is only a forward-
     * compatibility fallback for the research probe.
     */
    private fun probeInputManagerGlobal(context: Context, displayId: Int): ProbeOutcome {
        @Suppress("UNUSED_PARAMETER")
        val keepContextForUniformSignature = context
        return try {
            val klass = Class.forName("android.hardware.input.InputManagerGlobal")
            val instance = klass.getMethod("getInstance").invoke(null)
                ?: return ProbeOutcome.Unavailable(
                    "InputManagerGlobal.monitorGestureInput",
                    "NoInputManagerGlobal",
                    "getInstance returned null",
                )
            val method = klass.getMethod(
                "monitorGestureInput",
                String::class.java,
                Integer.TYPE,
            )
            invokeAndDispose(
                api = "InputManagerGlobal.monitorGestureInput",
                target = instance,
                method = method,
                arguments = arrayOf(MONITOR_NAME, displayId),
            )
        } catch (t: Throwable) {
            classifyFailure("InputManagerGlobal.monitorGestureInput", t)
        }
    }

    private fun invokeAndDispose(
        api: String,
        target: Any,
        method: Method,
        arguments: Array<Any>,
    ): ProbeOutcome {
        val monitor = try {
            method.invoke(target, *arguments)
                ?: return ProbeOutcome.Unavailable(api, "NullMonitor", "monitor creation returned null")
        } catch (t: Throwable) {
            return classifyFailure(api, t)
        }

        return try {
            val monitorClass = monitor.javaClass.name
            val dispose = monitor.javaClass.methods.firstOrNull {
                it.name == "dispose" && it.parameterCount == 0
            } ?: monitor.javaClass.declaredMethods.firstOrNull {
                it.name == "dispose" && it.parameterCount == 0
            }
            if (dispose == null) {
                ProbeOutcome.Unavailable(api, "NoDisposeMethod", monitorClass)
            } else {
                dispose.isAccessible = true
                dispose.invoke(monitor)
                ProbeOutcome.Allowed(api, monitorClass)
            }
        } catch (t: Throwable) {
            classifyFailure("$api.dispose", t)
        }
    }

    private fun classifyFailure(api: String, throwable: Throwable): ProbeOutcome {
        val cause = unwrap(throwable)
        val exceptionClass = cause.javaClass.simpleName.ifEmpty { cause.javaClass.name }
        val message = cause.message
        return if (cause is SecurityException) {
            ProbeOutcome.Denied(api, exceptionClass, message)
        } else {
            ProbeOutcome.Unavailable(api, exceptionClass, message)
        }
    }

    private fun unwrap(throwable: Throwable): Throwable {
        var current = throwable
        while (current is InvocationTargetException && current.targetException != null) {
            current = current.targetException
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

    private fun sanitize(value: String?): String =
        value
            ?.replace(Regex("[\\r\\n\\t]+"), " ")
            ?.take(160)
            ?: "none"

    private sealed interface ProbeOutcome {
        data class Allowed(val api: String, val monitorClass: String) : ProbeOutcome
        data class Denied(
            val api: String,
            val exceptionClass: String,
            val message: String?,
        ) : ProbeOutcome
        data class Unavailable(
            val api: String,
            val exceptionClass: String,
            val message: String?,
        ) : ProbeOutcome
    }
}
