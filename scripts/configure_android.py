import os
import re
import glob
import shutil

for p in glob.glob("android/settings.gradle*"):
    with open(p, "r", encoding="utf-8") as f: s = f.read()
    s = re.sub(r'(id\s+["\']org\.jetbrains\.kotlin\.android["\']\s+version\s+["\'])[^"\']+(["\'])', r'\g<1>1.9.24\g<2>', s)
    with open(p, "w", encoding="utf-8") as f: f.write(s)

for p in glob.glob("android/build.gradle*"):
    with open(p, "r", encoding="utf-8") as f: s = f.read()
    s = re.sub(r'ext\.kotlin_version\s*=\s*["\'][^"\']+["\']', 'ext.kotlin_version = "1.9.24"', s)
    with open(p, "w", encoding="utf-8") as f: f.write(s)

for p in glob.glob("android/app/build.gradle*"):
    with open(p, "r", encoding="utf-8") as f: s = f.read()
    s = re.sub(r'compileSdk\s*=?\s*[\w\.]+', 'compileSdk = 35', s)
    s = re.sub(r'compileSdkVersion\s+[\w\.]+', 'compileSdkVersion 35', s)
    s = re.sub(r'targetSdk\s*=?\s*[\w\.]+', 'targetSdk = 35', s)
    s = re.sub(r'targetSdkVersion\s+[\w\.]+', 'targetSdkVersion 35', s)
    s = re.sub(r'minSdk\s*=?\s*[\w\.]+', 'minSdk = 21', s)
    s = re.sub(r'minSdkVersion\s+[\w\.]+', 'minSdkVersion 21', s)
    with open(p, "w", encoding="utf-8") as f: f.write(s)

manifest_path = "android/app/src/main/AndroidManifest.xml"
with open(manifest_path, "r", encoding="utf-8") as f: manifest = f.read()

permissions_xml = """
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29" />
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />
"""
if "MANAGE_EXTERNAL_STORAGE" not in manifest: manifest = manifest.replace("<application", permissions_xml + "\n    <application", 1)
manifest = re.sub(r'android:label="[^"]*"', 'android:label="Tarik emb"', manifest, count=1)
if "requestLegacyExternalStorage" not in manifest: manifest = manifest.replace("<application", '<application android:requestLegacyExternalStorage="true"', 1)
manifest = re.sub(r'android:launchMode="[^"]*"', 'android:launchMode="singleTop"', manifest)

emb_intent_filters = """
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="content" />
                <data android:scheme="file" />
                <data android:mimeType="*/*" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="*/*" />
            </intent-filter>
"""
if "android.intent.action.VIEW" not in manifest: manifest = manifest.replace("</activity>", emb_intent_filters + "\n        </activity>", 1)
with open(manifest_path, "w", encoding="utf-8") as f: f.write(manifest)

kt_dir = "android/app/src/main/kotlin/com/tarikhabrosh/emb_gallery"
os.makedirs(kt_dir, exist_ok=True)
kt_code = """package com.tarikhabrosh.emb_gallery
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "tarik_emb/file_intent"
    private var initialFilePath: String? = null
    private var methodChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent, isInitial = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent, isInitial = false)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getInitialFile") { result.success(initialFilePath); initialFilePath = null }
            else { result.notImplemented() }
        }
    }

    private fun handleIntent(intent: Intent?, isInitial: Boolean) {
        if (intent == null) return
        var uri: Uri? = null
        if (intent.action == Intent.ACTION_VIEW || intent.action == Intent.ACTION_EDIT) { uri = intent.data }
        else if (intent.action == Intent.ACTION_SEND) {
            uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) { intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) }
            else { @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM) }
        }
        if (uri != null) {
            val copiedPath = copyUriToCache(uri) ?: return
            if (isInitial) { initialFilePath = copiedPath } else { methodChannel?.invokeMethod("onFileOpened", copiedPath) }
        }
    }

    private fun copyUriToCache(uri: Uri): String? {
        return try {
            if (uri.scheme == "file" && uri.path != null) {
                val f = File(uri.path!!)
                if (f.exists() && f.canRead()) return f.absolutePath
            }
            var displayName = "whatsapp_design.emb"
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && cursor.moveToFirst()) {
                    val name = cursor.getString(nameIndex)
                    if (!name.isNullOrBlank()) displayName = name
                }
            }
            displayName = displayName.substringAfterLast('/').substringAfterLast(92.toChar())
            val lowerName = displayName.lowercase()
            val validExts = listOf(
                ".emb", ".dst", ".dhp", ".dha", ".dhe",
                ".tbf", ".dsb", ".exp", ".pes", ".pec",
                ".jef", ".ef", ".vp3", ".xxx", ".u01"
            )
            if (validExts.none { lowerName.endsWith(it) }) displayName = "$displayName.emb"

            val outDir = File(cacheDir, "incoming_emb")
            if (!outDir.exists()) outDir.mkdirs()
            val outFile = File(outDir, displayName)
            contentResolver.openInputStream(uri)?.use { input -> FileOutputStream(outFile).use { output -> input.copyTo(output) } }
            outFile.absolutePath
        } catch (e: Exception) { null }
    }
}
"""
with open(os.path.join(kt_dir, "MainActivity.kt"), "w", encoding="utf-8") as f: f.write(kt_code)

if os.path.exists("assets/logo.png"):
    for folder in ["mipmap-mdpi", "mipmap-hdpi", "mipmap-xhdpi", "mipmap-xxhdpi", "mipmap-xxxhdpi"]:
        dest_dir = f"android/app/src/main/res/{folder}"
        if os.path.exists(dest_dir): shutil.copy("assets/logo.png", os.path.join(dest_dir, "ic_launcher.png"))
