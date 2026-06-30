package com.yeryi.nfc_instant_action

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class NfcLaunchActivity : Activity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var titleView: TextView
    private lateinit var messageView: TextView
    private lateinit var progressView: ProgressBar
    private var started = false
    private var pendingLink = DEFAULT_DEEP_LINK

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showLaunchScreen()

        pendingLink = intent?.dataString ?: DEFAULT_DEEP_LINK
        getSharedPreferences(PREF_NAME, MODE_PRIVATE)
            .edit()
            .putString(PREF_PENDING_DEEP_LINK, pendingLink)
            .apply()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) startProcessing()
    }

    private fun startProcessing() {
        if (started) return
        started = true

        mainHandler.postDelayed({
            val contextText = readClipboardText()
            processTap(contextText)
        }, 350)
    }

    private fun processTap(contextText: String) {
        Thread {
            val result = runCatching { handleTap(contextText) }
                .getOrElse { TapResult("Tap failed", it.message ?: "Unknown error", false) }

            mainHandler.post {
                updateStatus(result.title, result.message, result.loading)
                finishAfterDelay(if (result.loading) 900 else 1800)
            }
        }.start()
    }

    private fun showLaunchScreen() {
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.rgb(13, 17, 23))
            setPadding(48, 48, 48, 48)
        }

        progressView = ProgressBar(this).apply {
            isIndeterminate = true
        }
        titleView = TextView(this).apply {
            text = "Instant Action"
            setTextColor(Color.rgb(230, 237, 243))
            textSize = 20f
            gravity = Gravity.CENTER
            setPadding(0, 28, 0, 0)
        }
        messageView = TextView(this).apply {
            text = "Reading context..."
            setTextColor(Color.rgb(139, 148, 158))
            textSize = 14f
            gravity = Gravity.CENTER
            setPadding(0, 10, 0, 0)
        }

        layout.addView(progressView)
        layout.addView(titleView)
        layout.addView(messageView)
        setContentView(layout)
    }

    private fun updateStatus(title: String, message: String, loading: Boolean) {
        titleView.text = title
        messageView.text = message
        progressView.visibility = if (loading) android.view.View.VISIBLE else android.view.View.GONE
    }

    private fun handleTap(contextText: String): TapResult {
        val prefs = getSharedPreferences(PREF_NAME, MODE_PRIVATE)
        val baseUrl = prefs.getString("baseUrl", "")?.trim().orEmpty().trimEnd('/')
        val deviceId = prefs.getString("deviceId", "")?.trim().orEmpty()
        val deviceToken = prefs.getString("deviceToken", "")?.trim().orEmpty()

        if (baseUrl.isEmpty() || deviceId.isEmpty() || deviceToken.isEmpty()) {
            return TapResult("Not connected", "Open the app and trust this phone first.", false)
        }

        if (contextText.isEmpty()) {
            return TapResult("No context", "Show menu later.", false)
        }

        val type = if (contextText.startsWith("http://") || contextText.startsWith("https://")) {
            "url"
        } else {
            "clipboard"
        }

        val payload = JSONObject()
        if (type == "url") {
            payload.put("url", contextText)
        } else {
            payload.put("text", contextText)
        }

        val body = JSONObject()
            .put("type", type)
            .put("source", "nfc")
            .put("payload", payload)

        postIntent(baseUrl, deviceId, deviceToken, body)
        return TapResult("Sent", if (type == "url") "URL sent to PC." else "Clipboard sent to PC.", false)
    }

    private fun postIntent(baseUrl: String, deviceId: String, deviceToken: String, body: JSONObject) {
        val connection = URL("$baseUrl/api/intent").openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.connectTimeout = 3000
        connection.readTimeout = 5000
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        connection.setRequestProperty("X-Device-Id", deviceId)
        connection.setRequestProperty("X-Device-Token", deviceToken)

        connection.outputStream.use { output ->
            output.write(body.toString().toByteArray(Charsets.UTF_8))
        }

        val responseCode = connection.responseCode
        val responseStream = if (responseCode in 200..299) connection.inputStream else connection.errorStream
        val responseText = responseStream?.bufferedReader()?.use { it.readText() }.orEmpty()
        if (responseCode !in 200..299) {
            throw IllegalStateException("HTTP $responseCode")
        }

        val response = JSONObject(responseText)
        if (!response.optBoolean("ok", false)) {
            throw IllegalStateException(response.optString("error", "Request failed"))
        }
    }

    private fun readClipboardText(): String {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip ?: return ""
        if (clip.itemCount == 0) return ""
        return clip.getItemAt(0).coerceToText(this)?.toString()?.trim().orEmpty()
    }

    private fun finishAfterDelay(delayMs: Long) {
        mainHandler.postDelayed({ finish() }, delayMs)
    }

    private data class TapResult(
        val title: String,
        val message: String,
        val loading: Boolean,
    )

    companion object {
        const val EXTRA_DEEP_LINK = "instant_action_deep_link"
        const val PREF_PENDING_DEEP_LINK = "pendingDeepLink"
        private const val PREF_NAME = "instant_action"
        private const val DEFAULT_DEEP_LINK = "nfcinstant://tap"
    }
}
