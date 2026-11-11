package com.hghub.huangguo

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager

/** A window preference, never a forced display mode or a separate frame clock. */
internal class DisplayRefreshPolicy(private val activity: Activity) :
    DisplayManager.DisplayListener {
    private val displays = activity.getSystemService(DisplayManager::class.java)
    private val power = activity.getSystemService(PowerManager::class.java)
    private var listening = false
    private val powerChanges = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = update()
    }

    fun start() {
        if (listening) return
        listening = true
        displays.registerDisplayListener(this, Handler(Looper.getMainLooper()))
        val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) {
            activity.registerReceiver(powerChanges, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            activity.registerReceiver(powerChanges, filter)
        }
        update()
    }

    fun stop() {
        if (!listening) return
        listening = false
        displays.unregisterDisplayListener(this)
        activity.unregisterReceiver(powerChanges)
        apply(0f)
    }

    fun update() {
        if (!listening || !activity.hasWindowFocus() || power.isPowerSaveMode) {
            apply(0f)
            return
        }
        // The attached display also handles external screens and foldables.
        val display = activity.window.decorView.display ?: return
        val current = display.mode
        val rate = display.supportedModes.asSequence()
            .filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            .map { it.refreshRate }
            .filter { it.isFinite() && it > 0f }
            .maxOrNull() ?: 0f
        apply(rate)
    }

    private fun apply(rate: Float) {
        val attributes = activity.window.attributes
        if (attributes.preferredRefreshRate == rate) return
        // Do not set preferredDisplayModeId: resolution and system power/thermal
        // limits remain under the compositor's control. 0 restores OS policy.
        attributes.preferredRefreshRate = rate
        activity.window.attributes = attributes
    }

    override fun onDisplayChanged(displayId: Int) {
        if (activity.window.decorView.display?.displayId == displayId) update()
    }

    override fun onDisplayAdded(displayId: Int) = update()
    override fun onDisplayRemoved(displayId: Int) = update()
}
