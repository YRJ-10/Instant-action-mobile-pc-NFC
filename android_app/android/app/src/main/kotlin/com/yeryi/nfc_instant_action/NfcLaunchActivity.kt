package com.yeryi.nfc_instant_action

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

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
            openFilePicker()
        }, 250)
    }

    private fun openFilePicker() {
        updateStatus("Choose file", "Select file to send to PC.", true)
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        startActivityForResult(intent, REQUEST_PICK_FILES)
    }

    @Deprecated("Deprecated in Android API, still fine for this simple Activity.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_FILES) return

        if (resultCode != RESULT_OK || data == null) {
            updateStatus("Cancelled", "No file selected.", false)
            finishAfterDelay(900)
            return
        }

        val uris = selectedUris(data)
        if (uris.isEmpty()) {
            updateStatus("Cancelled", "No file selected.", false)
            finishAfterDelay(900)
            return
        }

        processFiles(uris)
    }

    private fun selectedUris(data: Intent): List<Uri> {
        val uris = mutableListOf<Uri>()
        val clipData = data.clipData
        if (clipData != null) {
            for (index in 0 until clipData.itemCount) {
                clipData.getItemAt(index).uri?.let { uris.add(it) }
            }
        } else {
            data.data?.let { uris.add(it) }
        }
        return uris
    }

    private fun processFiles(uris: List<Uri>) {
        updateStatus("Sending file", "Uploading ${uris.size} file(s) to PC.", true)
        Thread {
            val result = runCatching { uploadFiles(uris) }
                .getOrElse { TapResult("File failed", it.message ?: "Unknown error", false) }

            mainHandler.post {
                updateStatus(result.title, result.message, false)
                finishAfterDelay(1800)
            }
        }.start()
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
        getSharedPreferences(PREF_NAME, MODE_PRIVATE)
            .edit()
            .putString(PREF_LAST_SENT_CLIPBOARD, contextText)
            .apply()
        return TapResult("Sent", if (type == "url") "URL sent to PC." else "Clipboard sent to PC.", false)
    }

    private fun lastSentClipboard(): String {
        return getSharedPreferences(PREF_NAME, MODE_PRIVATE)
            .getString(PREF_LAST_SENT_CLIPBOARD, "")
            .orEmpty()
    }

    private fun shouldOpenFilePicker(contextText: String): Boolean {
        if (contextText.isEmpty() || contextText == lastSentClipboard()) return true

        val prefs = getSharedPreferences(PREF_NAME, MODE_PRIVATE)
        val setupValues = listOf(
            prefs.getString("pairingToken", ""),
            prefs.getString("deviceId", ""),
            prefs.getString("deviceToken", ""),
            prefs.getString("pcId", ""),
            prefs.getString("baseUrl", ""),
        )

        return setupValues.any { value ->
            !value.isNullOrBlank() && value.trim() == contextText
        }
    }

    private fun uploadFiles(uris: List<Uri>): TapResult {
        val prefs = getSharedPreferences(PREF_NAME, MODE_PRIVATE)
        val baseUrl = prefs.getString("baseUrl", "")?.trim().orEmpty().trimEnd('/')
        val deviceId = prefs.getString("deviceId", "")?.trim().orEmpty()
        val deviceToken = prefs.getString("deviceToken", "")?.trim().orEmpty()

        if (baseUrl.isEmpty() || deviceId.isEmpty() || deviceToken.isEmpty()) {
            return TapResult("Not connected", "Open the app and trust this phone first.", false)
        }

        var uploaded = 0
        for (uri in uris) {
            uploadFile(baseUrl, deviceId, deviceToken, uri)
            uploaded += 1
        }

        return TapResult("File sent", "$uploaded file(s) sent to PC.", false)
    }

    private fun uploadFile(baseUrl: String, deviceId: String, deviceToken: String, uri: Uri) {
        val filename = fileName(uri)
        val encodedName = URLEncoder.encode(filename, Charsets.UTF_8.name())
        val connection = URL("$baseUrl/api/files?filename=$encodedName").openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.connectTimeout = 3000
        connection.readTimeout = 30000
        connection.doOutput = true
        connection.setChunkedStreamingMode(0)
        connection.setRequestProperty("Content-Type", "application/octet-stream")
        connection.setRequestProperty("X-Device-Id", deviceId)
        connection.setRequestProperty("X-Device-Token", deviceToken)

        contentResolver.openInputStream(uri)?.use { input ->
            connection.outputStream.use { output ->
                input.copyTo(output)
            }
        } ?: throw IllegalStateException("Cannot read selected file")

        val responseCode = connection.responseCode
        val responseStream = if (responseCode in 200..299) connection.inputStream else connection.errorStream
        val responseText = responseStream?.bufferedReader()?.use { it.readText() }.orEmpty()
        if (responseCode !in 200..299) {
            throw IllegalStateException("HTTP $responseCode")
        }

        val response = JSONObject(responseText)
        if (!response.optBoolean("ok", false)) {
            throw IllegalStateException(response.optString("error", "Upload failed"))
        }
    }

    private fun fileName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    val name = cursor.getString(index)
                    if (!name.isNullOrBlank()) return name
                }
            }
        }
        return "upload-${System.currentTimeMillis()}"
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
        private const val PREF_LAST_SENT_CLIPBOARD = "lastSentClipboard"
        private const val REQUEST_PICK_FILES = 7291
        private const val PREF_NAME = "instant_action"
        private const val DEFAULT_DEEP_LINK = "nfcinstant://tap"
    }
}
