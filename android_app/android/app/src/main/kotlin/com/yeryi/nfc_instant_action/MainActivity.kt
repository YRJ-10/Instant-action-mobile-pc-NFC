package com.yeryi.nfc_instant_action

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "instant_action/preferences"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("instant_action", MODE_PRIVATE)

            when (call.method) {
                "loadConfig" -> {
                    result.success(
                        mapOf(
                            "baseUrl" to prefs.getString("baseUrl", ""),
                            "pairingToken" to prefs.getString("pairingToken", ""),
                            "deviceId" to prefs.getString("deviceId", ""),
                            "deviceToken" to prefs.getString("deviceToken", ""),
                            "pcId" to prefs.getString("pcId", "")
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
                else -> result.notImplemented()
            }
        }
    }
}
