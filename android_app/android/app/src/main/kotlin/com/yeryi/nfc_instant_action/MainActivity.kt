package com.yeryi.nfc_instant_action

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
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
                            "quickAction" to prefs.getString("quickAction", "send_file"),
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
                        .putString("quickAction", args["quickAction"] as? String ?: "send_file")
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
                "downloadToDownloads" -> {
                    val args = call.arguments as Map<*, *>
                    val downloadId = downloadToDownloads(
                        url = args["url"] as? String ?: "",
                        filename = args["filename"] as? String ?: "instant-action-file",
                        deviceId = args["deviceId"] as? String ?: "",
                        deviceToken = args["deviceToken"] as? String ?: "",
                    )
                    result.success(downloadId)
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

    private fun downloadToDownloads(
        url: String,
        filename: String,
        deviceId: String,
        deviceToken: String,
    ): Long {
        if (url.isBlank()) throw IllegalArgumentException("Missing download URL")
        if (deviceId.isBlank() || deviceToken.isBlank()) throw IllegalArgumentException("Missing device auth")

        val safeName = filename
            .replace(Regex("""[\\/:*?"<>|]"""), "_")
            .ifBlank { "instant-action-file" }
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(safeName)
            .setDescription("Instant Action PC")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, safeName)
            .addRequestHeader("X-Device-Id", deviceId)
            .addRequestHeader("X-Device-Token", deviceToken)

        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        return manager.enqueue(request)
    }
}
