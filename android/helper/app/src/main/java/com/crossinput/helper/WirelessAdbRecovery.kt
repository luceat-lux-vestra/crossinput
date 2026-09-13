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

class WirelessAdbBootstrapActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "bootstrap activity started")
        val result = WirelessAdbRecoveryScheduler.schedule(this, source = "bootstrap")
        if (result != JobScheduler.RESULT_SUCCESS) {
            Log.w(TAG, "bootstrap schedule failed result=$result")
        }
        finish()
    }
}

class WirelessAdbRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_LOCKED_BOOT_COMPLETED && action != Intent.ACTION_BOOT_COMPLETED) {
            return
        }

        Log.i(TAG, "boot receiver invoked action=$action")
        val result = WirelessAdbRecoveryScheduler.schedule(context, source = action)
        if (result != JobScheduler.RESULT_SUCCESS) {
            Log.w(TAG, "boot schedule failed action=$action result=$result")
        }
    }
}

internal object WirelessAdbRecoveryScheduler {
    fun schedule(context: Context, source: String): Int {
        val scheduler = context.getSystemService(JobScheduler::class.java)
        if (scheduler == null) {
            Log.w(TAG, "scheduler unavailable source=$source")
            return JobScheduler.RESULT_FAILURE
        }
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
        val result = scheduler.schedule(job)
        Log.i(TAG, "job schedule requested source=$source result=$result")
        return result
    }
}

class WirelessAdbRecoveryJobService : JobService() {
    private val generation = AtomicInteger(0)

    @Volatile
    private var worker: Thread? = null

    override fun onStartJob(params: JobParameters): Boolean {
        val runGeneration = generation.incrementAndGet()
        Log.i(TAG, "recovery job started jobId=${params.jobId}")
        worker?.interrupt()
        worker = Thread({
            val outcome = try {
                val wifiConnected = AndroidWifiAvailability.isConnected(this)
                Log.i(TAG, "recovery precheck wifiConnected=$wifiConnected")
                WirelessAdbRecovery(
                    settingStore = AndroidWirelessAdbSettingStore(this),
                    wifiConnected = { wifiConnected },
                    sleep = Thread::sleep,
                ).run()
            } catch (_: InterruptedException) {
                Log.i(TAG, "recovery job interrupted")
                return@Thread
            } catch (t: Throwable) {
                Log.w(TAG, "recovery job failed transiently type=${t.javaClass.simpleName}")
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
                    Log.w(TAG, "wireless ADB recovery deferred outcome=${outcome.token}")
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
        Log.i(TAG, "recovery job stopped jobId=${params.jobId}")
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
