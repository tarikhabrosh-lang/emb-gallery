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


# --- TARIK_INKSTITCH_FONTS_START ---
# Auto-download & compile Open-Source Ink/Stitch & StitchFoundry Satin Embroidery Fonts
import io
import json
import math
import zipfile
import xml.etree.ElementTree as ET

EMB_FONTS_DIR = "assets/emb_fonts"
os.makedirs(EMB_FONTS_DIR, exist_ok=True)

def _emb_parse_len_mm(val):
    if not val:
        return None
    m = re.match(r'^\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*([a-zA-Z%]*)\s*$', str(val))
    if not m:
        return None
    num = float(m.group(1))
    u = m.group(2).lower()
    if u == 'mm': return num
    if u == 'cm': return num * 10.0
    if u == 'in': return num * 25.4
    if u == 'pt': return num * (25.4 / 72.0)
    if u == 'pc': return num * (25.4 / 6.0)
    if u in ('px', ''): return num * (25.4 / 96.0)
    return None

def _emb_mat_mul(m1, m2):
    a1, b1, c1, d1, e1, f1 = m1
    a2, b2, c2, d2, e2, f2 = m2
    return (
        a1 * a2 + c1 * b2,
        b1 * a2 + d1 * b2,
        a1 * c2 + c1 * d2,
        b1 * c2 + d1 * d2,
        a1 * e2 + c1 * f2 + e1,
        b1 * e2 + d1 * f2 + f1,
    )

def _emb_mat_apply(m, x, y):
    return (m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5])

