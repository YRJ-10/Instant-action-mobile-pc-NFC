package com.yeryi.nfc_instant_action

import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "instant_action/preferences"
    private var channel: MethodChannel? = null
    private var latestDeepLink: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        latestDeepLink = deepLinkFrom(intent)
        super.onCreate(savedInstanceState)
    }

    override fun getRenderMode(): RenderMode {
        return RenderMode.texture
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("instant_action", MODE_PRIVATE)

            when (call.method) {
                "loadConfig" -> {
                    result.success(
                        mapOf(
                            "baseUrl" to prefs.getString("baseUrl", ""),
                            "pairingToken" to prefs.getString("pairingToken", ""),
                            "deviceId" to prefs.getString("deviceId", ""),
                            "deviceToken" to prefs.getString("deviceToken", ""),
                            "pcId" to prefs.getString("pcId", ""),
                            "deviceName" to readableDeviceName()
                        )
                    )
                }
                "saveConfig" -> {
                    val args = call.arguments as Map<*, *>
                    prefs.edit()
                        .putString("baseUrl", args["baseUrl"] as? String ?: "")
                        .putString("pairingToken", args["pairingToken"] as? String ?: "")
                        .putString("deviceId", args["deviceId"] as? String ?: "")
                        .putString("deviceToken", args["deviceToken"] as? String ?: "")
                        .putString("pcId", args["pcId"] as? String ?: "")
                        .apply()
                    result.success(true)
                }
                "consumeInitialDeepLink" -> {
                    val link = latestDeepLink ?: prefs.getString(NfcLaunchActivity.PREF_PENDING_DEEP_LINK, null)
                    latestDeepLink = null
                    if (link != null) {
                        prefs.edit().remove(NfcLaunchActivity.PREF_PENDING_DEEP_LINK).apply()
                    }
                    result.success(link)
                }
                "pickAndSendFile" -> {
                    startActivity(Intent(this, NfcLaunchActivity::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        val link = deepLinkFrom(intent) ?: return
        latestDeepLink = link
        channel?.invokeMethod("deepLink", link)
    }

    private fun deepLinkFrom(intent: Intent?): String? {
        return intent?.getStringExtra(NfcLaunchActivity.EXTRA_DEEP_LINK) ?: intent?.dataString
    }

    private fun readableDeviceName(): String {
        val manufacturer = Build.MANUFACTURER.trim()
        val model = Build.MODEL.trim()
        return if (model.lowercase().startsWith(manufacturer.lowercase())) {
            model
        } else {
            "$manufacturer $model"
        }
    }
}
