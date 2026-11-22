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


# --- Auto-download Arabic & English Embroidery Fonts and register in pubspec.yaml ---
import urllib.request

fonts_dir = "assets/fonts"
os.makedirs(fonts_dir, exist_ok=True)

FONT_SPECS = [
    ("Amiri", "Amiri-Bold.ttf", [
        "https://github.com/google/fonts/raw/main/ofl/amiri/Amiri-Bold.ttf",
        "https://raw.githubusercontent.com/google/fonts/main/ofl/amiri/Amiri-Bold.ttf",
    ]),
    ("ArefRuqaa", "ArefRuqaa-Bold.ttf", [
        "https://github.com/google/fonts/raw/main/ofl/arefruqaa/ArefRuqaa-Bold.ttf",
        "https://raw.githubusercontent.com/google/fonts/main/ofl/arefruqaa/ArefRuqaa-Bold.ttf",
    ]),
    ("Tajawal", "Tajawal-Bold.ttf", [
        "https://github.com/google/fonts/raw/main/ofl/tajawal/Tajawal-Bold.ttf",
        "https://raw.githubusercontent.com/google/fonts/main/ofl/tajawal/Tajawal-Bold.ttf",
    ]),
    ("Lalezar", "Lalezar-Regular.ttf", [
        "https://github.com/google/fonts/raw/main/ofl/lalezar/Lalezar-Regular.ttf",
        "https://raw.githubusercontent.com/google/fonts/main/ofl/lalezar/Lalezar-Regular.ttf",
    ]),
    ("Rakkas", "Rakkas-Regular.ttf", [
        "https://github.com/google/fonts/raw/main/ofl/rakkas/Rakkas-Regular.ttf",
        "https://raw.githubusercontent.com/google/fonts/main/ofl/rakkas/Rakkas-Regular.ttf",
    ]),
    ("ReemKufi", "ReemKufi-Bold.ttf", [
        "https://github.com/google/fonts/raw/main/ofl/reemkufi/static/ReemKufi-Bold.ttf",
        "https://raw.githubusercontent.com/google/fonts/main/ofl/reemkufi/static/ReemKufi-Bold.ttf",
    ]),
    ("Lobster", "Lobster-Regular.ttf", [
        "https://github.com/google/fonts/raw/main/ofl/lobster/Lobster-Regular.ttf",
        "https://raw.githubusercontent.com/google/fonts/main/ofl/lobster/Lobster-Regular.ttf",
    ]),
    ("GreatVibes", "GreatVibes-Regular.ttf", [
        "https://github.com/google/fonts/raw/main/ofl/greatvibes/GreatVibes-Regular.ttf",
        "https://raw.githubusercontent.com/google/fonts/main/ofl/greatvibes/GreatVibes-Regular.ttf",
    ]),
    ("Pacifico", "Pacifico-Regular.ttf", [
        "https://github.com/google/fonts/raw/main/ofl/pacifico/Pacifico-Regular.ttf",
        "https://raw.githubusercontent.com/google/fonts/main/ofl/pacifico/Pacifico-Regular.ttf",
    ]),
    ("BebasNeue", "BebasNeue-Regular.ttf", [
        "https://github.com/google/fonts/raw/main/ofl/bebasneue/BebasNeue-Regular.ttf",
        "https://raw.githubusercontent.com/google/fonts/main/ofl/bebasneue/BebasNeue-Regular.ttf",
    ]),
    ("Cinzel", "Cinzel-Bold.ttf", [
        "https://github.com/google/fonts/raw/main/ofl/cinzel/static/Cinzel-Bold.ttf",
        "https://raw.githubusercontent.com/google/fonts/main/ofl/cinzel/static/Cinzel-Bold.ttf",
    ]),
]

downloaded_fonts = []
for family, fname, urls in FONT_SPECS:
    dest = os.path.join(fonts_dir, fname)
    ok = os.path.exists(dest) and os.path.getsize(dest) > 10000
    if not ok:
        for url in urls:
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
                with urllib.request.urlopen(req, timeout=20) as resp:
                    data = resp.read()
                if len(data) > 10000 and data[:4] in (b"\x00\x01\x00\x00", b"OTTO", b"true"):
                    with open(dest, "wb") as out_f:
                        out_f.write(data)
                    ok = True
                    print(f"[Font OK] {family} -> {dest} ({len(data)} bytes)")
                    break
            except Exception as ex:
                print(f"[Font Skip] {family} ({url}): {ex}")
    if ok:
        downloaded_fonts.append((family, f"assets/fonts/{fname}"))

if downloaded_fonts and os.path.exists("pubspec.yaml"):
    with open("pubspec.yaml", "r", encoding="utf-8") as f:
        pub = f.read()
    # Remove any previous auto-generated font block if present
    pub = re.sub(r"\n  # TARIK_FONTS_START[\s\S]*?# TARIK_FONTS_END\n?", "\n", pub)
    fonts_yaml_lines = ["  # TARIK_FONTS_START", "  fonts:"]
    for family, asset_path in downloaded_fonts:
        fonts_yaml_lines.append(f"    - family: {family}")
        fonts_yaml_lines.append("      fonts:")
        fonts_yaml_lines.append(f"        - asset: {asset_path}")
    fonts_yaml_lines.append("  # TARIK_FONTS_END")
    fonts_block = "\n".join(fonts_yaml_lines) + "\n"

    if re.search(r"(?m)^flutter:\s*$", pub):
        pub = re.sub(r"(?m)^flutter:\s*$", "flutter:\n" + fonts_block.rstrip("\n"), pub, count=1)
    else:
        pub = pub.rstrip() + "\n\nflutter:\n" + fonts_block
    with open("pubspec.yaml", "w", encoding="utf-8") as f:
        f.write(pub)
    print(f"Registered {len(downloaded_fonts)} fonts in pubspec.yaml")
