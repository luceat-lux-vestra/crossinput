package com.crossinput.helper

import android.app.Activity
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import java.util.concurrent.atomic.AtomicInteger

private const val TAG = "CrossInputWirelessAdb"
internal const val WIRELESS_ADB_SETTING_KEY = "adb_wifi_enabled"
internal const val WIRELESS_ADB_RECOVERY_JOB_ID = 0x43584941
internal const val WIRELESS_ADB_VERIFY_DELAY_MS = 3_000L
private const val WIRELESS_ADB_RETRY_BACKOFF_MS = 10_000L

/**
 * Explicit one-shot entry point used by the setup script after installation.
 *
 * Newly installed Android packages can remain in the stopped state until an
 * explicit component is launched. Starting this no-display Activity removes
 * that ambiguity, schedules the recovery job once, and immediately exits.
 */
class WirelessAdbBootstrapActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val result = WirelessAdbRecoveryScheduler.schedule(this)
        if (result != JobScheduler.RESULT_SUCCESS) {
            Log.w(TAG, "failed to schedule wireless ADB recovery job from bootstrap")
        }
        finish()
    }
}

/**
 * Boot hook for the opt-in installed helper package.
 *
 * The production input helper still runs through adb/app_process. Installing
 * this APK only adds the reboot recovery component needed by unattended
 * devices whose local screen cannot be used to re-enable Wireless debugging.
 */
class WirelessAdbRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_LOCKED_BOOT_COMPLETED && action != Intent.ACTION_BOOT_COMPLETED) {
            return
        }

        val result = WirelessAdbRecoveryScheduler.schedule(context)
        if (result != JobScheduler.RESULT_SUCCESS) {
            Log.w(TAG, "failed to schedule wireless ADB recovery job")
        }
    }
}

internal object WirelessAdbRecoveryScheduler {
    fun schedule(context: Context): Int {
        val scheduler = context.getSystemService(JobScheduler::class.java)
            ?: return JobScheduler.RESULT_FAILURE
        val job = JobInfo.Builder(
            WIRELESS_ADB_RECOVERY_JOB_ID,
            ComponentName(context, WirelessAdbRecoveryJobService::class.java),
        )
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPersisted(true)
            .setBackoffCriteria(
                WIRELESS_ADB_RETRY_BACKOFF_MS,
                JobInfo.BACKOFF_POLICY_EXPONENTIAL,
            )
            .build()
        return scheduler.schedule(job)
    }
}

/**
 * Runs after boot when Android reports some network connectivity.
 *
 * NETWORK_TYPE_ANY is only the JobScheduler wake-up constraint; the recovery
 * policy still requires an actual Wi-Fi transport before touching the setting.
 */
class WirelessAdbRecoveryJobService : JobService() {
    private val generation = AtomicInteger(0)

    @Volatile
    private var worker: Thread? = null

    override fun onStartJob(params: JobParameters): Boolean {
        val runGeneration = generation.incrementAndGet()
        worker?.interrupt()
        worker = Thread({
            val outcome = try {
                WirelessAdbRecovery(
                    settingStore = AndroidWirelessAdbSettingStore(this),
                    wifiConnected = { AndroidWifiAvailability.isConnected(this) },
                    sleep = Thread::sleep,
                ).run()
            } catch (_: InterruptedException) {
                return@Thread
            } catch (t: Throwable) {
                Log.w(TAG, "wireless ADB recovery failed transiently (${t.javaClass.simpleName})")
                WirelessAdbRecoveryOutcome.RETRY
            }

            if (generation.get() != runGeneration) return@Thread

            when (outcome) {
                WirelessAdbRecoveryOutcome.ENABLED,
                WirelessAdbRecoveryOutcome.ALREADY_ENABLED -> {
                    Log.i(TAG, "wireless ADB recovery succeeded outcome=${outcome.token}")
                    jobFinished(params, false)
                }

                WirelessAdbRecoveryOutcome.RETRY -> {
                    Log.w(TAG, "wireless ADB recovery deferred; retry requested")
                    jobFinished(params, true)
                }

                WirelessAdbRecoveryOutcome.PERMISSION_DENIED,
                WirelessAdbRecoveryOutcome.UNSUPPORTED -> {
                    Log.w(TAG, "wireless ADB recovery stopped outcome=${outcome.token}")
                    jobFinished(params, false)
                }
            }
        }, "cxi-wireless-adb-recovery").also { it.start() }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        generation.incrementAndGet()
        worker?.interrupt()
        worker = null
        return true
    }

    override fun onDestroy() {
        generation.incrementAndGet()
        worker?.interrupt()
        worker = null
        super.onDestroy()
    }
}

internal object AndroidWifiAvailability {
    fun isConnected(context: Context): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
        return manager.allNetworks.any { network ->
            manager.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }
}

internal interface WirelessAdbSettingStore {
    fun isSupported(): Boolean
    fun isEnabled(): Boolean
    fun setEnabled(enabled: Boolean): Boolean
}

/**
 * Isolates the non-public Settings.Global key used by Android's Wireless
 * debugging UI. The key is intentionally not allowed to leak beyond this
 * adapter; see ADR-0015.
 */
internal class AndroidWirelessAdbSettingStore(
    private val context: Context,
) : WirelessAdbSettingStore {
    override fun isSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

    override fun isEnabled(): Boolean =
        Settings.Global.getInt(context.contentResolver, WIRELESS_ADB_SETTING_KEY, 0) == 1

    override fun setEnabled(enabled: Boolean): Boolean =
        Settings.Global.putInt(
            context.contentResolver,
            WIRELESS_ADB_SETTING_KEY,
            if (enabled) 1 else 0,
        )
}

internal enum class WirelessAdbRecoveryOutcome(val token: String) {
    ENABLED("enabled"),
    ALREADY_ENABLED("already-enabled"),
    RETRY("retry"),
    PERMISSION_DENIED("permission-denied"),
    UNSUPPORTED("unsupported"),
}

/**
 * Pure recovery policy around the Android adapter.
 *
 * A successful write is verified after a short delay because Android may
 * immediately clear Wireless debugging again when Wi-Fi is not actually ready.
 */
internal class WirelessAdbRecovery(
    private val settingStore: WirelessAdbSettingStore,
    private val wifiConnected: () -> Boolean,
    private val sleep: (Long) -> Unit,
) {
    fun run(): WirelessAdbRecoveryOutcome {
        if (!settingStore.isSupported()) return WirelessAdbRecoveryOutcome.UNSUPPORTED
        if (!wifiConnected()) return WirelessAdbRecoveryOutcome.RETRY

        return try {
            if (settingStore.isEnabled()) {
                return WirelessAdbRecoveryOutcome.ALREADY_ENABLED
            }
            if (!settingStore.setEnabled(true)) {
                return WirelessAdbRecoveryOutcome.RETRY
            }

            sleep(WIRELESS_ADB_VERIFY_DELAY_MS)
            if (settingStore.isEnabled()) {
                WirelessAdbRecoveryOutcome.ENABLED
            } else {
                WirelessAdbRecoveryOutcome.RETRY
            }
        } catch (_: SecurityException) {
            WirelessAdbRecoveryOutcome.PERMISSION_DENIED
        }
    }
}
