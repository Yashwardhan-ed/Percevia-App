package com.example.percevia

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Debug
import android.speech.tts.TextToSpeech
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val ttsChannelName = "percevia/tts"
    private val perfChannelName = "percevia/perf"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ttsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Opens the TTS engine's "install voice data" screen so the
                    // user downloads only the language they want. Voice data is
                    // managed by Google TTS, not bundled in this app.
                    "installTtsData" -> {
                        val engine = call.argument<String>("engine")
                        if (launchInstallTtsData(engine)) {
                            result.success(true)
                        } else if (launchInstallTtsData(null)) {
                            // Retry unscoped — OEM/default engine UI may differ.
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, perfChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Debug-only memory sampling for the perf harness.
                    "memoryInfo" -> result.success(collectMemoryInfo())
                    else -> result.notImplemented()
                }
            }
    }

    private fun launchInstallTtsData(enginePackage: String?): Boolean {
        return try {
            val intent = Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (!enginePackage.isNullOrEmpty()) {
                intent.setPackage(enginePackage)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun collectMemoryInfo(): Map<String, Any> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val sysInfo = ActivityManager.MemoryInfo()
        am.getMemoryInfo(sysInfo)

        val dbg = Debug.MemoryInfo()
        Debug.getMemoryInfo(dbg)

        val nativeHeapMb = Debug.getNativeHeapAllocatedSize() / (1024 * 1024)
        val totalPssMb = dbg.totalPss / 1024
        val dalvikMb = (dbg.dalvikPss) / 1024
        val availMb = sysInfo.availMem / (1024 * 1024)

        return mapOf(
            "totalPssMb" to totalPssMb,
            "nativeHeapMb" to nativeHeapMb.toInt(),
            "dalvikMb" to dalvikMb,
            "availMb" to availMb.toInt(),
            "lowMemory" to sysInfo.lowMemory
        )
    }
}