def _emb_parse_transform(tf_str):
    m = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    if not tf_str:
        return m
    for fn, args_str in re.findall(r'([a-zA-Z]+)\s*\(([^)]*)\)', tf_str):
        nums = [float(x) for x in re.findall(r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?', args_str)]
        fn = fn.lower()
        t = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
        if fn == 'matrix' and len(nums) >= 6:
            t = tuple(nums[:6])
        elif fn == 'translate' and len(nums) >= 1:
            t = (1.0, 0.0, 0.0, 1.0, nums[0], nums[1] if len(nums) > 1 else 0.0)
        elif fn == 'scale' and len(nums) >= 1:
            sx = nums[0]
            sy = nums[1] if len(nums) > 1 else sx
            t = (sx, 0.0, 0.0, sy, 0.0, 0.0)
        elif fn == 'rotate' and len(nums) >= 1:
            ang = math.radians(nums[0])
            ca, sa = math.cos(ang), math.sin(ang)
            if len(nums) >= 3:
                cx, cy = nums[1], nums[2]
                t = _emb_mat_mul((1, 0, 0, 1, cx, cy), _emb_mat_mul((ca, sa, -sa, ca, 0, 0), (1, 0, 0, 1, -cx, -cy)))
            else:
                t = (ca, sa, -sa, ca, 0.0, 0.0)
        elif fn == 'skewx' and len(nums) >= 1:
            t = (1.0, 0.0, math.tan(math.radians(nums[0])), 1.0, 0.0, 0.0)
        elif fn == 'skewy' and len(nums) >= 1:
            t = (1.0, math.tan(math.radians(nums[0])), 0.0, 1.0, 0.0, 0.0)
        m = _emb_mat_mul(m, t)
    return m

def _emb_flatten_cubic(p0, p1, p2, p3, tol=0.25, depth=0):
    x0, y0 = p0; x1, y1 = p1; x2, y2 = p2; x3, y3 = p3
    dx, dy = x3 - x0, y3 - y0
    d2 = abs((x1 - x3) * dy - (y1 - y3) * dx)
    d3 = abs((x2 - x3) * dy - (y2 - y3) * dx)
    if depth >= 7 or (d2 + d3) * (d2 + d3) <= tol * tol * (dx * dx + dy * dy + 1e-9):
        return [p3]
    x01, y01 = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    x12, y12 = (x1 + x2) * 0.5, (y1 + y2) * 0.5
    x23, y23 = (x2 + x3) * 0.5, (y2 + y3) * 0.5
    x012, y012 = (x01 + x12) * 0.5, (y01 + y12) * 0.5
    x123, y123 = (x12 + x23) * 0.5, (y12 + y23) * 0.5
    x0123, y0123 = (x012 + x123) * 0.5, (y012 + y123) * 0.5
    return (
        _emb_flatten_cubic(p0, (x01, y01), (x012, y012), (x0123, y0123), tol, depth + 1) +
        _emb_flatten_cubic((x0123, y0123), (x123, y123), (x23, y23), p3, tol, depth + 1)
    )

def _emb_flatten_arc(x1, y1, rx, ry, phi_deg, large_arc, sweep, x2, y2, tol=0.25):
    if abs(x1 - x2) < 1e-9 and abs(y1 - y2) < 1e-9:
        return []
    rx, ry = abs(rx), abs(ry)
    if rx < 1e-9 or ry < 1e-9:
        return [(x2, y2)]
    phi = math.radians(phi_deg % 360.0)
    cp, sp = math.cos(phi), math.sin(phi)
    dx2, dy2 = (x1 - x2) * 0.5, (y1 - y2) * 0.5
    x1p = cp * dx2 + sp * dy2
    y1p = -sp * dx2 + cp * dy2
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1.0:
        s = math.sqrt(lam)
        rx *= s; ry *= s
    num = max(0.0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = math.sqrt(num / den) if den > 1e-12 else 0.0
    if large_arc == sweep:
        coef = -coef
    cxp = coef * (rx * y1p / ry)
    cyp = coef * (-ry * x1p / rx)
    cx = cp * cxp - sp * cyp + (x1 + x2) * 0.5
    cy = sp * cxp + cp * cyp + (y1 + y2) * 0.5

    def _vang(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        mag = math.hypot(ux, uy) * math.hypot(vx, vy)
        c = max(-1.0, min(1.0, dot / mag)) if mag > 1e-12 else 1.0
        a = math.acos(c)
        return -a if (ux * vy - uy * vx) < 0 else a

    t1 = _vang(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = _vang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dt > 0:
        dt -= 2.0 * math.pi
    elif sweep and dt < 0:
        dt += 2.0 * math.pi

    steps = max(4, min(64, int(math.ceil(abs(dt) * max(rx, ry) / max(tol * 3.0, 0.5)))))
    pts = []
    for k in range(1, steps + 1):
        ang = t1 + dt * (k / steps)
        ca, sa = math.cos(ang), math.sin(ang)
        pts.append((cp * (rx * ca) - sp * (ry * sa) + cx, sp * (rx * ca) + cp * (ry * sa) + cy))
    return pts

_EMB_NUM_RE = re.compile(r'\s*,?\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)')
_EMB_FLAG_RE = re.compile(r'\s*,?\s*([01])')
_EMB_CMD_RE = re.compile(r'\s*,?\s*([MmLlHhVvCcSsQqTtAaZz])')

def _emb_parse_path(d, mat, tol=0.25):
    if not d:
        return []
    subpaths = []
    cur = []
    cx = cy = sx = sy = 0.0
    last_cp = None
    last_qcp = None
    cmd = None
    i = 0
    n = len(d)

    def rnum():
        nonlocal i
        m = _EMB_NUM_RE.match(d, i)
        if not m: return None
        i = m.end()
        return float(m.group(1))

    def rflag():
        nonlocal i
        m = _EMB_FLAG_RE.match(d, i)
        if not m: return None
        i = m.end()
        return int(m.group(1))

    def flush():
        nonlocal cur
        if len(cur) >= 2:
            subpaths.append([_emb_mat_apply(mat, px, py) for px, py in cur])
        cur = []

    while i < n:
        while i < n and d[i] in ' \t\r\n,':
            i += 1
        if i >= n:
            break
        m = _EMB_CMD_RE.match(d, i)
        if m:
            cmd = m.group(1)
            i = m.end()
        elif cmd is None:
            break

        if cmd in 'Zz':
            if cur and math.hypot(cx - sx, cy - sy) > 1e-5:
                cur.append((sx, sy))
            cx, cy = sx, sy
            flush()
            last_cp = last_qcp = None
            cmd = None
        elif cmd in 'Mm':
            x = rnum(); y = rnum()
            if x is None or y is None: break
            if cmd == 'm' and (cur or subpaths):
                x += cx; y += cy
            flush()
            cx, cy = sx, sy = x, y
            cur = [(cx, cy)]
            last_cp = last_qcp = None
            cmd = 'l' if cmd == 'm' else 'L'
        elif cmd in 'Ll':
            x = rnum(); y = rnum()
            if x is None or y is None: break
            if cmd == 'l': x += cx; y += cy
            cx, cy = x, y
            cur.append((cx, cy))
            last_cp = last_qcp = None
        elif cmd in 'Hh':
            x = rnum()
            if x is None: break
            cx = cx + x if cmd == 'h' else x
            cur.append((cx, cy))
            last_cp = last_qcp = None
        elif cmd in 'Vv':
            y = rnum()
            if y is None: break
            cy = cy + y if cmd == 'v' else y
            cur.append((cx, cy))
            last_cp = last_qcp = None
        elif cmd in 'Cc':
            vals = [rnum() for _ in range(6)]
            if any(v is None for v in vals): break
            x1, y1, x2, y2, x, y = vals
            if cmd == 'c':
                x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy
            cur.extend(_emb_flatten_cubic((cx, cy), (x1, y1), (x2, y2), (x, y), tol))
            last_cp = (x2, y2); last_qcp = None
            cx, cy = x, y
        elif cmd in 'Ss':
            vals = [rnum() for _ in range(4)]
            if any(v is None for v in vals): break
            x2, y2, x, y = vals
            if cmd == 's':
                x2 += cx; y2 += cy; x += cx; y += cy
            x1, y1 = (2 * cx - last_cp[0], 2 * cy - last_cp[1]) if last_cp is not None else (cx, cy)
            cur.extend(_emb_flatten_cubic((cx, cy), (x1, y1), (x2, y2), (x, y), tol))
            last_cp = (x2, y2); last_qcp = None
            cx, cy = x, y
        elif cmd in 'Qq':
            vals = [rnum() for _ in range(4)]
            if any(v is None for v in vals): break
            qx, qy, x, y = vals
            if cmd == 'q':
                qx += cx; qy += cy; x += cx; y += cy
            c1x = cx + (2.0 / 3.0) * (qx - cx); c1y = cy + (2.0 / 3.0) * (qy - cy)
            c2x = x + (2.0 / 3.0) * (qx - x); c2y = y + (2.0 / 3.0) * (qy - y)
            cur.extend(_emb_flatten_cubic((cx, cy), (c1x, c1y), (c2x, c2y), (x, y), tol))
            last_qcp = (qx, qy); last_cp = None
            cx, cy = x, y
        elif cmd in 'Tt':
            x = rnum(); y = rnum()
            if x is None or y is None: break
            if cmd == 't': x += cx; y += cy
            qx, qy = (2 * cx - last_qcp[0], 2 * cy - last_qcp[1]) if last_qcp is not None else (cx, cy)
            c1x = cx + (2.0 / 3.0) * (qx - cx); c1y = cy + (2.0 / 3.0) * (qy - cy)
            c2x = x + (2.0 / 3.0) * (qx - x); c2y = y + (2.0 / 3.0) * (qy - y)
            cur.extend(_emb_flatten_cubic((cx, cy), (c1x, c1y), (c2x, c2y), (x, y), tol))
            last_qcp = (qx, qy); last_cp = None
            cx, cy = x, y
        elif cmd in 'Aa':
            rx = rnum(); ry = rnum(); rot = rnum()
            la = rflag(); sw = rflag()
            x = rnum(); y = rnum()
            if any(v is None for v in (rx, ry, rot, la, sw, x, y)): break
            if cmd == 'a': x += cx; y += cy
            cur.extend(_emb_flatten_arc(cx, cy, rx, ry, rot, la, sw, x, y, tol))
            last_cp = last_qcp = None
            cx, cy = x, y
        else:
            break
    flush()
    return subpaths

def _emb_poly_len(pts):
    return sum(math.hypot(pts[k+1][0] - pts[k][0], pts[k+1][1] - pts[k][1]) for k in range(len(pts) - 1))

def _emb_rdp(pts, eps):
    if len(pts) <= 2:
        return pts
    x1, y1 = pts[0]; x2, y2 = pts[-1]
    dx, dy = x2 - x1, y2 - y1
    lsq = dx * dx + dy * dy
    max_d = -1.0; idx = 0
    for k in range(1, len(pts) - 1):
        px, py = pts[k]
        if lsq < 1e-12:
            d = math.hypot(px - x1, py - y1)
        else:
            t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / lsq))
            d = math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))
        if d > max_d:
            max_d = d; idx = k
    if max_d > eps:
        l = _emb_rdp(pts[:idx + 1], eps)
        r = _emb_rdp(pts[idx:], eps)
        return l[:-1] + r
    return [pts[0], pts[-1]]

def _emb_seg_inter(p1, p2, p3, p4, pad_rung=0.18):
    x1, y1 = p1; x2, y2 = p2; x3, y3 = p3; x4, y4 = p4
    dx1, dy1 = x2 - x1, y2 - y1
    dx2, dy2 = x4 - x3, y4 - y3
    den = dx1 * dy2 - dy1 * dx2
    if abs(den) < 1e-10:
        return None
    t = ((x3 - x1) * dy2 - (y3 - y1) * dx2) / den
    u = ((x3 - x1) * dy1 - (y3 - y1) * dx1) / den
    if -0.02 <= t <= 1.02 and -pad_rung <= u <= 1.0 + pad_rung:
        return max(0.0, min(1.0, t))
    return None

def _emb_rung_param(rail, rung):
    tot = _emb_poly_len(rail)
    if tot < 1e-6:
        return None
    acc = 0.0
    for k in range(len(rail) - 1):
        slen = math.hypot(rail[k+1][0] - rail[k][0], rail[k+1][1] - rail[k][1])
        for j in range(len(rung) - 1):
            t = _emb_seg_inter(rail[k], rail[k+1], rung[j], rung[j+1])
            if t is not None:
                return (acc + t * slen) / tot
        acc += slen
    return None

def _emb_extract_satin(subpaths, eps=0.6):
    valid = [sp for sp in subpaths if len(sp) >= 2 and _emb_poly_len(sp) > 0.4]
    if len(valid) < 2:
        return None
    if len(valid) == 2:
        r1, r2 = valid[0], valid[1]
        rungs = []
    else:
        n = len(valid)
        lens = [_emb_poly_len(sp) for sp in valid]
        cand = sorted(range(n), key=lambda k: -lens[k])[:min(n, 7)]
        if 0 not in cand: cand.append(0)
        if 1 not in cand: cand.append(1)
        best_score = (-1, -1.0)
        best_pair = (0, 1)
        best_rungs = []
        for ai in range(len(cand)):
            for bi in range(ai + 1, len(cand)):
                i, j = cand[ai], cand[bi]
                ra, rb = valid[i], valid[j]
                matched = []
                for k in range(n):
                    if k == i or k == j: continue
                    u1 = _emb_rung_param(ra, valid[k])
                    if u1 is None: continue
                    u2 = _emb_rung_param(rb, valid[k])
                    if u2 is not None:
                        matched.append((u1, u2))
                score = (len(matched), lens[i] + lens[j])
                if score > best_score:
                    best_score = score
                    best_pair = (i, j)
                    best_rungs = matched
        r1, r2 = valid[best_pair[0]], valid[best_pair[1]]
        rungs = best_rungs

    is_cl1 = math.hypot(r1[0][0] - r1[-1][0], r1[0][1] - r1[-1][1]) < 2.0 and len(r1) >= 4
    is_cl2 = math.hypot(r2[0][0] - r2[-1][0], r2[0][1] - r2[-1][1]) < 2.0 and len(r2) >= 4
    if is_cl1 and is_cl2:
        core2 = r2[:-1]
        bi = min(range(len(core2)), key=lambda k: math.hypot(core2[k][0] - r1[0][0], core2[k][1] - r1[0][1]))
        r2 = core2[bi:] + core2[:bi] + [core2[bi]]
        sa1 = sum(r1[k][0] * r1[k+1][1] - r1[k+1][0] * r1[k][1] for k in range(len(r1) - 1))
        sa2 = sum(r2[k][0] * r2[k+1][1] - r2[k+1][0] * r2[k][1] for k in range(len(r2) - 1))
        if sa1 * sa2 < 0:
            r2 = list(reversed(r2))
        rungs = []
    else:
        if len(rungs) >= 2:
            rungs.sort(key=lambda pr: pr[0])
            inc = sum(1 for k in range(len(rungs) - 1) if rungs[k+1][1] >= rungs[k][1])
            dec = sum(1 for k in range(len(rungs) - 1) if rungs[k+1][1] < rungs[k][1])
            if dec > inc:
                r2 = list(reversed(r2))
                rungs = [(u1, 1.0 - u2) for (u1, u2) in rungs]
        else:
            d_same = math.hypot(r1[0][0] - r2[0][0], r1[0][1] - r2[0][1]) + math.hypot(r1[-1][0] - r2[-1][0], r1[-1][1] - r2[-1][1])
            d_flip = math.hypot(r1[0][0] - r2[-1][0], r1[0][1] - r2[-1][1]) + math.hypot(r1[-1][0] - r2[0][0], r1[-1][1] - r2[0][1])
            if d_flip < d_same:
                r2 = list(reversed(r2))
                rungs = [(u1, 1.0 - u2) for (u1, u2) in rungs]

    clean_rungs = []
    if rungs:
        rungs.sort(key=lambda pr: pr[0])
        lu1, lu2 = 0.02, 0.02
        for u1, u2 in rungs:
            if u1 > lu1 + 0.015 and u2 > lu2 + 0.015 and u1 < 0.98 and u2 < 0.98:
                clean_rungs.append([round(u1, 4), round(u2, 4)])
                lu1, lu2 = u1, u2

    return _emb_rdp(r1, eps), _emb_rdp(r2, eps), clean_rungs

def _emb_parse_style(elem):
    st = {}
    raw = elem.get("style") or ""
    for part in raw.split(";"):
        if ":" in part:
            k, v = part.split(":", 1)
            st[k.strip().lower()] = v.strip().lower()
    for k in ("fill", "stroke", "stroke-dasharray", "display"):
        if elem.get(k) is not None:
            st[k] = elem.get(k).strip().lower()
    return st

def _emb_attr_endswith(elem, suffix):
    for k, v in elem.attrib.items():
        if k.endswith("}" + suffix) or k == suffix:
            return v
    return None

def _emb_shape_to_subpaths(elem, mat, tol):
    tag = elem.tag.split("}")[-1].lower()
    if tag == "path":
        return _emb_parse_path(elem.get("d"), mat, tol)
    if tag in ("polyline", "polygon"):
        nums = [float(x) for x in re.findall(r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?', elem.get("points") or "")]
        pts = [(_emb_mat_apply(mat, nums[k], nums[k+1])) for k in range(0, len(nums) - 1, 2)]
        if tag == "polygon" and len(pts) >= 2:
            pts.append(pts[0])
        return [pts] if len(pts) >= 2 else []
    if tag == "line":
        x1 = float(elem.get("x1") or 0); y1 = float(elem.get("y1") or 0)
        x2 = float(elem.get("x2") or 0); y2 = float(elem.get("y2") or 0)
        return [[_emb_mat_apply(mat, x1, y1), _emb_mat_apply(mat, x2, y2)]]
    if tag == "rect":
        x = float(elem.get("x") or 0); y = float(elem.get("y") or 0)
        w = float(elem.get("width") or 0); h = float(elem.get("height") or 0)
        if w <= 0 or h <= 0: return []
        pts = [(x, y), (x+w, y), (x+w, y+h), (x, y+h), (x, y)]
        return [[_emb_mat_apply(mat, px, py) for px, py in pts]]
    if tag in ("circle", "ellipse"):
        cx = float(elem.get("cx") or 0); cy = float(elem.get("cy") or 0)
        rx = float(elem.get("r") or elem.get("rx") or 0)
        ry = float(elem.get("r") or elem.get("ry") or 0)
        if rx <= 0 or ry <= 0: return []
        pts = []
        for k in range(17):
            ang = 2.0 * math.pi * k / 16.0
            pts.append(_emb_mat_apply(mat, cx + rx * math.cos(ang), cy + ry * math.sin(ang)))
        return [pts]
    return []

def _emb_compile_svg_font(svg_bytes, font_meta, font_id, name_ar, name_en):
    root = ET.fromstring(svg_bytes)
    w_mm = _emb_parse_len_mm(root.get("width"))
    h_mm = _emb_parse_len_mm(root.get("height"))
    vb = root.get("viewBox")
    mm_per_unit = 25.4 / 96.0
    vb_h = None
    if vb:
        vb_nums = [float(x) for x in re.findall(r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?', vb)]
        if len(vb_nums) >= 4 and vb_nums[2] > 0:
            vb_h = vb_nums[3]
            if w_mm is not None and w_mm > 0:
                mm_per_unit = w_mm / vb_nums[2]
            elif h_mm is not None and h_mm > 0 and vb_nums[3] > 0:
                mm_per_unit = h_mm / vb_nums[3]
    scale_01mm = mm_per_unit * 10.0  # convert SVG units -> 0.1 mm units
    base_mat = (scale_01mm, 0.0, 0.0, scale_01mm, 0.0, 0.0)

    # Extract baseline guide if present
    guide_ys = []
    for elem in root.iter():
        tag = elem.tag.split("}")[-1].lower()
        if tag == "guide":
            orient = (elem.get("orientation") or "").strip()
            pos_str = (elem.get("position") or "").strip()
            lbl = (_emb_attr_endswith(elem, "label") or "").lower()
            nums = [float(x) for x in re.findall(r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?', pos_str)]
            if len(nums) >= 2 and (orient.startswith("0,") or "baseline" in lbl):
                gy = nums[1] * scale_01mm
                guide_ys.append((gy, "baseline" in lbl))
                if vb_h is not None:
                    guide_ys.append(((vb_h - nums[1]) * scale_01mm, "baseline" in lbl))

    raw_glyphs = {}

    def collect_elements(node, cur_mat, out_list):
        for child in node:
            tag = child.tag.split("}")[-1].lower()
            if tag in ("defs", "metadata", "namedview", "symbol", "marker", "use", "title", "desc"):
                continue
            if _emb_attr_endswith(child, "command") is not None:
                continue
            if _emb_attr_endswith(child, "connection-start") is not None or _emb_attr_endswith(child, "connection-end") is not None:
                continue
            lbl = (_emb_attr_endswith(child, "label") or "").lower()
            if "command" in lbl:
                continue
            c_mat = _emb_mat_mul(cur_mat, _emb_parse_transform(child.get("transform")))
            if tag == "g":
                collect_elements(child, c_mat, out_list)
                continue
            st = _emb_parse_style(child)
            if st.get("display") == "none":
                continue
            sps = _emb_shape_to_subpaths(child, c_mat, tol=0.45)
            if not sps:
                continue
            is_satin = (_emb_attr_endswith(child, "satin_column") or "").lower() == "true"
            if is_satin and len(sps) >= 2:
                sat = _emb_extract_satin(sps, eps=0.6)
                if sat is not None:
                    r1, r2, rungs = sat
                    u_mask = 0
                    cw = (_emb_attr_endswith(child, "center_walk_underlay") or "").lower()
                    ct = (_emb_attr_endswith(child, "contour_underlay") or "").lower()
                    zz = (_emb_attr_endswith(child, "zigzag_underlay") or "").lower()
                    if cw == "true": u_mask |= 1
                    if ct == "true": u_mask |= 2
                    if zz == "true": u_mask |= 4
                    if cw == "" and ct == "" and zz == "":
                        u_mask = 1
                    out_list.append(("s", r1, r2, rungs, u_mask))
                continue
            stroke = st.get("stroke", "")
            fill = st.get("fill", "")
            dash = st.get("stroke-dasharray", "")
            is_run = (stroke not in ("", "none")) and (fill in ("", "none") or dash not in ("", "none") or _emb_attr_endswith(child, "running_stitch_length_mm") is not None)
            if is_run:
                for sp in sps:
                    sp_s = _emb_rdp(sp, 0.6)
                    if len(sp_s) >= 2 and _emb_poly_len(sp_s) > 0.4:
                        out_list.append(("r", sp_s))
            elif fill not in ("", "none"):
                for sp in sps:
                    sp_s = _emb_rdp(sp, 0.7)
                    if len(sp_s) >= 3 and _emb_poly_len(sp_s) > 1.0:
                        out_list.append(("f", sp_s))
            else:
                for sp in sps:
                    sp_s = _emb_rdp(sp, 0.6)
                    if len(sp_s) >= 2 and _emb_poly_len(sp_s) > 0.4:
                        out_list.append(("r", sp_s))

    def find_glyph_layers(node, cur_mat):
        for child in node:
            tag = child.tag.split("}")[-1].lower()
            if tag != "g":
                continue
            c_mat = _emb_mat_mul(cur_mat, _emb_parse_transform(child.get("transform")))
            lbl = _emb_attr_endswith(child, "label") or ""
            if lbl.startswith("GlyphLayer-"):
                ch = lbl[len("GlyphLayer-"):]
                if ch:
                    elems = []
                    collect_elements(child, c_mat, elems)
                    if elems:
                        raw_glyphs[ch] = elems
            else:
                find_glyph_layers(child, c_mat)

    find_glyph_layers(root, base_mat)
    if len(raw_glyphs) < 10:
        return None

    # Detect Arabic/RTL
    has_arabic = any(any(('\u0600' <= c <= '\u06FF') or ('\uFE70' <= c <= '\uFEFF') for c in k) for k in raw_glyphs.keys())
    def_var = str(font_meta.get("default_variant") or "")
    is_rtl = has_arabic or ("←" in def_var) or ("rtl" in def_var.lower())

    # Compute raw bounding boxes per glyph
    bboxes = {}
    for ch, elems in raw_glyphs.items():
        xs = []; ys = []
        for el in elems:
            if el[0] == "s":
                for p in el[1]: xs.append(p[0]); ys.append(p[1])
                for p in el[2]: xs.append(p[0]); ys.append(p[1])
            else:
                for p in el[1]: xs.append(p[0]); ys.append(p[1])
        if xs:
            bboxes[ch] = (min(xs), max(xs), min(ys), max(ys))

    # Determine accurate baseline Y
    ref_chars = (
        ['ا', 'ب', 'ت', 'ث', 'د', 'ط', 'ك', '\uFE8D', '\uFE8E', '\uFE8F', '\uFE91', '\uFE92', '\uFE90', '\uFEA9', '\uFEC1', '\uFEC3']
        if is_rtl else
        ['A', 'B', 'D', 'E', 'F', 'H', 'I', 'K', 'L', 'M', 'N', 'R', 'T', 'Z', 'a', 'e', 'm', 'n', 'x']
    )
    ref_bottoms = [bboxes[c][3] for c in ref_chars if c in bboxes]
    if not ref_bottoms:
        ref_bottoms = [b[3] for b in bboxes.values()]
    ref_bottoms.sort()
    median_bottom = ref_bottoms[len(ref_bottoms) // 2]

    baseline_y = median_bottom
    if guide_ys:
        # Pick baseline guide closest to median_bottom (within reasonable tolerance)
        best_g = min(guide_ys, key=lambda g: abs(g[0] - median_bottom) - (5.0 if g[1] else 0.0))
        if abs(best_g[0] - median_bottom) < 60.0:
            baseline_y = best_g[0]

    # Determine cap height above baseline
    cap_chars = (['ا', 'ل', 'ك', '\uFE8D', '\uFE8E', '\uFEDD', '\uFEDF'] if is_rtl else ['A', 'E', 'H', 'I', 'M', 'T', 'B', 'L'])
    cap_hs = [baseline_y - bboxes[c][2] for c in cap_chars if c in bboxes and (baseline_y - bboxes[c][2]) > 15.0]
    if not cap_hs:
        cap_hs = [b[3] - b[2] for b in bboxes.values() if (b[3] - b[2]) > 15.0]
    cap_hs.sort()
    cap_h = cap_hs[len(cap_hs) // 2] if cap_hs else 150.0

    # Serialize normalized glyphs (X shifted so glyph minX = 0, Y shifted so baseline = 0)
    def flat_pts(pts, ox, oy):
        out = []
        for px, py in pts:
            out.append(round(px - ox, 1))
            out.append(round(py - oy, 1))
        return out

    glyphs_out = {}
    for ch, elems in raw_glyphs.items():
        if ch not in bboxes:
            continue
        minx, maxx, miny, maxy = bboxes[ch]
        w = round(maxx - minx, 1)
        if w < 1.0 and (maxy - miny) < 1.0:
            continue
        el_out = []
        for el in elems:
            if el[0] == "s":
                obj = {
                    "t": "s",
                    "r1": flat_pts(el[1], minx, baseline_y),
                    "r2": flat_pts(el[2], minx, baseline_y),
                    "u": el[4],
                }
                if el[3]:
                    obj["g"] = el[3]
                el_out.append(obj)
            elif el[0] == "r":
                el_out.append({"t": "r", "p": flat_pts(el[1], minx, baseline_y)})
            elif el[0] == "f":
                el_out.append({"t": "f", "p": flat_pts(el[1], minx, baseline_y)})
        glyphs_out[ch] = {
            "w": w,
            "e": el_out,
        }

    if len(glyphs_out) < 10:
        return None

    ws = sorted([g["w"] for g in glyphs_out.values() if g["w"] > 10.0])
    med_w = ws[len(ws) // 2] if ws else cap_h * 0.65

    raw_space = font_meta.get("horiz_adv_x_space") or font_meta.get("word_spacing")
    space_w = round(float(raw_space) * scale_01mm, 1) if raw_space else round(med_w * 0.65, 1)
    if space_w < cap_h * 0.2 or space_w > cap_h * 1.5:
        space_w = round(med_w * 0.65, 1)

    raw_ls = font_meta.get("letter_spacing")
    letter_sp = round(float(raw_ls) * scale_01mm, 1) if raw_ls is not None else round(cap_h * 0.11, 1)
    if letter_sp < 0 or letter_sp > cap_h * 0.45:
        letter_sp = round(cap_h * 0.11, 1)

    raw_lead = font_meta.get("leading")
    line_h = round(float(raw_lead) * scale_01mm, 1) if raw_lead else round(cap_h * 1.45, 1)
    if line_h < cap_h * 1.1 or line_h > cap_h * 2.5:
        line_h = round(cap_h * 1.45, 1)

    out_data = {
        "id": font_id,
        "nameAr": name_ar,
        "nameEn": name_en,
        "rtl": has_arabic,
        "arabic": has_arabic,
        "capH": round(cap_h, 1),
        "spaceW": space_w,
        "letterSp": letter_sp,
        "lineH": line_h,
        "minScale": float(font_meta.get("min_scale") or 0.6),
        "maxScale": float(font_meta.get("max_scale") or 2.5),
        "glyphs": glyphs_out,
    }
    return out_data

def _emb_build_open_source_fonts():
    # Priority list of diverse open-source satin fonts: (slug_keyword, ar_label, en_label)
    PRIORITY_ENGLISH = [
        ("chopin", "Chopin مخطوط", "Chopin Script"),
        ("bluenesia", "Bluenesia مشبّك", "Bluenesia Satin"),
        ("great_vibes", "Great Vibes", "Great Vibes"),
        ("pacifico", "Pacifico عريض", "Pacifico"),
        ("lobster", "Lobster مشبّك", "Lobster"),
        ("allura", "Allura ناعم", "Allura"),
        ("garamond", "Garamond كلاسيك", "Garamond"),
        ("cinzel", "Cinzel روماني", "Cinzel"),
        ("geneva", "Geneva حديث", "Geneva"),
        ("glacier", "Glacier نظيف", "Glacier"),
        ("apex", "Apex رياضي", "Apex Block"),
        ("anton", "Anton عريض", "Anton Bold"),
        ("barstitch", "Barstitch كلاسيك", "Barstitch"),
        ("montserrat", "Montserrat عصري", "Montserrat"),
        ("oswald", "Oswald طويل", "Oswald"),
        ("inkstitch_small", "Small صغير", "Ink/Stitch Small"),
        ("courgette", "Courgette", "Courgette"),
        ("times", "Times كلاسيك", "Times Satin"),
    ]
    ARABIC_NAMES = {
        "computer": ("حاسوب (فستون عربي)", "Computer Arabic"),
        "computer_small": ("حاسوب صغير (فستون)", "Computer Small Arabic"),
    }

    REPO_ZIPS = [
        "https://github.com/inkstitch/embroidery-fonts/archive/refs/heads/main.zip",
        "https://github.com/Stitchwright/stitchfoundry-fonts/archive/refs/heads/main.zip",
    ]

    compiled_index = []
    seen_ids = set()

    for repo_url in REPO_ZIPS:
        try:
            print(f"[EmbFont] Downloading {repo_url} ...")
            req = urllib.request.Request(repo_url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=45) as resp:
                zbytes = resp.read()
            zf = zipfile.ZipFile(io.BytesIO(zbytes))
        except Exception as ex:
            print(f"[EmbFont] Repo skipped ({repo_url}): {ex}")
            continue

        # Discover all font folders containing font.json
        font_dirs = {}
        for zname in zf.namelist():
            if zname.endswith("/font.json"):
                folder = zname[:-len("font.json")]
                font_dirs[folder] = []
        for zname in zf.namelist():
            if zname.lower().endswith(".svg"):
                for folder in font_dirs:
                    if zname.startswith(folder) and "/" not in zname[len(folder):]:
                        font_dirs[folder].append(zname)

        # Rank folders: Arabic first, then prioritized English
        candidates = []
        for folder, svgs in font_dirs.items():
            if not svgs:
                continue
            slug = folder.rstrip("/").split("/")[-1].lower()
            try:
                meta = json.loads(zf.read(folder + "font.json").decode("utf-8", errors="ignore"))
            except Exception:
                meta = {}
            fname = str(meta.get("name") or slug)
            fname_l = fname.lower()
            def_var = str(meta.get("default_variant") or "")

            # Check Arabic / RTL
            is_ar_cand = (
                slug in ARABIC_NAMES
                or "arabic" in slug or "arabic" in fname_l
                or any(s.endswith("←.svg") or s.endswith("rtl.svg") for s in svgs)
                or "←" in def_var
            )
            if is_ar_cand:
                ar_lbl, en_lbl = ARABIC_NAMES.get(slug, (f"{fname} (عربي)", fname))
                candidates.append((0, slug, folder, svgs, meta, ar_lbl, en_lbl, True))
                continue

            # Check prioritized English
            matched_prio = None
            for idx, (kw, ar_l, en_l) in enumerate(PRIORITY_ENGLISH):
                if kw in slug or kw.replace("_", " ") in fname_l:
                    matched_prio = (idx + 1, ar_l, en_l)
                    break
            if matched_prio is not None:
                candidates.append((matched_prio[0], slug, folder, svgs, meta, matched_prio[1], matched_prio[2], False))

        candidates.sort(key=lambda x: x[0])

        en_count = sum(1 for item in compiled_index if not item["rtl"])
        for prio, slug, folder, svgs, meta, ar_lbl, en_lbl, is_ar_cand in candidates:
            clean_id = re.sub(r'[^a-z0-9_]', '_', slug)
            if clean_id in seen_ids:
                continue
            if not is_ar_cand and en_count >= 16:
                continue

            # Pick best SVG variant
            chosen_svg = None
            if is_ar_cand:
                for pref in ("←.svg", "rtl.svg"):
                    for s in svgs:
                        if s.lower().endswith(pref):
                            chosen_svg = s; break
                    if chosen_svg: break
            if not chosen_svg:
                for pref in ("→.svg", "ltr.svg"):
                    for s in svgs:
                        if s.lower().endswith(pref):
                            chosen_svg = s; break
                    if chosen_svg: break
            if not chosen_svg:
                chosen_svg = svgs[0]

            try:
                svg_bytes = zf.read(chosen_svg)
                compiled = _emb_compile_svg_font(svg_bytes, meta, clean_id, ar_lbl, en_lbl)
                if compiled is None:
                    continue
                # If marked as RTL candidate only by ←.svg, confirm it actually has Arabic glyphs (skip non-Arabic RTL)
                if is_ar_cand and not compiled.get("arabic", False):
                    continue
                out_file = os.path.join(EMB_FONTS_DIR, f"{clean_id}.json")
                raw_json = json.dumps(compiled, ensure_ascii=False, separators=(",", ":"))
                with open(out_file, "w", encoding="utf-8") as of:
                    of.write(raw_json)
                seen_ids.add(clean_id)
                if not compiled["rtl"]:
                    en_count += 1
                compiled_index.append({
                    "id": clean_id,
                    "nameAr": compiled["nameAr"],
                    "nameEn": compiled["nameEn"],
                    "rtl": compiled["rtl"],
                    "capH": compiled["capH"],
                    "spaceW": compiled["spaceW"],
                    "letterSp": compiled["letterSp"],
                    "lineH": compiled["lineH"],
                    "minScale": compiled["minScale"],
                    "maxScale": compiled["maxScale"],
                    "glyphCount": len(compiled["glyphs"]),
                    "file": f"assets/emb_fonts/{clean_id}.json",
                })
                print(f"[EmbFont OK] {clean_id} ({compiled['nameEn']}): {len(compiled['glyphs'])} glyphs, {len(raw_json)//1024} KB, rtl={compiled['rtl']}")
            except Exception as ex:
                print(f"[EmbFont Skip] {clean_id}: {ex}")

    # Always write index.json (Arabic fonts first, then English)
    compiled_index.sort(key=lambda x: (0 if x["rtl"] else 1, x["nameEn"]))
    index_path = os.path.join(EMB_FONTS_DIR, "index.json")
    with open(index_path, "w", encoding="utf-8") as f:
        json.dump({"fonts": compiled_index}, f, ensure_ascii=False, separators=(",", ":"))
    print(f"[EmbFont] Total compiled satin embroidery fonts: {len(compiled_index)}")

    # Register assets/emb_fonts/ cleanly in pubspec.yaml (YAML-safe!)
    if os.path.exists("pubspec.yaml"):
        with open("pubspec.yaml", "r", encoding="utf-8") as f:
            pub = f.read()
        if "assets/emb_fonts/" not in pub:
            if re.search(r"(?m)^  assets:\s*$", pub):
                pub = re.sub(r"(?m)^  assets:\s*$", "  assets:\n    - assets/emb_fonts/", pub, count=1)
            elif re.search(r"(?m)^flutter:\s*$", pub):
                pub = re.sub(r"(?m)^flutter:\s*$", "flutter:\n  assets:\n    - assets/emb_fonts/", pub, count=1)
            else:
                pub = pub.rstrip() + "\n\nflutter:\n  assets:\n    - assets/emb_fonts/\n"
            with open("pubspec.yaml", "w", encoding="utf-8") as f:
                f.write(pub)
            print("[EmbFont] Registered assets/emb_fonts/ in pubspec.yaml")

if os.path.exists("pubspec.yaml"):
    try:
        _emb_build_open_source_fonts()
    except Exception as _emb_ex:
        print(f"[EmbFont] Non-fatal error: {_emb_ex}")
        if not os.path.exists(os.path.join(EMB_FONTS_DIR, "index.json")):
            with open(os.path.join(EMB_FONTS_DIR, "index.json"), "w", encoding="utf-8") as _f:
                json.dump({"fonts": []}, _f)
# --- TARIK_INKSTITCH_FONTS_END ---
