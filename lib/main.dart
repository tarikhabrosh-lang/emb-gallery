import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' as intl;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'parsers/emb_parser.dart';
import 'parsers/tarik_pro_engine.dart';

final ValueNotifier<bool> isArabicNotifier = ValueNotifier<bool>(true);
final ValueNotifier<int> galleryRefreshNotifier = ValueNotifier<int>(0);
String? lastMutatedFilePath;

void notifyDesignFilesChanged([String? path]) {
  lastMutatedFilePath = path;
  galleryRefreshNotifier.value++;
}

String tr(String ar, String en) => isArabicNotifier.value ? ar : en;

String joinCleanPath(String dir, String name) {
  final cleanDir = dir.replaceAll(RegExp(r'/+$'), '');
  final cleanName = name.replaceAll(RegExp(r'^/+'), '');
  return '$cleanDir/$cleanName';
}
final validExtensions = ['.emb', '.dst', '.dhp', '.dha', '.dhe', '.tbf', '.dsb', '.exp', '.pes', '.pec', '.jef', '.ef', '.vp3', '.xxx', '.u01'];

int compareNatural(String a, String b) {
  final reg = RegExp(r'(\d+|\D+)');
  final aParts = reg.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final bParts = reg.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  final len = min(aParts.length, bParts.length);

  for (int i = 0; i < len; i++) {
    final aNum = int.tryParse(aParts[i]);
    final bNum = int.tryParse(bParts[i]);
    int cmp;
    if (aNum != null && bNum != null) {
      cmp = aNum.compareTo(bNum);
    } else {
      cmp = aParts[i].compareTo(bParts[i]);
    }
    if (cmp != 0) return cmp;
  }
  return aParts.length.compareTo(bParts.length);
}

Future<VectorDesignData?> loadAnyVectorDesign(String path) async {
  final lower = path.toLowerCase();
  VectorDesignData? v;
  if (lower.endsWith('.tbf')) {
    v = await TarikProTbfParser.loadVector(path);
  } else if (lower.endsWith('.dhe') || lower.endsWith('.dha')) {
    v = await TarikProDahaoParser.loadVector(path);
  }
  v ??= await VectorDesignLoader.load(path);
  if (v != null && (v.seqX.isNotEmpty || v.beadX.isNotEmpty)) {
    // تجهيز الفهرس المكاني مرة واحدة O(N+B+S) لتسريع الدوران والمحاكاة 1000 مرة
    TarikDesignSpatialIndex.of(v);
  }
  return v;
}

Future<EmbDesignInfo?> parseAnyDesignFile(String path) async {
  final lower = path.toLowerCase();
  EmbDesignInfo? result;
  if (lower.endsWith('.dst')) {
    result = await DstParser.parseFile(path, maxCanvas: 720.0);
    if (result != null) {
      final v3d = await loadAnyVectorDesign(path);
      if (v3d != null && v3d.stX.length >= 2) {
        final png3d = await TarikPro3DRenderer.renderVectorToPng(v3d, maxCanvas: 720.0, is3D: true, transparentBg: false, decorTheme: 0);
        if (png3d != null) {
          result = EmbDesignInfo(
            filePath: result.filePath,
            fileName: result.fileName,
            previewJpeg: png3d,
            stitches: result.stitches,
            colorCount: result.colorCount,
            stopsCount: result.stopsCount,
            jumpsCount: result.jumpsCount,
            sequinsCount: result.sequinsCount,
            beadsCount: result.beadsCount,
            trimsCount: result.trimsCount,
            machineType: result.machineType,
            colorSequence: result.colorSequence,
            widthMm: result.widthMm,
            heightMm: result.heightMm,
          );
        }
      }
    }
  } else if (lower.endsWith('.emb')) {
    result = await EmbParser.parseFile(path);
    if (result != null && result.previewJpeg != null && result.previewJpeg!.isNotEmpty) {
      final enhanced = await TarikProEmbImageEnhancer.enhancePreview(result.previewJpeg!);
      final cleanMachine = result.machineType.replaceAll(RegExp(r'Wilcom\s*', caseSensitive: false), '').trim();
      result = EmbDesignInfo(
        filePath: result.filePath,
        fileName: result.fileName,
        previewJpeg: enhanced ?? result.previewJpeg,
        stitchPreviewBytes: result.stitchPreviewBytes,
        previewWidth: result.previewWidth,
        previewHeight: result.previewHeight,
        stitches: result.stitches,
        colorCount: result.colorCount,
        stopsCount: result.stopsCount,
        jumpsCount: result.jumpsCount,
        sequinsCount: result.sequinsCount,
        trimsCount: result.trimsCount,
        beadsCount: result.beadsCount,
        machineType: cleanMachine.isEmpty ? 'EMB' : cleanMachine,
        colorSequence: result.colorSequence,
        widthMm: result.widthMm,
        heightMm: result.heightMm,
      );
    }
  } else if (lower.endsWith('.dha') || lower.endsWith('.dhe')) {
    final calVec = await TarikProDahaoParser.loadVector(path);
    if (calVec != null && calVec.stX.length >= 2) {
      final calPng = await TarikPro3DRenderer.renderVectorToPng(
        calVec,
        maxCanvas: 720.0,
        is3D: true,
        transparentBg: false,
        decorTheme: 0,
      );
      result = EmbDesignInfo(
        filePath: path,
        fileName: path.split(Platform.pathSeparator).last,
        previewJpeg: calPng,
        stitches: calVec.stitches,
        colorCount: calVec.colorCount,
        stopsCount: calVec.stopsCount,
        jumpsCount: calVec.jumpsCount,
        sequinsCount: calVec.sequinsCount,
        beadsCount: calVec.beadsCount,
        trimsCount: calVec.trimsCount,
        machineType: calVec.machineType,
        colorSequence: [],
        widthMm: calVec.widthMm,
        heightMm: calVec.heightMm,
      );
    } else {
      result = await DahaoParser.parseFile(path, maxCanvas: 720.0);
    }
  } else if (lower.endsWith('.dhp')) {
    result = await DahaoParser.parseFile(path, maxCanvas: 720.0);
    if (result != null) {
      final calVec = await loadAnyVectorDesign(path);
      if (calVec != null && calVec.stX.length >= 2) {
        final calPng = await TarikPro3DRenderer.renderVectorToPng(
          calVec,
          maxCanvas: 720.0,
          is3D: true,
          transparentBg: false,
          decorTheme: 0,
        );
        result = EmbDesignInfo(
          filePath: result.filePath,
          fileName: result.fileName,
          previewJpeg: calPng ?? result.previewJpeg,
          stitches: calVec.stitches,
          colorCount: calVec.colorCount,
          stopsCount: calVec.stopsCount,
          jumpsCount: calVec.jumpsCount,
          sequinsCount: calVec.sequinsCount,
          beadsCount: calVec.beadsCount,
          trimsCount: calVec.trimsCount,
          machineType: calVec.machineType,
          colorSequence: result.colorSequence,
          widthMm: calVec.widthMm,
          heightMm: calVec.heightMm,
        );
      }
    }
  } else if (lower.endsWith('.tbf')) {
    result = await TarikProTbfParser.parseFile(path, maxCanvas: 720.0);
  } else if (UniversalFormatParser.isSupported(lower)) {
    result = await UniversalFormatParser.parseFile(path, maxCanvas: 720.0);
  }

  // فحص ذكي لمحتوى الملف إذا كانت اللاحقة مختلفة أو مرسلة من واتساب بصيغة BIN
  result ??= await UniversalFormatParser.parseByContentFallback(path, maxCanvas: 720.0);
  if (result != null) return result;

  final name = path.split(Platform.pathSeparator).last;
  return EmbDesignInfo(
    filePath: path,
    fileName: name,
    stitches: 0,
    colorCount: 0,
    jumpsCount: 0,
    sequinsCount: 0,
    machineType: 'Other',
    colorSequence: [],
  );
}

/// مدير الكاش والمزامنة الدائمة على ذاكرة الهاتف لفتح المجلدات فوراً بدون انتظار
class DesignCacheManager {
  static final Map<String, EmbDesignInfo> _memCache = {};
  static final Map<String, Color> _bgColorMemCache = {};
  static Directory? _cacheDir;

  static Color getBgColor(String path) => _bgColorMemCache[path] ?? Colors.white;

  static Future<Directory> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory('${supportDir.path}/design_cache_v11');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  static String _keyForPath(String path) {
    int h1 = 0x811c9dc5;
    int h2 = 0x9e3779b9;
    for (int i = 0; i < path.length; i++) {
      final c = path.codeUnitAt(i);
      h1 ^= c;
      h1 = (h1 * 0x01000193) & 0xFFFFFFFF;
      h2 ^= (c + i);
      h2 = (h2 * 0x85ebca6b) & 0xFFFFFFFF;
    }
    return '${h1.toRadixString(16)}_${h2.toRadixString(16)}_${path.length}';
  }

  static EmbDesignInfo? getFromMemory(String path) => _memCache[path];

  static Future<void> invalidate(String path) async {
    _memCache.remove(path);
    _bgColorMemCache.remove(path);
    try {
      final dir = await _getCacheDir();
      final key = _keyForPath(path);
      final metaFile = File('${dir.path}/$key.json');
      final imgFile = File('${dir.path}/$key.img');
      if (await metaFile.exists()) await metaFile.delete();
      if (await imgFile.exists()) await imgFile.delete();
    } catch (_) {}
  }

  static Future<EmbDesignInfo?> getOrParse(String path) async {
    if (_memCache.containsKey(path)) {
      return _memCache[path];
    }

    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final stat = await file.stat();
      final int modMs = stat.modified.millisecondsSinceEpoch;
      final int fileSize = stat.size;

      final dir = await _getCacheDir();
      final key = _keyForPath(path);
      final metaFile = File('${dir.path}/$key.json');
      final imgFile = File('${dir.path}/$key.img');

      if (await metaFile.exists()) {
        try {
          final Map<String, dynamic> meta = jsonDecode(await metaFile.readAsString());
          if (meta['modMs'] == modMs && meta['size'] == fileSize) {
            Uint8List? previewBytes;
            if (meta['hasImg'] == true && await imgFile.exists()) {
              previewBytes = await imgFile.readAsBytes();
            }
            final info = EmbDesignInfo(
              filePath: path,
              fileName: meta['fileName'] ?? path.split(Platform.pathSeparator).last,
              previewJpeg: previewBytes,
              stitches: meta['stitches'] ?? 0,
              colorCount: meta['colorCount'] ?? 1,
              stopsCount: meta['stopsCount'] ?? 0,
              jumpsCount: meta['jumpsCount'] ?? 0,
              sequinsCount: meta['sequinsCount'] ?? 0,
              beadsCount: meta['beadsCount'] ?? 0,
              trimsCount: meta['trimsCount'] ?? 0,
              machineType: meta['machineType'] ?? 'Embroidery',
              colorSequence: [],
              widthMm: (meta['widthMm'] as num?)?.toDouble(),
              heightMm: (meta['heightMm'] as num?)?.toDouble(),
            );
            if (meta['bgColorArgb'] is int) {
              _bgColorMemCache[path] = Color(meta['bgColorArgb'] as int);
            } else if (path.toLowerCase().endsWith('.emb') && previewBytes != null && previewBytes.isNotEmpty) {
              _bgColorMemCache[path] = await TarikProEmbImageEnhancer.detectBgColor(previewBytes);
            }
            _memCache[path] = info;
            return info;
          }
        } catch (_) {}
      }

      final EmbDesignInfo? parsed = await parseAnyDesignFile(path);
      if (parsed != null) {
        _memCache[path] = parsed;
        try {
          final hasImg = parsed.previewJpeg != null && parsed.previewJpeg!.isNotEmpty;
          int? bgArgb;
          if (hasImg) {
            await imgFile.writeAsBytes(parsed.previewJpeg!, flush: false);
            if (path.toLowerCase().endsWith('.emb')) {
              final bgCol = await TarikProEmbImageEnhancer.detectBgColor(parsed.previewJpeg!);
              _bgColorMemCache[path] = bgCol;
              bgArgb = bgCol.value;
            }
          }
          final metaMap = {
            if (bgArgb != null) 'bgColorArgb': bgArgb,
            'modMs': modMs,
            'size': fileSize,
            'fileName': parsed.fileName,
            'stitches': parsed.stitches,
            'colorCount': parsed.colorCount,
            'stopsCount': parsed.stopsCount,
            'jumpsCount': parsed.jumpsCount,
            'sequinsCount': parsed.sequinsCount,
            'beadsCount': parsed.beadsCount,
            'trimsCount': parsed.trimsCount,
            'machineType': parsed.machineType,
            'widthMm': parsed.widthMm,
            'heightMm': parsed.heightMm,
            'hasImg': hasImg,
          };
          await metaFile.writeAsString(jsonEncode(metaMap), flush: false);
        } catch (_) {}
      }
      return parsed;
    } catch (_) {
      return await parseAnyDesignFile(path);
    }
  }
}

String? formatDimensionsCm(double? widthMm, double? heightMm, {bool includeMm = false}) {
  if (widthMm == null || heightMm == null) return null;
  final wCm = (widthMm / 10.0).toStringAsFixed(1);
  final hCm = (heightMm / 10.0).toStringAsFixed(1);
  final unitCm = tr('سم', 'cm');
  if (!includeMm) return '$wCm × $hCm $unitCm';
  final wMm = widthMm.toStringAsFixed(0);
  final hMm = heightMm.toStringAsFixed(0);
  final unitMm = tr('مم', 'mm');
  return '$wCm × $hCm $unitCm  ($wMm × $hMm $unitMm)';
}

class LicenseManager {
  static Future<Map<String, dynamic>> checkLicense() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/tarik_license.txt');
      if (!await file.exists()) {
        final newId = (100000 + Random().nextInt(900000)).toString();
        final now = DateTime.now().millisecondsSinceEpoch;
        await file.writeAsString('$now|false|$newId');
        return {'valid': true, 'activated': false, 'id': newId, 'days': 7};
      }
      final data = await file.readAsString();
      final parts = data.split('|');
      if (parts.length != 3) {
        return {'valid': true, 'activated': false, 'id': '123456', 'days': 7};
      }

      final installTime = int.tryParse(parts[0]) ?? 0;
      final activated = parts[1].trim() == 'true';
      final id = parts[2].trim();

      if (activated) {
        return {'valid': true, 'activated': true, 'id': id, 'days': 0};
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final diff = now - installTime;
      final daysPassed = diff / (1000 * 60 * 60 * 24);
      final remaining = 7 - daysPassed.floor();

      if (remaining > 0) {
        return {'valid': true, 'activated': false, 'id': id, 'days': remaining};
      }
      return {'valid': false, 'activated': false, 'id': id, 'days': 0};
    } catch (e) {
      return {'valid': true, 'activated': false, 'id': '123456', 'days': 7};
    }
  }

  static Future<bool> activate(String deviceId, String enteredCode) async {
    try {
      final idNum = int.tryParse(deviceId.trim()) ?? 0;
      final expectedCode = (idNum * 7) + 2026;
      if (enteredCode.trim() == expectedCode.toString()) {
        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/tarik_license.txt');
        if (await file.exists()) {
          final data = await file.readAsString();
          final parts = data.split('|');
          final t = parts.isNotEmpty ? parts[0] : DateTime.now().millisecondsSinceEpoch.toString();
          await file.writeAsString('$t|true|${deviceId.trim()}');
        } else {
          final now = DateTime.now().millisecondsSinceEpoch;
          await file.writeAsString('$now|true|${deviceId.trim()}');
        }
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0xFF0E131D),
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0E131D),
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Color(0xFF18202E),
  ));
  runApp(const EmbGalleryApp());
}

class EmbGalleryApp extends StatefulWidget {
  const EmbGalleryApp({super.key});
  @override
  State<EmbGalleryApp> createState() => _EmbGalleryAppState();
}

class _EmbGalleryAppState extends State<EmbGalleryApp> {
  Map<String, dynamic>? _license;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    await _loadLanguagePreference();
    final lic = await LicenseManager.checkLicense();
    if (mounted) {
      setState(() {
        _license = lic;
      });
    }
  }

  Future<void> _loadLanguagePreference() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/app_lang.txt');
      if (await f.exists()) {
        final code = (await f.readAsString()).trim();
        isArabicNotifier.value = (code != 'en');
      }
    } catch (_) {}
  }

  static Future<void> toggleLanguage() async {
    isArabicNotifier.value = !isArabicNotifier.value;
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/app_lang.txt');
      await f.writeAsString(isArabicNotifier.value ? 'ar' : 'en');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isArabicNotifier,
      builder: (context, isAr, _) {
        return MaterialApp(
          title: 'Tarik emb',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFD4AF37),
              brightness: Brightness.dark,
            ),
            scaffoldBackgroundColor: const Color(0xFF0E131D),
            cardColor: const Color(0xFF18202E),
          ),
          builder: (context, child) => Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: ColoredBox(
              color: const Color(0xFF0E131D),
              child: SafeArea(
                top: false,
                bottom: true,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
          home: _license == null
              ? const Scaffold(
                  backgroundColor: Color(0xFF0E131D),
                  body: Center(
                    child: CircularProgressIndicator(color: Color(0xFFD4AF37)),
                  ),
                )
              : (_license!['valid'] == true
                  ? FoldersGalleryPage(license: _license!)
                  : ActivationScreen(deviceId: _license!['id'].toString(), isExpired: true)),
        );
      },
    );
  }
}

class ActivationScreen extends StatefulWidget {
  final String deviceId;
  final bool isExpired;
  const ActivationScreen({super.key, required this.deviceId, required this.isExpired});
  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final TextEditingController _codeController = TextEditingController();
  bool _isError = false;

  void _verify() async {
    final success = await LicenseManager.activate(widget.deviceId, _codeController.text);
    if (success) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('تم تفعيل البرنامج بنجاح!', 'App activated successfully!')),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => FoldersGalleryPage(
              license: {'valid': true, 'activated': true, 'id': widget.deviceId, 'days': 0},
            ),
          ),
        );
      }
    } else {
      setState(() => _isError = true);
    }
  }

  void _openWhatsApp() async {
    await Clipboard.setData(ClipboardData(text: widget.deviceId));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('تم نسخ رقم الجهاز وجاري فتح واتساب...', 'Device ID copied, opening WhatsApp...')),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    final msg = 'أرجو تزويدي بالكود الدائم\nرقم جهازي هو: ${widget.deviceId}';
    final url = Uri.parse("https://wa.me/963956739715?text=${Uri.encodeComponent(msg)}");
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E131D),
      appBar: widget.isExpired ? null : AppBar(backgroundColor: const Color(0xFF0E131D), elevation: 0),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF18202E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFD4AF37)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.isExpired ? Icons.lock : Icons.lock_open, size: 64, color: const Color(0xFFD4AF37)),
                const SizedBox(height: 16),
                Text(
                  widget.isExpired
                      ? tr('انتهت الفترة التجريبية', 'Trial Period Expired')
                      : tr('تفعيل النسخة الدائمة', 'Activate Full Version'),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  tr(
                    'اضغط على زر الواتساب بالأسفل لنسخ رقم جهازك وإرساله تلقائياً لطلب الكود الدائم:',
                    'Tap the WhatsApp button below to copy your Device ID and send it automatically:',
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  widget.deviceId,
                  style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFF56CCF2), letterSpacing: 2),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _openWhatsApp,
                  icon: const Icon(Icons.chat, size: 20),
                  label: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(tr('تواصل عبر واتساب ', 'Contact via WhatsApp ')),
                      const Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text(
                          '+963956739715',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20, letterSpacing: 4),
                  decoration: InputDecoration(
                    hintText: tr('أدخل كود التفعيل هنا', 'Enter Activation Code'),
                    filled: true,
                    fillColor: Colors.black26,
                    errorText: _isError ? tr('الكود غير صحيح', 'Invalid Code') : null,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _verify,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD4AF37),
                    foregroundColor: Colors.black,
                    minimumSize: const Size.fromHeight(50),
                  ),
                  child: Text(tr('تفعيل البرنامج', 'Activate App'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EmbFolderGroup {
  final String folderPath, folderName;
  final List<String> filePaths;
  Uint8List? coverBytes;
  EmbFolderGroup({required this.folderPath, required this.folderName, required this.filePaths, this.coverBytes});
}

class FoldersGalleryPage extends StatefulWidget {
  final Map<String, dynamic> license;
  const FoldersGalleryPage({super.key, required this.license});
  @override
  State<FoldersGalleryPage> createState() => _FoldersGalleryPageState();
}

class _FoldersGalleryPageState extends State<FoldersGalleryPage> with WidgetsBindingObserver {
  static const MethodChannel _intentChannel = MethodChannel('tarik_emb/file_intent');
  bool _isScanning = false;
  bool _isBackgroundSyncing = false;
  String _statusText = '';
  final List<EmbFolderGroup> _folders = [];
  int _scanToken = 0;
  DateTime _lastAutoScan = DateTime.fromMillisecondsSinceEpoch(0);

  int get _totalFilesCount => _folders.fold(0, (sum, folder) => sum + folder.filePaths.length);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    galleryRefreshNotifier.addListener(_onGalleryFilesChanged);
    _intentChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFileOpened' && call.arguments is String) {
        await _openIncomingEmbFile(call.arguments as String);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      String? initialPath;
      try {
        final res = await _intentChannel.invokeMethod('getInitialFile');
        if (res is String && res.isNotEmpty) initialPath = res;
      } catch (_) {}

      if (initialPath != null) {
        await _openIncomingEmbFile(initialPath);
        _startBackgroundScan();
      } else {
        if (widget.license['activated'] != true) _showTrialToast();
        _showSignatureDialog();
        _startBackgroundScan();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_isScanning) {
      if (DateTime.now().difference(_lastAutoScan).inSeconds >= 20) {
        _startBackgroundScan(silent: true);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    galleryRefreshNotifier.removeListener(_onGalleryFilesChanged);
    super.dispose();
  }

  Future<void> _onGalleryFilesChanged() async {
    if (!mounted) return;
    final String? changedPath = lastMutatedFilePath;
    if (changedPath != null && changedPath.isNotEmpty) {
      final file = File(changedPath);
      final parentPath = file.parent.path;
      final bool exists = await file.exists();
      if (exists) {
        final info = await DesignCacheManager.getOrParse(changedPath);
        if (!mounted) return;
        setState(() {
          final idx = _folders.indexWhere((f) => f.folderPath == parentPath);
          if (idx >= 0) {
            final grp = _folders[idx];
            if (!grp.filePaths.contains(changedPath)) {
              grp.filePaths.insert(0, changedPath);
            }
            if (info?.previewJpeg != null) {
              grp.coverBytes = info!.previewJpeg;
            }
          } else {
            final folderName = parentPath.split(Platform.pathSeparator).last;
            _folders.insert(
              0,
              EmbFolderGroup(
                folderPath: parentPath,
                folderName: folderName.isEmpty ? parentPath : folderName,
                filePaths: [changedPath],
                coverBytes: info?.previewJpeg,
              ),
            );
          }
        });
        return;
      }
    }
    // في حال حذف أو تعديل جماعي، نُحدّث قائمة المجلدات تلقائياً
    await _refreshExistingFoldersSilently();
  }

  Future<void> _refreshExistingFoldersSilently() async {
    for (final folder in List<EmbFolderGroup>.from(_folders)) {
      final dir = Directory(folder.folderPath);
      if (!await dir.exists()) continue;
      final List<String> fresh = [];
      try {
        await for (final entity in dir.list(recursive: false, followLinks: false)) {
          if (entity is File) {
            final p = entity.path.toLowerCase();
            if (validExtensions.any((ext) => p.endsWith(ext))) {
              fresh.add(entity.path);
            }
          }
        }
      } catch (_) {}
      fresh.sort((a, b) => compareNatural(
            b.split(Platform.pathSeparator).last,
            a.split(Platform.pathSeparator).last,
          ));
      folder.filePaths
        ..clear()
        ..addAll(fresh);
    }
    if (mounted) {
      setState(() {
        _folders.removeWhere((f) => f.filePaths.isEmpty);
      });
    }
  }

  Future<void> _openIncomingEmbFile(String path) async {
    final EmbDesignInfo? info = await DesignCacheManager.getOrParse(path);
    if (!mounted) return;
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('تعذر قراءة الملف:', 'Could not read file:')} ${path.split(Platform.pathSeparator).last}')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DesignDetailScreen(design: info)),
    );
  }

  void _showTrialToast() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${tr('نسخة تجريبية - متبقي', 'Trial - Remaining')} ${widget.license['days']} ${tr('أيام', 'days')}'),
        backgroundColor: const Color(0xFFD4AF37),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showSignatureDialog() {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _AutoFadeWelcomeBanner(
        onFinished: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }

  Future<List<String>> _readSavedFolders() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/saved_emb_folders.txt');
      if (await f.exists()) {
        return (await f.readAsLines()).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _saveFolderToHistory(String folderPath) async {
    try {
      final List<String> current = await _readSavedFolders();
      if (!current.contains(folderPath)) {
        current.insert(0, folderPath);
        final dir = await getApplicationSupportDirectory();
        final f = File('${dir.path}/saved_emb_folders.txt');
        await f.writeAsString(current.join('\n'));
      }
    } catch (_) {}
  }

  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    try {
      if (await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted) return true;
      final manageStatus = await Permission.manageExternalStorage.request();
      if (manageStatus.isGranted) return true;
      return (await Permission.storage.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  static const Set<String> _skipRootFolders = {
    'android', 'dcim', 'pictures', 'movies', 'music', 'ringtones',
    'notifications', 'alarms', 'podcasts', 'audiobooks', 'recordings',
    'miui', 'samsung', 'lost.dir', 'system', 'obb', 'data',
  };

  Future<void> _scanDirBounded(
    Directory dir,
    Map<String, List<String>> folderMap,
    int currentToken,
    int depth,
    List<int> counterRef,
  ) async {
    if (depth > 5 || currentToken != _scanToken) return;
    try {
      await for (final entity in dir.list(recursive: false, followLinks: false)) {
        if (currentToken != _scanToken) return;
        counterRef[0]++;
        if (counterRef[0] % 35 == 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }
        final String name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;

        if (entity is File) {
          final lower = entity.path.toLowerCase();
          if (validExtensions.any((ext) => lower.endsWith(ext))) {
            folderMap.putIfAbsent(entity.parent.path, () => []).add(entity.path);
          }
        } else if (entity is Directory) {
          if (depth == 0 && _skipRootFolders.contains(name.toLowerCase())) continue;
          await _scanDirBounded(entity, folderMap, currentToken, depth + 1, counterRef);
        }
      }
    } catch (_) {}
  }

  Future<void> _startBackgroundScan({bool silent = false}) async {
    final int currentToken = ++_scanToken;
    _lastAutoScan = DateTime.now();
    final hasPerm = await _ensureStoragePermission();
    if (!hasPerm) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _statusText = tr('يرجى منح إذن الملفات', 'Please grant file permission');
      });
      return;
    }
    if (!mounted) return;
    if (!silent) {
      setState(() {
        _isScanning = true;
        _folders.clear();
        _statusText = tr('جاري البحث التلقائي عن مجلدات التطريز...', 'Auto-scanning embroidery folders...');
      });
    }

    final List<String> savedDirs = await _readSavedFolders();
    final Set<String> priorityDirs = {
      ...savedDirs,
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Documents',
      '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Documents',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Documents',
      '/storage/emulated/0/Telegram/Telegram Documents',
    };

    final Map<String, List<String>> folderMap = {};
    final Set<String> scannedRoots = {};
    final List<int> counterRef = [0];

    // 1) مسح المجلدات الأساسية أولاً لظهور فوري
    for (final rootPath in priorityDirs) {
      if (currentToken != _scanToken) return;
      final rootDir = Directory(rootPath);
      if (await rootDir.exists()) {
        scannedRoots.add(rootPath);
        await _scanDirBounded(rootDir, folderMap, currentToken, 1, counterRef);
        _rebuildFoldersList(folderMap);
      }
    }

    // 2) مسح تلقائي ذكي لجميع مجلدات المستخدم في جذر الذاكرة (مثل مجلد سمير الفرا وغيرها تلقائياً بدون إضافة يدوية)
    final internalRoot = Directory('/storage/emulated/0');
    if (await internalRoot.exists()) {
      try {
        await for (final entity in internalRoot.list(recursive: false, followLinks: false)) {
          if (currentToken != _scanToken) return;
          if (entity is Directory) {
            final name = entity.path.split(Platform.pathSeparator).last;
            if (name.startsWith('.') || _skipRootFolders.contains(name.toLowerCase())) continue;
            if (scannedRoots.contains(entity.path)) continue;
            scannedRoots.add(entity.path);
            await _scanDirBounded(entity, folderMap, currentToken, 1, counterRef);
            if (folderMap.isNotEmpty) _rebuildFoldersList(folderMap);
          } else if (entity is File) {
            final lower = entity.path.toLowerCase();
            if (validExtensions.any((ext) => lower.endsWith(ext))) {
              folderMap.putIfAbsent(entity.parent.path, () => []).add(entity.path);
            }
          }
        }
      } catch (_) {}
      _rebuildFoldersList(folderMap);
    }

    if (!mounted || currentToken != _scanToken) return;
    setState(() {
      _isScanning = false;
      _statusText = _folders.isEmpty ? tr('لم يتم العثور على مجلدات', 'No folders found') : '';
    });

    _syncAllFoldersInBackground(currentToken);
  }

  void _rebuildFoldersList(Map<String, List<String>> folderMap) {
    if (!mounted) return;
    final List<EmbFolderGroup> list = [];
    folderMap.forEach((path, files) {
      if (files.isNotEmpty) {
        final sortedFiles = List<String>.from(files)
          ..sort((a, b) => compareNatural(
                b.split(Platform.pathSeparator).last,
                a.split(Platform.pathSeparator).last,
              ));
        final name = path.split(Platform.pathSeparator).last;
        list.add(EmbFolderGroup(
          folderPath: path,
          folderName: name.isEmpty ? path : name,
          filePaths: sortedFiles,
        ));
      }
    });
    final Map<String, Uint8List?> oldCovers = {
      for (final f in _folders) f.folderPath: f.coverBytes,
    };
    for (final grp in list) {
      grp.coverBytes ??= oldCovers[grp.folderPath];
    }
    setState(() {
      _folders
        ..clear()
        ..addAll(list);
    });
  }

  Future<void> _syncAllFoldersInBackground(int token) async {
    if (mounted) setState(() => _isBackgroundSyncing = true);

    for (final folder in List<EmbFolderGroup>.from(_folders)) {
      if (!mounted || token != _scanToken) return;
      if (folder.coverBytes == null && folder.filePaths.isNotEmpty) {
        for (final pathStr in folder.filePaths) {
          if (!mounted || token != _scanToken) return;
          final EmbDesignInfo? info = await DesignCacheManager.getOrParse(pathStr);
          if (info?.previewJpeg != null && mounted && token == _scanToken) {
            setState(() {
              folder.coverBytes = info!.previewJpeg;
            });
            break;
          }
          await Future.delayed(const Duration(milliseconds: 5));
        }
      }
    }

    for (final folder in List<EmbFolderGroup>.from(_folders)) {
      if (!mounted || token != _scanToken) return;
      for (final pathStr in folder.filePaths) {
        if (!mounted || token != _scanToken) return;
        if (DesignCacheManager.getFromMemory(pathStr) == null) {
          await DesignCacheManager.getOrParse(pathStr);
          await Future.delayed(const Duration(milliseconds: 8));
        }
      }
    }

    if (mounted && token == _scanToken) {
      setState(() => _isBackgroundSyncing = false);
    }
  }

  Future<void> _pickSingleOrMultipleFiles() async {
    _scanToken++;
    setState(() => _isScanning = false);
    try {
      await _ensureStoragePermission();
      final result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
      if (result == null || result.paths.isEmpty) return;

      final List<String> validPaths = result.paths.whereType<String>().where((p) {
        final lower = p.toLowerCase();
        return validExtensions.any((ext) => lower.endsWith(ext));
      }).toList();

      if (validPaths.isEmpty) {
        _showSnack(tr('يرجى اختيار ملف تطريز مدعوم', 'Please select a valid embroidery file'));
        return;
      }
      final firstParent = File(validPaths.first).parent.path;
      await _saveFolderToHistory(firstParent);

      if (validPaths.length == 1) {
        final EmbDesignInfo? info = await DesignCacheManager.getOrParse(validPaths.first);
        if (info != null && mounted) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => DesignDetailScreen(design: info)));
        }
      } else {
        validPaths.sort((a, b) => compareNatural(
              b.split(Platform.pathSeparator).last,
              a.split(Platform.pathSeparator).last,
            ));
        final group = EmbFolderGroup(
          folderPath: firstParent,
          folderName: tr('ملفات مختارة', 'Selected Files'),
          filePaths: validPaths,
        );
        if (mounted) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => FolderDetailsScreen(folderGroup: group)));
        }
      }
    } catch (e) {
      _showSnack('${tr('تعذر فتح الملف', 'Failed to open file')}: $e');
    }
  }

  Future<void> _pickCustomFolder() async {
    _scanToken++;
    setState(() => _isScanning = false);
    try {
      await _ensureStoragePermission();
      final dirPath = await FilePicker.platform.getDirectoryPath();
      if (dirPath == null) return;
      await _saveFolderToHistory(dirPath);

      setState(() {
        _isScanning = true;
        _statusText = tr('جاري القراءة...', 'Reading...');
      });

      final List<String> files = [];
      try {
        await for (final entity in Directory(dirPath).list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final p = entity.path.toLowerCase();
            if (validExtensions.any((ext) => p.endsWith(ext))) files.add(entity.path);
          }
        }
      } catch (_) {}

      setState(() => _isScanning = false);
      if (files.isEmpty) {
        _showSnack(tr('لا توجد ملفات تطريز هنا', 'No embroidery files here'));
        return;
      }

      files.sort((a, b) => compareNatural(
            b.split(Platform.pathSeparator).last,
            a.split(Platform.pathSeparator).last,
          ));

      final folderName = dirPath.split(Platform.pathSeparator).last;
      final newGroup = EmbFolderGroup(
        folderPath: dirPath,
        folderName: folderName.isEmpty ? dirPath : folderName,
        filePaths: files,
      );
      setState(() {
        _folders.removeWhere((f) => f.folderPath == dirPath);
        _folders.insert(0, newGroup);
      });
      if (mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => FolderDetailsScreen(folderGroup: newGroup)));
      }
    } catch (e) {
      setState(() => _isScanning = false);
      _showSnack('${tr('تعذر فتح المجلد', 'Failed to open folder')}: $e');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isArabicNotifier,
      builder: (context, isAr, _) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF0E131D),
            titleSpacing: 12,
            title: const Text(
              'Tarik emb',
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFD4AF37), fontSize: 19, letterSpacing: 0.4),
            ),
            actions: [
              if (_isBackgroundSyncing)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Center(
                    child: SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD4AF37)),
                    ),
                  ),
                ),
              if (widget.license['activated'] != true)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  icon: const Icon(Icons.lock_open, color: Colors.greenAccent, size: 20),
                  tooltip: tr('تفعيل النسخة', 'Activate App'),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ActivationScreen(deviceId: widget.license['id'].toString(), isExpired: false),
                      ),
                    );
                  },
                ),
              InkWell(
                onTap: () async {
                  await _EmbGalleryAppState.toggleLanguage();
                  setState(() {});
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD4AF37).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.45)),
                  ),
                  child: Text(
                    isAr ? 'EN' : 'عربي',
                    style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                icon: const Icon(Icons.calculate_outlined, color: Color(0xFFD4AF37), size: 22),
                tooltip: tr('حساب التطريز (\$)', 'Embroidery Calculator (\$)'),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const EmbroideryCalculatorScreen()),
                  );
                },
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                icon: const Icon(Icons.text_fields, color: Color(0xFFD4AF37), size: 22),
                tooltip: tr('كتابة وتحويل لغرز', 'Text to Stitches'),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TextToEmbroideryScreen()),
                  );
                },
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                icon: const Icon(Icons.refresh, color: Color(0xFFD4AF37), size: 21),
                tooltip: tr('تحديث', 'Refresh'),
                onPressed: _startBackgroundScan,
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _pickSingleOrMultipleFiles,
                        icon: const Icon(Icons.insert_drive_file),
                        label: Text(tr('فتح ملفات التطريز', 'Open Designs')),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          backgroundColor: const Color(0xFF3E522B),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickCustomFolder,
                        icon: const Icon(Icons.create_new_folder, color: Color(0xFFD4AF37)),
                        label: Text(tr('إضافة مجلد', 'Add Folder'), style: const TextStyle(color: Color(0xFFD4AF37))),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: const BorderSide(color: Color(0xFFD4AF37)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_folders.isNotEmpty)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF18202E),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.folder_special, size: 18, color: Color(0xFFD4AF37)),
                          const SizedBox(width: 6),
                          Text(
                            '${tr('المجلدات', 'Folders')}: ${_folders.length}',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(color: const Color(0xFF3E522B), borderRadius: BorderRadius.circular(12)),
                        child: Text(
                          '${tr('الكل', 'Total')}: $_totalFilesCount',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_isScanning) const LinearProgressIndicator(color: Color(0xFFD4AF37)),
              Expanded(
                child: _folders.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.folder_copy_rounded, size: 64, color: Colors.white.withOpacity(0.25)),
                              const SizedBox(height: 12),
                              Text(_statusText, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, color: Colors.white70)),
                            ],
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 0.84,
                        ),
                        itemCount: _folders.length,
                        itemBuilder: (context, index) {
                          final folder = _folders[index];
                          return GestureDetector(
                            onTap: () async {
                              await Navigator.push(context, MaterialPageRoute(builder: (_) => FolderDetailsScreen(folderGroup: folder)));
                              if (mounted) setState(() {});
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF18202E),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.white12),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Builder(
                                          builder: (_) {
                                            final firstPath = folder.filePaths.isNotEmpty ? folder.filePaths.first : '';
                                            final isEmbCover = firstPath.toLowerCase().endsWith('.emb');
                                            final bgCol = isEmbCover ? DesignCacheManager.getBgColor(firstPath) : Colors.white;
                                            return Container(
                                              color: bgCol,
                                              padding: isEmbCover ? EdgeInsets.zero : const EdgeInsets.all(6),
                                              child: folder.coverBytes != null
                                                  ? Image.memory(
                                                      folder.coverBytes!,
                                                      width: double.infinity,
                                                      height: double.infinity,
                                                      fit: BoxFit.contain,
                                                      filterQuality: FilterQuality.high,
                                                    )
                                                  : const Center(child: Icon(Icons.folder_rounded, size: 54, color: Color(0xFFD4AF37))),
                                            );
                                          },
                                        ),
                                        Positioned(
                                          top: 8,
                                          left: 8,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF0E131D).withOpacity(0.88),
                                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(color: const Color(0xFFD4AF37), width: 1),
                                            ),
                                            child: Text(
                                              '${folder.filePaths.length} ${tr('ملف', 'files')}',
                                              style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.folder, size: 16, color: Color(0xFFD4AF37)),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Directionality(
                                            textDirection: TextDirection.ltr,
                                            child: Text(
                                              folder.folderName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum SortOption { nameDesc, nameAsc, stitchesDesc, stitchesAsc, colorsDesc }

class FolderDetailsScreen extends StatefulWidget {
  final EmbFolderGroup folderGroup;
  const FolderDetailsScreen({super.key, required this.folderGroup});
  @override
  State<FolderDetailsScreen> createState() => _FolderDetailsScreenState();
}

class _FolderDetailsScreenState extends State<FolderDetailsScreen> {
  final List<EmbDesignInfo> _designs = [];
  List<EmbDesignInfo> _filteredDesigns = [];
  bool _isLoading = true;
  bool _isBatchWorking = false;
  String _searchQuery = '';
  SortOption _sortOption = SortOption.nameDesc;
  final Set<String> _selectedPaths = {};

  bool get _selectionMode => _selectedPaths.isNotEmpty;

  @override
  void initState() {
    super.initState();
    galleryRefreshNotifier.addListener(_onExternalChange);
    _loadFolderDesignsInBackground(rescanDisk: true);
  }

  @override
  void dispose() {
    galleryRefreshNotifier.removeListener(_onExternalChange);
    super.dispose();
  }

  void _onExternalChange() {
    if (mounted) {
      _loadFolderDesignsInBackground(rescanDisk: true);
    }
  }

  Future<void> _loadFolderDesignsInBackground({bool rescanDisk = false}) async {
    if (rescanDisk) {
      final dir = Directory(widget.folderGroup.folderPath);
      if (await dir.exists()) {
        final List<String> diskFiles = [];
        try {
          await for (final entity in dir.list(recursive: false, followLinks: false)) {
            if (entity is File) {
              final p = entity.path.toLowerCase();
              if (validExtensions.any((ext) => p.endsWith(ext))) {
                diskFiles.add(entity.path);
              }
            }
          }
        } catch (_) {}
        if (diskFiles.isNotEmpty || widget.folderGroup.filePaths.isNotEmpty) {
          // دمج أي ملفات فرعية موجودة أصلاً إذا كانت قائمة مختارة، أو تحديث مباشر للمجلد الحقيقي
          final Set<String> merged = {...diskFiles};
          for (final p in widget.folderGroup.filePaths) {
            if (File(p).parent.path != widget.folderGroup.folderPath && await File(p).exists()) {
              merged.add(p);
            }
          }
          widget.folderGroup.filePaths
            ..clear()
            ..addAll(merged);
        }
      }
    }

    final List<String> paths = List<String>.from(widget.folderGroup.filePaths)
      ..sort((a, b) => compareNatural(
            b.split(Platform.pathSeparator).last,
            a.split(Platform.pathSeparator).last,
          ));

    final List<EmbDesignInfo> nextLoaded = [];
    final List<String> pendingPaths = [];
    for (final path in paths) {
      final cached = DesignCacheManager.getFromMemory(path);
      if (cached != null) {
        nextLoaded.add(cached);
      } else {
        pendingPaths.add(path);
      }
    }

    if (mounted) {
      _designs
        ..clear()
        ..addAll(nextLoaded);
      _selectedPaths.removeWhere((p) => !paths.contains(p));
      _applyFilterAndSort();
    }

    int count = 0;
    for (final path in pendingPaths) {
      if (!mounted) return;
      final EmbDesignInfo? info = await DesignCacheManager.getOrParse(path);
      if (info != null) {
        if (!_designs.any((d) => d.filePath == info.filePath)) {
          _designs.add(info);
        }
        count++;
        if (count % 6 == 0 || count == pendingPaths.length) {
          _applyFilterAndSort();
        }
      }
      await Future.delayed(const Duration(milliseconds: 2));
    }

    if (mounted) {
      setState(() => _isLoading = false);
      _applyFilterAndSort();
    }
  }

  void _applyFilterAndSort() {
    if (!mounted) return;
    final q = _searchQuery.trim().toLowerCase();
    final List<EmbDesignInfo> list = _designs.where((d) => q.isEmpty || d.fileName.toLowerCase().contains(q)).toList();
    switch (_sortOption) {
      case SortOption.nameDesc:
        list.sort((a, b) => compareNatural(b.fileName, a.fileName));
        break;
      case SortOption.nameAsc:
        list.sort((a, b) => compareNatural(a.fileName, b.fileName));
        break;
      case SortOption.stitchesDesc:
        list.sort((a, b) => b.stitches.compareTo(a.stitches));
        break;
      case SortOption.stitchesAsc:
        list.sort((a, b) => a.stitches.compareTo(b.stitches));
        break;
      case SortOption.colorsDesc:
        list.sort((a, b) => b.colorCount.compareTo(a.colorCount));
        break;
    }
    setState(() {
      _filteredDesigns = list;
    });
  }

  void _toggleSelection(String filePath) {
    setState(() {
      if (_selectedPaths.contains(filePath)) {
        _selectedPaths.remove(filePath);
      } else {
        _selectedPaths.add(filePath);
      }
    });
  }

  Future<void> _batchDeleteSelected() async {
    if (_selectedPaths.isEmpty || _isBatchWorking) return;
    final int count = _selectedPaths.length;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF18202E),
        title: Text(
          tr('تأكيد الحذف', 'Confirm Delete'),
          style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
        ),
        content: Text(
          tr(
            'هل أنت متأكد من حذف $count ملف نهائياً من الجهاز؟',
            'Are you sure you want to permanently delete $count file(s)?',
          ),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('إلغاء', 'Cancel'), style: const TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            child: Text(tr('حذف', 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isBatchWorking = true);
    int deleted = 0;
    final List<String> targets = List<String>.from(_selectedPaths);
    for (final p in targets) {
      try {
        final f = File(p);
        if (await f.exists()) {
          await f.delete();
        }
        await DesignCacheManager.invalidate(p);
        widget.folderGroup.filePaths.remove(p);
        _designs.removeWhere((d) => d.filePath == p);
        deleted++;
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _selectedPaths.clear();
        _isBatchWorking = false;
      });
      _applyFilterAndSort();
      notifyDesignFilesChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('تم حذف $deleted ملف بنجاح', 'Deleted $deleted file(s)')),
          backgroundColor: const Color(0xFF2E7D32),
        ),
      );
    }
  }

  Future<void> _batchShareSelected() async {
    if (_selectedPaths.isEmpty || _isBatchWorking) return;
    final List<XFile> xfiles = [];
    for (final p in _selectedPaths) {
      if (await File(p).exists()) {
        xfiles.add(XFile(p));
      }
    }
    if (xfiles.isEmpty) return;
    try {
      await Share.shareXFiles(xfiles);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${tr('تعذرت المشاركة', 'Share failed')}: $e')),
        );
      }
    }
  }

  Future<void> _batchConvertSelected() async {
    if (_selectedPaths.isEmpty || _isBatchWorking) return;

    final String? chosenExt = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF18202E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
              ),
              Text(
                tr(
                  'تحويل ${_selectedPaths.length} ملف إلى صيغة:',
                  'Convert ${_selectedPaths.length} file(s) to format:',
                ),
                style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const SizedBox(height: 10),
              ...UniversalExporter.supportedFormats.map((fmt) {
                final ext = fmt['ext']!;
                final label = fmt['name']!;
                return ListTile(
                  leading: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4AF37).withOpacity(0.18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('.$ext', style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold)),
                  ),
                  title: Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                  trailing: const Icon(Icons.transform, color: Colors.white60, size: 20),
                  onTap: () => Navigator.pop(ctx, ext),
                );
              }),
            ],
          ),
        ),
      ),
    );

    if (chosenExt == null || !mounted) return;
    setState(() => _isBatchWorking = true);
    int okCount = 0;
    final List<String> targets = List<String>.from(_selectedPaths);

    for (final srcPath in targets) {
      if (srcPath.toLowerCase().endsWith('.emb') || !UniversalExporter.canExport(srcPath)) continue;
      final fileName = srcPath.split(Platform.pathSeparator).last;
      final baseName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
      final parentDir = File(srcPath).parent.path;
      final outPath = joinCleanPath(parentDir, '$baseName.$chosenExt');
      String? res = await UniversalExporter.exportToFormat(srcPath, outPath, chosenExt);
      res ??= await UniversalExporter.exportToFormat(
        srcPath,
        '/storage/emulated/0/Download/$baseName.$chosenExt',
        chosenExt,
      );
      if (res != null && await File(res).exists()) {
        await DesignCacheManager.invalidate(res);
        final info = await DesignCacheManager.getOrParse(res);
        if (info != null && mounted) {
          if (!widget.folderGroup.filePaths.contains(res)) {
            widget.folderGroup.filePaths.insert(0, res);
          }
          _designs.removeWhere((d) => d.filePath == res);
          _designs.insert(0, info);
          okCount++;
        }
      }
    }

    if (mounted) {
      setState(() {
        _selectedPaths.clear();
        _isBatchWorking = false;
      });
      _applyFilterAndSort();
      notifyDesignFilesChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'تم تحويل $okCount ملف إلى .$chosenExt وحفظها في نفس المجلد',
              'Converted $okCount file(s) to .$chosenExt in the same folder',
            ),
          ),
          backgroundColor: const Color(0xFF2E7D32),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final numFmt = intl.NumberFormat('#,###');
    return ValueListenableBuilder<bool>(
      valueListenable: isArabicNotifier,
      builder: (context, isAr, _) {
        final bool allSelected =
            _filteredDesigns.isNotEmpty && _filteredDesigns.every((d) => _selectedPaths.contains(d.filePath));
        return PopScope(
          canPop: !_selectionMode,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _selectionMode) {
              setState(() => _selectedPaths.clear());
            }
          },
          child: Scaffold(
            appBar: _selectionMode
                ? AppBar(
                    backgroundColor: const Color(0xFF1F2B3E),
                    leading: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => setState(() => _selectedPaths.clear()),
                    ),
                    title: Text(
                      '${_selectedPaths.length} ${tr('محدد', 'selected')}',
                      style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    actions: [
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            if (allSelected) {
                              _selectedPaths.clear();
                            } else {
                              for (final d in _filteredDesigns) {
                                _selectedPaths.add(d.filePath);
                              }
                            }
                          });
                        },
                        icon: Icon(
                          allSelected ? Icons.deselect : Icons.select_all,
                          color: const Color(0xFFD4AF37),
                          size: 19,
                        ),
                        label: Text(
                          allSelected ? tr('إلغاء الكل', 'None') : tr('تحديد الكل', 'All'),
                          style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ),
                    ],
                  )
                : AppBar(
                    backgroundColor: const Color(0xFF0E131D),
                    title: Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(widget.folderGroup.folderName, style: const TextStyle(fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    actions: [
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Color(0xFFD4AF37), size: 20),
                        tooltip: tr('تحديث المجلد', 'Refresh Folder'),
                        onPressed: () => _loadFolderDesignsInBackground(rescanDisk: true),
                      ),
                      TextButton(
                        onPressed: () async {
                          await _EmbGalleryAppState.toggleLanguage();
                          setState(() {});
                        },
                        child: Text(isAr ? 'EN' : 'عربي', style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold)),
                      ),
                      PopupMenuButton<SortOption>(
                        icon: const Icon(Icons.sort),
                        tooltip: tr('ترتيب', 'Sort'),
                        onSelected: (opt) {
                          _sortOption = opt;
                          _applyFilterAndSort();
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: SortOption.nameDesc, child: Text(tr('الأحدث / الأكبر رقماً (9 - 1)', 'Newest / Largest (9 - 1)'))),
                          PopupMenuItem(value: SortOption.nameAsc, child: Text(tr('الاسم / الأصغر رقماً (1 - 9)', 'Name / Smallest (1 - 9)'))),
                          PopupMenuItem(value: SortOption.stitchesDesc, child: Text(tr('الأكثر غرزاً', 'Most Stitches'))),
                          PopupMenuItem(value: SortOption.stitchesAsc, child: Text(tr('الأقل غرزاً', 'Least Stitches'))),
                          PopupMenuItem(value: SortOption.colorsDesc, child: Text(tr('الأكثر ألواناً', 'Most Colors'))),
                        ],
                      ),
                    ],
                  ),
            body: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  color: const Color(0xFF18202E),
                  child: Row(
                    children: [
                      Expanded(
                        child: Directionality(
                          textDirection: TextDirection.ltr,
                          child: Text(
                            '📁 ${widget.folderGroup.folderPath}',
                            style: const TextStyle(fontSize: 11, color: Colors.white60),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (!_selectionMode && _filteredDesigns.isNotEmpty)
                        Text(
                          tr('ضغطة مطوّلة للتحديد', 'Long-press to select'),
                          style: const TextStyle(fontSize: 10, color: Color(0xFFD4AF37)),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: tr('بحث...', 'Search...'),
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: const Color(0xFF18202E),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onChanged: (val) {
                      _searchQuery = val;
                      _applyFilterAndSort();
                    },
                  ),
                ),
                if (_isLoading || _isBatchWorking) const LinearProgressIndicator(color: Color(0xFFD4AF37)),
                Expanded(
                  child: _filteredDesigns.isEmpty
                      ? Center(
                          child: Text(
                            _isLoading ? tr('جاري القراءة...', 'Loading...') : tr('لا يوجد تطابق', 'No match'),
                            style: const TextStyle(color: Colors.white70),
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 0.70,
                          ),
                          itemCount: _filteredDesigns.length,
                          itemBuilder: (context, index) {
                            final item = _filteredDesigns[index];
                            final isSelected = _selectedPaths.contains(item.filePath);
                            return _DesignGridCard(
                              design: item,
                              formattedStitches: numFmt.format(item.stitches),
                              isSelected: isSelected,
                              selectionMode: _selectionMode,
                              onLongPress: () => _toggleSelection(item.filePath),
                              onTap: () async {
                                if (_selectionMode) {
                                  _toggleSelection(item.filePath);
                                  return;
                                }
                                final exportedPath = await Navigator.push<String>(
                                  context,
                                  MaterialPageRoute(builder: (_) => DesignDetailScreen(design: item)),
                                );
                                if (exportedPath != null && exportedPath.isNotEmpty && mounted) {
                                  await DesignCacheManager.invalidate(exportedPath);
                                  final newInfo = await DesignCacheManager.getOrParse(exportedPath);
                                  if (newInfo != null && mounted) {
                                    setState(() {
                                      if (!widget.folderGroup.filePaths.contains(exportedPath)) {
                                        widget.folderGroup.filePaths.insert(0, exportedPath);
                                      }
                                      _designs.removeWhere((d) => d.filePath == exportedPath);
                                      _designs.insert(0, newInfo);
                                    });
                                    _applyFilterAndSort();
                                  }
                                }
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
            bottomNavigationBar: _selectionMode
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: const BoxDecoration(
                      color: Color(0xFF18202E),
                      border: Border(top: BorderSide(color: Colors.white12)),
                    ),
                    child: Row(
                      children: [
                        if (_selectedPaths.any((p) => !p.toLowerCase().endsWith('.emb')))
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isBatchWorking ? null : _batchConvertSelected,
                            icon: const Icon(Icons.transform, size: 18),
                            label: Text(
                              tr('تحويل صيغة', 'Convert'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFD4AF37),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isBatchWorking ? null : _batchShareSelected,
                            icon: const Icon(Icons.share, size: 18),
                            label: Text(
                              tr('مشاركة', 'Share'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF283852),
                              foregroundColor: const Color(0xFF56CCF2),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isBatchWorking ? null : _batchDeleteSelected,
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: Text(
                              tr('حذف', 'Delete'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent.withOpacity(0.18),
                              foregroundColor: Colors.redAccent,
                              side: BorderSide(color: Colors.redAccent.withOpacity(0.6)),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : null,
          ),
        );
      },
    );
  }
}

class _DesignGridCard extends StatelessWidget {
  final EmbDesignInfo design;
  final String formattedStitches;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isSelected;
  final bool selectionMode;

  const _DesignGridCard({
    required this.design,
    required this.formattedStitches,
    required this.onTap,
    this.onLongPress,
    this.isSelected = false,
    this.selectionMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final dimCmText = formatDimensionsCm(design.widthMm, design.heightMm);
    final ext = design.filePath.split('.').last.toUpperCase();
    final hasPreview = design.previewJpeg != null;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: const Color(0xFF18202E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? const Color(0xFFD4AF37) : Colors.white10,
            width: isSelected ? 2.4 : 1.0,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: ext == 'EMB' ? DesignCacheManager.getBgColor(design.filePath) : Colors.white,
                    padding: ext == 'EMB' ? EdgeInsets.zero : const EdgeInsets.all(6),
                    child: hasPreview
                        ? Image.memory(
                            design.previewJpeg!,
                            width: double.infinity,
                            height: double.infinity,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.high,
                          )
                        : Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.architecture, size: 50, color: Color(0xFF3E522B)),
                                const SizedBox(height: 8),
                                Text(ext, style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.bold, fontSize: 16)),
                              ],
                            ),
                          ),
                  ),
                  if (isSelected)
                    Container(color: const Color(0xFFD4AF37).withOpacity(0.18)),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0E131D).withOpacity(0.84),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.75), width: 0.9),
                      ),
                      child: Text(
                        '.$ext',
                        style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 10),
                      ),
                    ),
                  ),
                  if (selectionMode)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: isSelected ? const Color(0xFFD4AF37) : const Color(0xFF0E131D).withOpacity(0.7),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.6),
                        ),
                        child: isSelected
                            ? const Icon(Icons.check, size: 15, color: Colors.black)
                            : null,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(design.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  ),
                  if (dimCmText != null) ...[
                    const SizedBox(height: 3),
                    Text('📏 $dimCmText', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.w600)),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('$formattedStitches ${tr('غرزة', 'st')}', style: const TextStyle(color: Color(0xFF56CCF2), fontSize: 11)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: const Color(0xFFD4AF37).withOpacity(0.18), borderRadius: BorderRadius.circular(6)),
                        child: Text('${design.colorCount} ${tr('لون', 'col')}', style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 11)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DesignDetailScreen extends StatefulWidget {
  final EmbDesignInfo design;
  const DesignDetailScreen({super.key, required this.design});
  @override
  State<DesignDetailScreen> createState() => _DesignDetailScreenState();
}

class _DesignDetailScreenState extends State<DesignDetailScreen> {
  bool _isSharing = false;
  bool _isExportingDst = false;
  String? _lastExportedPath;
  VectorDesignData? _liveVec;
  Color _embBgColor = Colors.white;
  bool _loadingSharp = false;
  int _decorTheme = 0; // 0=ذهبي ولؤلؤي، 1=فضي ولؤلؤي، 2=لؤلؤي، 3=ملوّن

  @override
  void initState() {
    super.initState();
    _loadLiveVector();
    _detectEmbBg();
  }

  Future<void> _detectEmbBg() async {
    if (!widget.design.filePath.toLowerCase().endsWith('.emb')) return;
    final bytes = widget.design.previewJpeg;
    if (bytes == null || bytes.isEmpty) return;
    final col = await TarikProEmbImageEnhancer.detectBgColor(bytes);
    if (mounted) setState(() => _embBgColor = col);
  }

  Future<void> _loadLiveVector() async {
    final path = widget.design.filePath;
    if (!VectorDesignLoader.supportsVectorView(path)) return;
    if (mounted) setState(() => _loadingSharp = true);
    try {
      final vec = await loadAnyVectorDesign(path);
      if (vec != null && (vec.seqX.isNotEmpty || vec.beadX.isNotEmpty)) {
        await TarikProPbrSprites.ensureLoaded();
      }
      if (mounted) {
        setState(() {
          _liveVec = vec;
          _loadingSharp = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingSharp = false);
    }
  }

  String _decorThemeLabel(int theme) {
    switch (theme) {
      case 1:
        return tr('فضي', 'Silver');
      case 2:
        return tr('لؤلؤي', 'Pearl');
      case 3:
        return tr('ملوّن', 'Color');
      default:
        return tr('ذهبي', 'Gold');
    }
  }

  void _openFullScreenViewer() {
    if (widget.design.previewJpeg == null && _liveVec == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenDesignViewer(
          design: widget.design,
          initialDecorTheme: _decorTheme,
          initialBgColor: _embBgColor,
        ),
      ),
    );
  }

  Future<void> _showFormatPickerAndExport({required bool shareAfter}) async {
    if (_isExportingDst) return;
    final currentExt = widget.design.filePath.split('.').last.toUpperCase();
    final formats = UniversalExporter.supportedFormats
        .where((f) => f['ext'] != currentExt)
        .toList();
    final listToShow = formats.isNotEmpty ? formats : UniversalExporter.supportedFormats;

    final String? chosenExt = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF18202E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
              ),
              Text(
                shareAfter
                    ? tr('اختر الصيغة للتصدير والمشاركة', 'Choose format to Export & Share')
                    : tr('اختر الصيغة للتحويل والحفظ', 'Choose format to Convert & Save'),
                style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 12),
              ...listToShow.map((fmt) {
                final ext = fmt['ext']!;
                final label = fmt['name']!;
                return ListTile(
                  leading: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4AF37).withOpacity(0.18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '.$ext',
                      style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold),
                    ),
                  ),
                  title: Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  ),
                  trailing: Icon(
                    shareAfter ? Icons.share : Icons.save_alt,
                    color: Colors.white60,
                    size: 20,
                  ),
                  onTap: () => Navigator.pop(ctx, ext),
                );
              }),
            ],
          ),
        ),
      ),
    );

    if (chosenExt == null || !mounted) return;
    setState(() => _isExportingDst = true);
    try {
      final baseName = widget.design.fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
      String outPath;
      if (shareAfter) {
        final tempDir = await getTemporaryDirectory();
        outPath = joinCleanPath(tempDir.path, '$baseName.$chosenExt');
      } else {
        final parentDir = File(widget.design.filePath).parent.path;
        outPath = joinCleanPath(parentDir, '$baseName.$chosenExt');
      }

      String? resultPath = await UniversalExporter.exportToFormat(widget.design.filePath, outPath, chosenExt);
      if (resultPath == null && !shareAfter) {
        // احتياطياً الحفظ في مجلد Download إذا لم يسمح المجلد الأصلي بالكتابة
        final fallbackPath = '/storage/emulated/0/Download/$baseName.$chosenExt';
        resultPath = await UniversalExporter.exportToFormat(widget.design.filePath, fallbackPath, chosenExt);
      }

      if (resultPath != null && await File(resultPath).exists()) {
        if (shareAfter) {
          await Share.shareXFiles([XFile(resultPath)], text: '$baseName.$chosenExt');
        } else {
          _lastExportedPath = resultPath;
          // توليد معاينة التصميم للملف المُصدَّر وتحديث المجلد فوراً
          await DesignCacheManager.invalidate(resultPath);
          await DesignCacheManager.getOrParse(resultPath);
          notifyDesignFilesChanged(resultPath);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${tr('تم الحفظ في نفس المجلد:', 'Saved in same folder:')}\n$resultPath'),
                backgroundColor: const Color(0xFF2E7D32),
                duration: const Duration(seconds: 4),
              ),
            );
          }
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('تعذر التحويل إلى هذه الصيغة', 'Failed to convert to this format'))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${tr('خطأ في التصدير', 'Export error')}: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isExportingDst = false);
    }
  }

  Future<void> _shareOriginalFileOnly() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);
    try {
      final file = File(widget.design.filePath);
      if (await file.exists()) {
        await Share.shareXFiles([XFile(widget.design.filePath)]);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('الملف الأصلي غير موجود', 'Original file not found'))),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${tr('تعذرت المشاركة', 'Share failed')}: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final numFmt = intl.NumberFormat('#,###');
    final d = widget.design;
    final ext = d.filePath.split('.').last.toUpperCase();

    return ValueListenableBuilder<bool>(
      valueListenable: isArabicNotifier,
      builder: (context, isAr, _) {
        final shortCmText = formatDimensionsCm(d.widthMm, d.heightMm, includeMm: false);

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              Navigator.of(context).pop(_lastExportedPath);
            }
          },
          child: Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF0E131D),
            title: Directionality(textDirection: TextDirection.ltr, child: Text(d.fileName, style: const TextStyle(fontSize: 15))),
            actions: [
              TextButton(
                onPressed: () async {
                  await _EmbGalleryAppState.toggleLanguage();
                  setState(() {});
                },
                child: Text(isAr ? 'EN' : 'عربي', style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold)),
              ),
              if (d.previewJpeg != null)
                IconButton(
                  icon: const Icon(Icons.fullscreen, color: Color(0xFFD4AF37)),
                  tooltip: tr('تكبير بملء الشاشة', 'Full Screen Zoom'),
                  onPressed: _openFullScreenViewer,
                ),
              IconButton(
                icon: _isSharing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.share, color: Color(0xFFD4AF37)),
                tooltip: tr('مشاركة الملف الأصلي', 'Share Original File'),
                onPressed: _shareOriginalFileOnly,
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF18202E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: _openFullScreenViewer,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Container(
                            width: double.infinity,
                            height: double.infinity,
                            color: _embBgColor,
                            child: _liveVec != null
                                ? _LiveVectorViewport(
                                    data: _liveVec!,
                                    is3D: true,
                                    decorTheme: _decorTheme,
                                    bgColor: Colors.white,
                                    showCmGrid: false,
                                  )
                                : (d.previewJpeg != null
                                    ? InteractiveViewer(
                                        minScale: 0.8,
                                        maxScale: 12.0,
                                        child: SizedBox.expand(
                                          child: Image.memory(
                                            d.previewJpeg!,
                                            width: double.infinity,
                                            height: double.infinity,
                                            fit: BoxFit.contain,
                                            filterQuality: FilterQuality.high,
                                            isAntiAlias: true,
                                            gaplessPlayback: true,
                                          ),
                                        ),
                                      )
                                : Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        const Icon(Icons.architecture, size: 64, color: Color(0xFF3E522B)),
                                        const SizedBox(height: 8),
                                        Text('$ext Format', style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.bold, fontSize: 18)),
                                        const SizedBox(height: 2),
                                        Text(
                                          tr('صيغة تشغيل ماكينة', 'Machine Format'),
                                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  )),
                          ),
                          if (_loadingSharp)
                            const Positioned(
                              top: 8,
                              right: 8,
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD4AF37)),
                              ),
                            ),
                          if (_liveVec != null || d.previewJpeg != null)
                            Positioned(
                              bottom: 8,
                              left: 8,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Material(
                                    color: const Color(0xFF0E131D).withOpacity(0.86),
                                    borderRadius: BorderRadius.circular(18),
                                    child: InkWell(
                                      onTap: _openFullScreenViewer,
                                      borderRadius: BorderRadius.circular(18),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.zoom_in, size: 16, color: Color(0xFFD4AF37)),
                                            const SizedBox(width: 4),
                                            Text(tr('تكبير', 'Zoom'), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),

                                  if (VectorDesignLoader.supportsVectorView(d.filePath) && (d.sequinsCount > 0 || d.beadsCount > 0)) ...[
                                    const SizedBox(width: 6),
                                    Material(
                                      color: const Color(0xFF0E131D).withOpacity(0.86),
                                      borderRadius: BorderRadius.circular(18),
                                      child: InkWell(
                                        onTap: _loadingSharp
                                            ? null
                                            : () => setState(() => _decorTheme = (_decorTheme + 1) % 4),
                                        borderRadius: BorderRadius.circular(18),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                          child: Text(
                                            '✨ ${_decorThemeLabel(_decorTheme)}',
                                            style: const TextStyle(
                                              color: Color(0xFFD4AF37),
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // مسار الملف مضغوط بسطر واحد
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
                            child: Row(
                              children: [
                                const Icon(Icons.folder_open, size: 13, color: Color(0xFFD4AF37)),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Directionality(
                                    textDirection: TextDirection.ltr,
                                    child: Text(
                                      d.filePath,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white60, fontSize: 10.5),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          // شريط البيانات مضغوط وموحّد بدون تكرار المقاس
                          Wrap(
                            spacing: 14,
                            runSpacing: 6,
                            alignment: WrapAlignment.spaceEvenly,
                            children: [
                              if (d.stitches > 0) _StatBadge(label: tr('الغرز', 'Stitches'), value: numFmt.format(d.stitches), color: const Color(0xFF56CCF2)),
                              if (shortCmText != null) _StatBadge(label: tr('المقاس (سم)', 'Size (cm)'), value: shortCmText, color: Colors.lightGreenAccent),
                              _StatBadge(label: tr('الألوان', 'Colors'), value: '${d.colorCount}', color: const Color(0xFFD4AF37)),
                              if (d.sequinsCount > 0) _StatBadge(label: tr('الترتر', 'Sequins'), value: numFmt.format(d.sequinsCount), color: Colors.pinkAccent),
                              if (d.beadsCount > 0) _StatBadge(label: tr('الخرز', 'Beads'), value: numFmt.format(d.beadsCount), color: const Color(0xFFFFCA28)),
                              _StatBadge(label: tr('الماكينة', 'Machine'), value: d.machineType, color: Colors.purpleAccent),
                            ],
                          ),
                          const SizedBox(height: 9),
                          // صف الأوامر 1: محاكاة الغرز + تعديل التصميم
                          if (VectorDesignLoader.supportsVectorView(d.filePath)) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(builder: (_) => StitchSimulatorScreen(design: d)),
                                      );
                                    },
                                    icon: const Icon(Icons.play_circle_outline, size: 17),
                                    label: Text(
                                      tr('محاكاة الغرز', 'Simulate'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF283852),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
                                      minimumSize: const Size(0, 38),
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () async {
                                      final editedPath = await Navigator.push<String>(
                                        context,
                                        MaterialPageRoute(builder: (_) => DesignEditorScreen(design: d)),
                                      );
                                      if (editedPath != null && editedPath.isNotEmpty) {
                                        _lastExportedPath = editedPath;
                                      }
                                    },
                                    icon: const Icon(Icons.tune, size: 17),
                                    label: Text(
                                      tr('تعديل التصميم', 'Edit Design'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF3E522B),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
                                      minimumSize: const Size(0, 38),
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                          ],
                          // صف الأوامر 2: تحديد عنصر + حساب التطريز (بجانب بعض لعدم التمرير)
                          if (VectorDesignLoader.supportsVectorView(d.filePath) || d.stitches > 0) ...[
                            Row(
                              children: [
                                if (VectorDesignLoader.supportsVectorView(d.filePath))
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () async {
                                        final editedPath = await Navigator.push<String>(
                                          context,
                                          MaterialPageRoute(builder: (_) => ObjectEditorScreen(design: d)),
                                        );
                                        if (editedPath != null && editedPath.isNotEmpty) {
                                          _lastExportedPath = editedPath;
                                        }
                                      },
                                      icon: const Icon(Icons.select_all, size: 17, color: Color(0xFFD4AF37)),
                                      label: Text(
                                        tr('تحديد عنصر', 'Select Element'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF1F2B3E),
                                        foregroundColor: Colors.white,
                                        side: BorderSide(color: const Color(0xFFD4AF37).withOpacity(0.55)),
                                        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
                                        minimumSize: const Size(0, 38),
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                    ),
                                  ),
                                if (VectorDesignLoader.supportsVectorView(d.filePath) && d.stitches > 0)
                                  const SizedBox(width: 8),
                                if (d.stitches > 0)
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => EmbroideryCalculatorScreen(design: d),
                                          ),
                                        );
                                      },
                                      icon: const Icon(Icons.calculate, size: 17, color: Colors.greenAccent),
                                      label: Text(
                                        tr('حساب التطريز', 'Calculator'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.greenAccent),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        side: BorderSide(color: Colors.greenAccent.withOpacity(0.55)),
                                        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
                                        minimumSize: const Size(0, 38),
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 7),
                          ],
                          // صف الأوامر 3: تصدير وحفظ + تصدير ومشاركة (ظاهر دائماً بدون رفع الشاشة)
                          if (!d.filePath.toLowerCase().endsWith('.emb') && UniversalExporter.canExport(d.filePath))
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _isExportingDst ? null : () => _showFormatPickerAndExport(shareAfter: false),
                                    icon: _isExportingDst
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD4AF37)),
                                          )
                                        : const Icon(Icons.save_alt, size: 17, color: Color(0xFFD4AF37)),
                                    label: Text(
                                      tr('تصدير وحفظ', 'Export & Save'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: Color(0xFFD4AF37)),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Color(0xFFD4AF37), width: 1.3),
                                      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
                                      minimumSize: const Size(0, 40),
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: _isExportingDst ? null : () => _showFormatPickerAndExport(shareAfter: true),
                                    icon: _isExportingDst
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                                          )
                                        : const Icon(Icons.ios_share, size: 17),
                                    label: Text(
                                      tr('تصدير ومشاركة', 'Export & Share'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFD4AF37),
                                      foregroundColor: Colors.black,
                                      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
                                      minimumSize: const Size(0, 40),
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          if (d.colorSequence.isNotEmpty) ...[
                            const SizedBox(height: 7),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  showModalBottomSheet(
                                    context: context,
                                    backgroundColor: const Color(0xFF18202E),
                                    shape: const RoundedRectangleBorder(
                                      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                                    ),
                                    builder: (ctx) => SafeArea(
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Row(
                                              children: [
                                                const Icon(Icons.palette_outlined, size: 18, color: Color(0xFFD4AF37)),
                                                const SizedBox(width: 8),
                                                Text(
                                                  '${tr('جدول تسلسل الألوان والتوقفات', 'Color Sequence & Stops')} (${d.colorSequence.length})',
                                                  style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 14),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 10),
                                            Flexible(
                                              child: ListView.builder(
                                                shrinkWrap: true,
                                                itemCount: d.colorSequence.length,
                                                itemBuilder: (_, idx) {
                                                  final ThreadColorStep s = d.colorSequence[idx] as ThreadColorStep;
                                                  return Container(
                                                    margin: const EdgeInsets.only(bottom: 6),
                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                                    decoration: BoxDecoration(
                                                      color: Colors.black26,
                                                      borderRadius: BorderRadius.circular(10),
                                                    ),
                                                    child: Row(
                                                      children: [
                                                        Container(
                                                          width: 22,
                                                          height: 22,
                                                          decoration: BoxDecoration(
                                                            color: Color(s.colorValue),
                                                            shape: BoxShape.circle,
                                                            border: Border.all(color: Colors.white54, width: 1.5),
                                                          ),
                                                        ),
                                                        const SizedBox(width: 10),
                                                        Text(
                                                          '#${s.stopNumber}',
                                                          style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12),
                                                        ),
                                                        const SizedBox(width: 10),
                                                        Expanded(
                                                          child: Text(
                                                            s.colorName,
                                                            maxLines: 1,
                                                            overflow: TextOverflow.ellipsis,
                                                            style: const TextStyle(color: Colors.white, fontSize: 13),
                                                          ),
                                                        ),
                                                        if (s.stitches > 0)
                                                          Text(
                                                            '${numFmt.format(s.stitches)} ${tr('غرزة', 'st')}',
                                                            style: const TextStyle(color: Color(0xFF56CCF2), fontSize: 12),
                                                          ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.palette_outlined, size: 16, color: Color(0xFFD4AF37)),
                                label: Text(
                                  '${tr('جدول الألوان والتوقفات', 'Color Sequence')} (${d.colorSequence.length})',
                                  style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: const Color(0xFFD4AF37).withOpacity(0.45)),
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  minimumSize: const Size(0, 36),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                              ),
                            ),
                          ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        );
      },
    );
  }
}

class FullScreenDesignViewer extends StatefulWidget {
  final EmbDesignInfo design;
  final int initialDecorTheme;
  final Color initialBgColor;
  const FullScreenDesignViewer({
    super.key,
    required this.design,
    this.initialDecorTheme = 0,
    this.initialBgColor = Colors.white,
  });
  @override
  State<FullScreenDesignViewer> createState() => _FullScreenDesignViewerState();
}

class _FullScreenDesignViewerState extends State<FullScreenDesignViewer> {
  final TransformationController _transformController = TransformationController();
  final GlobalKey<_LiveVectorViewportState> _liveKey = GlobalKey<_LiveVectorViewportState>();
  TapDownDetails? _doubleTapDetails;
  Color _canvasBg = Colors.white;
  bool _showCmGrid = false;
  int _decorTheme = 0;
  VectorDesignData? _liveVec;
  bool _loadingVec = false;

  @override
  void initState() {
    super.initState();
    _canvasBg = widget.initialBgColor;
    _decorTheme = widget.initialDecorTheme;
    _loadVectorIfSupported();
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  String _decorThemeLabel(int t) {
    switch (t) {
      case 1: return tr('فضي', 'Silver');
      case 2: return tr('لؤلؤي', 'Pearl');
      case 3: return tr('ملوّن', 'Color');
      default: return tr('ذهبي', 'Gold');
    }
  }

  Future<void> _loadVectorIfSupported() async {
    if (!VectorDesignLoader.supportsVectorView(widget.design.filePath)) return;
    if (mounted) setState(() => _loadingVec = true);
    try {
      final vec = await loadAnyVectorDesign(widget.design.filePath);
      if (vec != null && (vec.seqX.isNotEmpty || vec.beadX.isNotEmpty)) {
        await TarikProPbrSprites.ensureLoaded();
      }
      if (mounted) {
        setState(() {
          _liveVec = vec;
          _loadingVec = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingVec = false);
    }
  }

  void _handleDoubleTap() {
    if (_transformController.value != Matrix4.identity()) {
      _transformController.value = Matrix4.identity();
    } else if (_doubleTapDetails != null) {
      final position = _doubleTapDetails!.localPosition;
      _transformController.value = Matrix4.identity()
        ..translate(-position.dx * 3, -position.dy * 3)
        ..scale(4.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.design;
    return Scaffold(
      backgroundColor: _canvasBg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        foregroundColor: Colors.white,
        title: Directionality(textDirection: TextDirection.ltr, child: Text(d.fileName, style: const TextStyle(fontSize: 14))),
        actions: [
          if (_loadingVec)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD4AF37)),
                ),
              ),
            ),
          IconButton(
            onPressed: () {
              if (_liveVec != null) {
                _liveKey.currentState?.resetView();
              } else {
                _transformController.value = Matrix4.identity();
              }
            },
            icon: const Icon(Icons.fit_screen),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: _liveVec != null
                ? _LiveVectorViewport(
                    key: _liveKey,
                    data: _liveVec!,
                    is3D: true,
                    decorTheme: _decorTheme,
                    bgColor: _canvasBg,
                    showCmGrid: _showCmGrid,
                    maxZoom: 35.0,
                  )
                : (d.previewJpeg != null
                    ? GestureDetector(
                        onDoubleTapDown: (details) => _doubleTapDetails = details,
                        onDoubleTap: _handleDoubleTap,
                        child: InteractiveViewer(
                          transformationController: _transformController,
                          minScale: 0.5,
                          maxScale: 16.0,
                          boundaryMargin: const EdgeInsets.all(120),
                          child: SizedBox.expand(
                            child: Image.memory(
                              d.previewJpeg!,
                              width: double.infinity,
                              height: double.infinity,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              isAntiAlias: true,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink()),
          ),
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 14,
            left: 14,
            right: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0E131D).withOpacity(0.92),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Text(tr('الخلفية:', 'BG:'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      const SizedBox(width: 6),
                      _BgColorDot(color: Colors.white, isSelected: _canvasBg == Colors.white, onTap: () => setState(() => _canvasBg = Colors.white)),
                      _BgColorDot(color: const Color(0xFF0E131D), isSelected: _canvasBg == const Color(0xFF0E131D), onTap: () => setState(() => _canvasBg = const Color(0xFF0E131D))),
                      _BgColorDot(color: Colors.black, isSelected: _canvasBg == Colors.black, onTap: () => setState(() => _canvasBg = Colors.black)),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_liveVec != null) ...[

                        if (_liveVec!.seqX.isNotEmpty || _liveVec!.beadX.isNotEmpty) ...[
                          TextButton(
                            onPressed: () => setState(() => _decorTheme = (_decorTheme + 1) % 4),
                            style: TextButton.styleFrom(
                              backgroundColor: const Color(0xFFD4AF37).withOpacity(0.20),
                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                            ),
                            child: Text(
                              '✨ ${_decorThemeLabel(_decorTheme)}',
                              style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 11.5, fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        TextButton.icon(
                          onPressed: () => setState(() => _showCmGrid = !_showCmGrid),
                          style: TextButton.styleFrom(
                            backgroundColor: _showCmGrid ? Colors.tealAccent.withOpacity(0.22) : Colors.white10,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          ),
                          icon: Icon(Icons.grid_on, size: 15, color: _showCmGrid ? Colors.tealAccent : Colors.white60),
                          label: Text(
                            '1cm',
                            style: TextStyle(color: _showCmGrid ? Colors.tealAccent : Colors.white60, fontSize: 11.5, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// عارض متجهي حي فائق النقاء وسلس 60 FPS (GPU Snapshot Cache + Live Zoom Re-render + ClipRect):
/// - يجمّد اللوحة على كرت الشاشة أثناء تحريك الأصابع لسرعة 60 إطار/ثانية حتى لملفات 200 ألف غرزة و20 ألف خرزة
/// - فور رفع الإصبع يعيد توليد المنطقة الظاهرة بدقة 3D مجهرية (0.41 مم، برمة 20°، وخامات 256×256)
/// - يقص الحدود بصرامة (ClipRect) لمنع خروج أي غرزة على لوحة المعلومات
class _LiveVectorViewport extends StatefulWidget {
  final VectorDesignData data;
  final bool is3D;
  final int decorTheme;
  final Color bgColor;
  final bool showCmGrid;
  final double maxZoom;

  const _LiveVectorViewport({
    super.key,
    required this.data,
    required this.is3D,
    this.decorTheme = 0,
    this.bgColor = Colors.white,
    this.showCmGrid = false,
    this.maxZoom = 30.0,
  });

  @override
  State<_LiveVectorViewport> createState() => _LiveVectorViewportState();
}

class _LiveVectorViewportState extends State<_LiveVectorViewport> {
  double _zoom = 1.0;
  Offset _pan = Offset.zero;
  double _startZoom = 1.0;
  Offset _startPan = Offset.zero;
  Offset _startFocal = Offset.zero;
  Size _viewSize = Size.zero;

  // كاش GPU للرسمة الحالية لسرعة 60 FPS أثناء السحب والتكبير
  ui.Image? _snapshotImg;
  double _snapZoom = 1.0;
  Offset _snapPan = Offset.zero;
  Size _snapSize = Size.zero;
  int _renderToken = 0;
  Timer? _debounceTimer;
  bool _isInteracting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleSnapshot(immediate: true));
  }

  @override
  void didUpdateWidget(covariant _LiveVectorViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data ||
        oldWidget.is3D != widget.is3D ||
        oldWidget.decorTheme != widget.decorTheme ||
        oldWidget.bgColor != widget.bgColor ||
        oldWidget.showCmGrid != widget.showCmGrid) {
      _scheduleSnapshot(immediate: true);
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _snapshotImg?.dispose();
    super.dispose();
  }

  void resetView() {
    setState(() {
      _zoom = 1.0;
      _pan = Offset.zero;
    });
    _scheduleSnapshot(immediate: true);
  }

  void _scheduleSnapshot({bool immediate = false}) {
    _debounceTimer?.cancel();
    if (immediate) {
      _renderSnapshotNow();
    } else {
      _debounceTimer = Timer(const Duration(milliseconds: 90), _renderSnapshotNow);
    }
  }

  Future<void> _renderSnapshotNow() async {
    if (!mounted || _viewSize.width < 16 || _viewSize.height < 16) return;
    final int tok = ++_renderToken;
    final Size sz = _viewSize;
    final double curZoom = _zoom;
    final Offset curPan = _pan;
    final double dpr = (MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0).clamp(1.0, 2.0);
    // سقف دقة GPU متوازن (1400px) لضمان استجابة لحظية (<50ms) ووضوح فائق
    final double maxSide = max(sz.width, sz.height) * dpr;
    final double effDpr = maxSide > 1400.0 ? (1400.0 / max(sz.width, sz.height)) : dpr;
    final int imgW = max(32, (sz.width * effDpr).round());
    final int imgH = max(32, (sz.height * effDpr).round());

    if (widget.data.seqX.isNotEmpty || widget.data.beadX.isNotEmpty) {
      await TarikProPbrSprites.ensureLoaded();
      if (!mounted || tok != _renderToken) return;
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()));
    canvas.scale(effDpr, effDpr);
    canvas.clipRect(Offset.zero & sz);
    canvas.drawRect(Offset.zero & sz, Paint()..color = widget.bgColor);

    final data = widget.data;
    if (data.hasBounds && data.stX.length >= 2) {
      final double rawW = max(1.0, data.maxX - data.minX);
      final double rawH = max(1.0, data.maxY - data.minY);
      const double pad = 22.0;
      final double baseScale = min((sz.width - pad * 2) / rawW, (sz.height - pad * 2) / rawH);
      final double scale = baseScale * curZoom;
      final double baseOffX = (sz.width - rawW * baseScale) * 0.5 - data.minX * baseScale;
      final double baseOffY = (sz.height - rawH * baseScale) * 0.5 - data.minY * baseScale;
      final double cx = sz.width * 0.5;
      final double cy = sz.height * 0.5;
      final double offX = (baseOffX - cx) * curZoom + cx + curPan.dx;
      final double offY = (baseOffY - cy) * curZoom + cy + curPan.dy;

      if (widget.showCmGrid) {
        TarikUnifiedCanvasRenderer.drawCmGrid(canvas, sz, scale: scale, originX: offX, originY: offY);
      }
      TarikUnifiedCanvasRenderer.paintDesign(
        canvas: canvas,
        data: data,
        scale: scale,
        offX: offX,
        offY: offY,
        is3D: true,
        decorTheme: widget.decorTheme,
        visibleRect: Offset.zero & sz,
      );
    }

    final pic = recorder.endRecording();
    final ui.Image nextImg = await pic.toImage(imgW, imgH);
    pic.dispose();

    if (!mounted || tok != _renderToken) {
      nextImg.dispose();
      return;
    }
    final old = _snapshotImg;
    setState(() {
      _snapshotImg = nextImg;
      _snapZoom = curZoom;
      _snapPan = curPan;
      _snapSize = sz;
    });
    old?.dispose();
  }

  void _onScaleStart(ScaleStartDetails d) {
    _isInteracting = true;
    _debounceTimer?.cancel();
    _startZoom = _zoom;
    _startPan = _pan;
    _startFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_viewSize == Size.zero) return;
    final double nextZoom = (_startZoom * d.scale).clamp(0.5, widget.maxZoom);
    final Offset center = Offset(_viewSize.width * 0.5, _viewSize.height * 0.5);
    final Offset focalFromCenter = _startFocal - center;
    final double ratio = nextZoom / _startZoom;
    final Offset nextPan = (_startPan - focalFromCenter) * ratio + focalFromCenter + (d.localFocalPoint - _startFocal);
    setState(() {
      _zoom = nextZoom;
      _pan = nextPan;
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _isInteracting = false;
    _scheduleSnapshot(immediate: false);
  }

  void _onDoubleTap() {
    if ((_zoom - 1.0).abs() > 0.05 || _pan.distance > 2.0) {
      resetView();
    } else {
      setState(() => _zoom = 4.0);
      _scheduleSnapshot(immediate: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: LayoutBuilder(
        builder: (ctx, c) {
          final nextSize = Size(c.maxWidth, c.maxHeight);
          if ((nextSize.width - _viewSize.width).abs() > 2.0 || (nextSize.height - _viewSize.height).abs() > 2.0) {
            _viewSize = nextSize;
            WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleSnapshot(immediate: true));
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: _onDoubleTap,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: ColoredBox(
              color: widget.bgColor,
              child: CustomPaint(
                painter: _LiveVectorViewportPainter(
                  data: widget.data,
                  decorTheme: widget.decorTheme,
                  showCmGrid: widget.showCmGrid,
                  zoom: _zoom,
                  pan: _pan,
                  snapshotImg: _snapshotImg,
                  snapZoom: _snapZoom,
                  snapPan: _snapPan,
                  snapSize: _snapSize,
                  isInteracting: _isInteracting,
                ),
                size: Size.infinite,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LiveVectorViewportPainter extends CustomPainter {
  final VectorDesignData data;
  final int decorTheme;
  final bool showCmGrid;
  final double zoom;
  final Offset pan;
  final ui.Image? snapshotImg;
  final double snapZoom;
  final Offset snapPan;
  final Size snapSize;
  final bool isInteracting;

  const _LiveVectorViewportPainter({
    required this.data,
    required this.decorTheme,
    required this.showCmGrid,
    required this.zoom,
    required this.pan,
    required this.snapshotImg,
    required this.snapZoom,
    required this.snapPan,
    required this.snapSize,
    required this.isInteracting,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    if (snapshotImg != null && snapSize.width > 1 && snapSize.height > 1) {
      // عرض فوري 60 FPS من كاش كرت الشاشة مع تحويل مصفوفة دقيق أثناء السحب والتكبير
      final double relScale = zoom / max(0.01, snapZoom);
      final double cx = size.width * 0.5;
      final double cy = size.height * 0.5;
      final double dx = (pan.dx - snapPan.dx * relScale);
      final double dy = (pan.dy - snapPan.dy * relScale);

      canvas.save();
      canvas.translate(cx + dx, cy + dy);
      canvas.scale(relScale, relScale);
      canvas.translate(-cx, -cy);
      canvas.drawImageRect(
        snapshotImg!,
        Rect.fromLTWH(0, 0, snapshotImg!.width.toDouble(), snapshotImg!.height.toDouble()),
        Offset.zero & snapSize,
        Paint()..filterQuality = isInteracting ? FilterQuality.low : FilterQuality.high,
      );
      canvas.restore();
      canvas.restore();
      return;
    }

    // رسم احتياطي فوري لأول إطار قبل جاهزية الكاش
    if (data.hasBounds && data.stX.length >= 2) {
      final double rawW = max(1.0, data.maxX - data.minX);
      final double rawH = max(1.0, data.maxY - data.minY);
      const double pad = 22.0;
      final double baseScale = min((size.width - pad * 2) / rawW, (size.height - pad * 2) / rawH);
      final double scale = baseScale * zoom;
      final double baseOffX = (size.width - rawW * baseScale) * 0.5 - data.minX * baseScale;
      final double baseOffY = (size.height - rawH * baseScale) * 0.5 - data.minY * baseScale;
      final double cx = size.width * 0.5;
      final double cy = size.height * 0.5;
      final double offX = (baseOffX - cx) * zoom + cx + pan.dx;
      final double offY = (baseOffY - cy) * zoom + cy + pan.dy;

      if (showCmGrid) {
        TarikUnifiedCanvasRenderer.drawCmGrid(canvas, size, scale: scale, originX: offX, originY: offY);
      }
      TarikUnifiedCanvasRenderer.paintDesign(
        canvas: canvas,
        data: data,
        scale: scale,
        offX: offX,
        offY: offY,
        is3D: true,
        decorTheme: decorTheme,
        visibleRect: Offset.zero & size,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LiveVectorViewportPainter oldDelegate) {
    return oldDelegate.snapshotImg != snapshotImg ||
        oldDelegate.zoom != zoom ||
        oldDelegate.pan != pan ||
        oldDelegate.data != data ||
        oldDelegate.decorTheme != decorTheme ||
        oldDelegate.showCmGrid != showCmGrid;
  }
}

class _BgColorDot extends StatelessWidget {
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;
  const _BgColorDot({required this.color, required this.isSelected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: isSelected ? const Color(0xFFD4AF37) : Colors.white38, width: isSelected ? 2.5 : 1),
        ),
      ),
    );
  }
}

class _StatBadge extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatBadge({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: color)),
        const SizedBox(height: 1),
        Text(label, style: const TextStyle(fontSize: 10.5, color: Colors.white60)),
      ],
    );
  }
}


class _AutoFadeWelcomeBanner extends StatefulWidget {
  final VoidCallback onFinished;
  const _AutoFadeWelcomeBanner({required this.onFinished});
  @override
  State<_AutoFadeWelcomeBanner> createState() => _AutoFadeWelcomeBannerState();
}

class _AutoFadeWelcomeBannerState extends State<_AutoFadeWelcomeBanner> {
  double _opacity = 0.0;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) setState(() => _opacity = 1.0);
    });
    Future.delayed(const Duration(milliseconds: 2100), () {
      if (mounted) setState(() => _opacity = 0.0);
    });
    Future.delayed(const Duration(milliseconds: 2700), () {
      widget.onFinished();
    });
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Material(
        color: Colors.transparent,
        child: Center(
          child: AnimatedOpacity(
            opacity: _opacity,
            duration: const Duration(milliseconds: 550),
            curve: Curves.easeInOut,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 28),
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
              decoration: BoxDecoration(
                color: const Color(0xFF0E131D).withOpacity(0.76),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.65), width: 1.6),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.45),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Tarik emb',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 30,
                      letterSpacing: 1.4,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'By Tarik Habrosh',
                    style: TextStyle(
                      color: Color(0xFFD4AF37),
                      fontWeight: FontWeight.w700,
                      fontSize: 20,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// شاشة محاكاة سير الغرز (Stitch Player) مع تحكم بالسرعة وشريط التمرير
class StitchSimulatorScreen extends StatefulWidget {
  final EmbDesignInfo? design;
  final VectorDesignData? initialVector;
  const StitchSimulatorScreen({super.key, this.design, this.initialVector});
  @override
  State<StitchSimulatorScreen> createState() => _StitchSimulatorScreenState();
}

class _StitchSimulatorScreenState extends State<StitchSimulatorScreen> {
  VectorDesignData? _vec;
  List<int> _colorStarts = [0];
  bool _loading = true;
  bool _playing = false;
  int _currentStitch = 0;
  int _speedIndex = 0; // يبدأ من أبطأ سرعة (0.2x)
  static const List<int> _speedSteps = [1, 3, 8, 20, 55, 140, 350];
  static const List<String> _speedLabels = ['0.2x', '0.5x', '1x', '3x', '8x', '20x', '45x'];
  Timer? _timer;
  double _simZoom = 1.0;
  Offset _simPan = Offset.zero;
  double _simStartZoom = 1.0;
  Offset _simStartPan = Offset.zero;
  Offset _simStartFocal = Offset.zero;
  Size _simSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _loadVector();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<int> _computeColorStarts(VectorDesignData v) {
    final List<int> starts = [0];
    for (int i = 1; i < v.stColor.length; i++) {
      if (v.stColor[i] != v.stColor[i - 1]) {
        starts.add(i);
      }
    }
    return starts;
  }

  int get _activeColorBlock {
    int idx = 0;
    for (int i = 0; i < _colorStarts.length; i++) {
      if (_currentStitch >= _colorStarts[i]) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  void _jumpToNextColor() {
    if (_vec == null || _colorStarts.isEmpty) return;
    final int cur = _activeColorBlock;
    if (cur + 1 < _colorStarts.length) {
      setState(() => _currentStitch = _colorStarts[cur + 1]);
    } else {
      _pausePlayback();
      setState(() => _currentStitch = _vec!.stX.length);
    }
  }

  void _jumpToPrevColor() {
    if (_vec == null || _colorStarts.isEmpty) return;
    final int cur = _activeColorBlock;
    if (_currentStitch > _colorStarts[cur] + 2) {
      setState(() => _currentStitch = _colorStarts[cur]);
    } else if (cur > 0) {
      setState(() => _currentStitch = _colorStarts[cur - 1]);
    } else {
      setState(() => _currentStitch = 0);
    }
  }

  void _stopPlayback() {
    _timer?.cancel();
    setState(() {
      _playing = false;
      _currentStitch = 0;
    });
  }

  Future<void> _loadVector() async {
    final v = widget.initialVector ?? (widget.design != null ? await loadAnyVectorDesign(widget.design!.filePath) : null);
    if (v != null && (v.seqX.isNotEmpty || v.beadX.isNotEmpty)) {
      await TarikProPbrSprites.ensureLoaded();
    }
    if (!mounted) return;
    setState(() {
      _vec = v;
      _colorStarts = v != null ? _computeColorStarts(v) : [0];
      _loading = false;
      _currentStitch = 0;
      _speedIndex = 0; // أبطأ سرعة
    });
    if (v != null && v.stX.length > 2) {
      _startPlayback();
    }
  }

  void _startPlayback() {
    if (_vec == null) return;
    final total = _vec!.stX.length;
    if (_currentStitch >= total - 1) {
      _currentStitch = 0;
    }
    _timer?.cancel();
    setState(() => _playing = true);
    _timer = Timer.periodic(const Duration(milliseconds: 35), (_) {
      if (!mounted || _vec == null) return;
      final step = _speedSteps[_speedIndex];
      final next = _currentStitch + step;
      if (next >= total) {
        setState(() {
          _currentStitch = total;
          _playing = false;
        });
        _timer?.cancel();
      } else {
        setState(() => _currentStitch = next);
      }
    });
  }

  void _pausePlayback() {
    _timer?.cancel();
    setState(() => _playing = false);
  }

  @override
  Widget build(BuildContext context) {
    final total = _vec?.stX.length ?? 0;
    final numFmt = intl.NumberFormat('#,###');
    final int curColorNum = _activeColorBlock + 1;
    final int totalColors = max(1, _colorStarts.length);

    return Scaffold(
      backgroundColor: const Color(0xFF0E131D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: Text(tr('محاكاة سير الغرز (3D)', 'Stitch Simulator (3D)'), style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 16)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFD4AF37)))
          : (_vec == null || total < 2)
              ? Center(child: Text(tr('لا يمكن محاكاة هذا الملف', 'Cannot simulate this file'), style: const TextStyle(color: Colors.white70)))
              : Column(
                  children: [
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ClipRect(
                          child: LayoutBuilder(
                            builder: (ctx, c) {
                              _simSize = Size(c.maxWidth, c.maxHeight);
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onDoubleTap: () => setState(() {
                                  if ((_simZoom - 1.0).abs() > 0.05 || _simPan.distance > 2.0) {
                                    _simZoom = 1.0;
                                    _simPan = Offset.zero;
                                  } else {
                                    _simZoom = 4.0;
                                  }
                                }),
                                onScaleStart: (d) {
                                  _simStartZoom = _simZoom;
                                  _simStartPan = _simPan;
                                  _simStartFocal = d.localFocalPoint;
                                },
                                onScaleUpdate: (d) {
                                  if (_simSize == Size.zero) return;
                                  final nextZ = (_simStartZoom * d.scale).clamp(0.6, 24.0);
                                  final ctr = Offset(_simSize.width * 0.5, _simSize.height * 0.5);
                                  final foc = _simStartFocal - ctr;
                                  final ratio = nextZ / _simStartZoom;
                                  setState(() {
                                    _simZoom = nextZ;
                                    _simPan = (_simStartPan - foc) * ratio + foc + (d.localFocalPoint - _simStartFocal);
                                  });
                                },
                                child: CustomPaint(
                                  painter: _VectorStitchPainter(
                                    data: _vec!,
                                    limit: _currentStitch,
                                    showNeedle: true,
                                    is3D: true,
                                    zoomFactor: _simZoom,
                                    panOffset: _simPan,
                                  ),
                                  size: Size.infinite,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.fromLTRB(14, 10, 14, MediaQuery.of(context).padding.bottom + 12),
                      decoration: const BoxDecoration(
                        color: Color(0xFF18202E),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '${tr('الغرزة', 'Stitch')}: ${numFmt.format(_currentStitch)} / ${numFmt.format(total)}',
                                style: const TextStyle(color: Color(0xFF56CCF2), fontWeight: FontWeight.bold, fontSize: 12.5),
                              ),
                              Text(
                                '${tr('اللون', 'Color')}: $curColorNum / $totalColors  •  ${((_currentStitch / max(1, total)) * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12.5),
                              ),
                            ],
                          ),
                          Slider(
                            value: _currentStitch.toDouble().clamp(0, total.toDouble()),
                            min: 0,
                            max: total.toDouble(),
                            activeColor: const Color(0xFFD4AF37),
                            inactiveColor: Colors.white24,
                            onChanged: (v) {
                              setState(() => _currentStitch = v.round());
                            },
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // ترجيع لون
                              IconButton(
                                onPressed: _jumpToPrevColor,
                                icon: const Icon(Icons.skip_previous, color: Color(0xFF56CCF2), size: 26),
                                tooltip: tr('اللون السابق', 'Prev Color'),
                              ),
                              // ستوب (إيقاف وإعادة للصفر)
                              IconButton(
                                onPressed: _stopPlayback,
                                icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent, size: 26),
                                tooltip: tr('ستوب', 'Stop'),
                              ),
                              // تشغيل / إيقاف مؤقت
                              ElevatedButton.icon(
                                onPressed: _playing ? _pausePlayback : _startPlayback,
                                icon: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 22),
                                label: Text(
                                  _playing ? tr('إيقاف', 'Pause') : tr('تشغيل', 'Play'),
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFD4AF37),
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                                ),
                              ),
                              // تقديم لون
                              IconButton(
                                onPressed: _jumpToNextColor,
                                icon: const Icon(Icons.skip_next, color: Color(0xFF56CCF2), size: 26),
                                tooltip: tr('اللون التالي', 'Next Color'),
                              ),
                              // التحكم بالسرعة
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.white10,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: _speedIndex > 0 ? () => setState(() => _speedIndex--) : null,
                                      icon: const Icon(Icons.remove, size: 16),
                                      color: const Color(0xFFD4AF37),
                                      disabledColor: Colors.white24,
                                      constraints: const BoxConstraints(minWidth: 30, minHeight: 34),
                                      padding: EdgeInsets.zero,
                                    ),
                                    Text(
                                      _speedLabels[_speedIndex],
                                      style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 11.5),
                                    ),
                                    IconButton(
                                      onPressed: _speedIndex < _speedSteps.length - 1 ? () => setState(() => _speedIndex++) : null,
                                      icon: const Icon(Icons.add, size: 16),
                                      color: const Color(0xFFD4AF37),
                                      disabledColor: Colors.white24,
                                      constraints: const BoxConstraints(minWidth: 30, minHeight: 34),
                                      padding: EdgeInsets.zero,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}

/// شبكة ويلكم 3×3 لتحديد نقطة البداية والنهاية (9 نقاط موصولة بخطوط تماماً مثل برنامج ويلكم)
class _WilcomStartPointGrid extends StatelessWidget {
  final int selectedAnchor; // 0=الأصلي، 1..9=نقاط الشبكة
  final ValueChanged<int> onChanged;

  const _WilcomStartPointGrid({
    required this.selectedAnchor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    const double gridSize = 104.0;
    const double pad = 16.0;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: gridSize,
        height: gridSize,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: _WilcomGridLinesPainter(pad: pad)),
            ),
            for (int row = 0; row < 3; row++)
              for (int col = 0; col < 3; col++)
                Positioned(
                  left: pad + col * ((gridSize - pad * 2) / 2.0) - 13.0,
                  top: pad + row * ((gridSize - pad * 2) / 2.0) - 13.0,
                  child: _buildNode(row * 3 + col + 1),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildNode(int idx) {
    final bool isSel = selectedAnchor == idx;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(idx),
      child: SizedBox(
        width: 26,
        height: 26,
        child: Center(
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: const Color(0xFF0E131D),
              shape: BoxShape.circle,
              border: Border.all(
                color: isSel ? const Color(0xFFD4AF37) : Colors.white70,
                width: isSel ? 2.2 : 1.5,
              ),
            ),
            child: isSel
                ? Center(
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFFD4AF37),
                        shape: BoxShape.circle,
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

class _WilcomGridLinesPainter extends CustomPainter {
  final double pad;
  _WilcomGridLinesPainter({required this.pad});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1.6;
    final double step = (size.width - pad * 2) / 2.0;
    for (int i = 0; i < 3; i++) {
      final double pos = pad + i * step;
      canvas.drawLine(Offset(pad, pos), Offset(size.width - pad, pos), paint);
      canvas.drawLine(Offset(pos, pad), Offset(pos, size.height - pad), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WilcomGridLinesPainter oldDelegate) => false;
}

/// شاشة تعديل الفلم الشاملة (طول×عرض، نقطة البداية والنهاية 9 نقاط مثل ويلكم، إطار درزة وبُعده، طول الدرزة Run، الكثافة، الفلترة، الدوران، القلب، حذف لون، قص غرز، وحفظ)
class DesignEditorScreen extends StatefulWidget {
  final EmbDesignInfo? design;
  final VectorDesignData? initialVector;
  final String defaultBaseName;
  const DesignEditorScreen({
    super.key,
    this.design,
    this.initialVector,
    this.defaultBaseName = 'tarik_edit',
  });
  @override
  State<DesignEditorScreen> createState() => _DesignEditorScreenState();
}

class _DesignEditorScreenState extends State<DesignEditorScreen> {
  VectorDesignData? _original;
  VectorDesignData? _edited;
  bool _loading = true;
  bool _saving = false;

  double _scaleX = 1.0;
  double _scaleY = 1.0;
  bool _lockAspect = true;
  final TextEditingController _widthCmCtrl = TextEditingController();
  final TextEditingController _heightCmCtrl = TextEditingController();

  // نقطة البداية والنهاية (شبكة ويلكم 3×3: 0=الأصلي، 1..9=الشبكة)
  int _startAnchor = 5; // المركز افتراضياً مثل ويلكم
  bool _returnToStart = true;

  // إطار الدرزة (Basting Frame) + التحكم بطول الدرزة Run (للإطار وتعديل الرسمات)
  bool _addBastingFrame = false;
  double _bastingMarginMm = 5.0;
  final TextEditingController _marginCtrl = TextEditingController(text: '5.0');
  bool _bastingSeparateColor = true;
  int _bastingColorArgb = 0xFF00BFA5;
  static const List<int> _bastingColors = [0xFF00BFA5, 0xFFFF1744, 0xFF007BFF, 0xFFFFB300, 0xFF00C853, 0xFFD500F9, 0xFF000000];
  double _runLengthMm = 4.0;
  final TextEditingController _runLenCtrl = TextEditingController(text: '4.0');
  bool _applyRunToDesign = false;

  double _densityMm = 0.50; // الكثافة الأساسية 0.50 مم
  final TextEditingController _densityCtrl = TextEditingController(text: '0.50');
  bool _filterEnabled = false;
  double _minStitchFilterMm = 0.30; // فلترة الفلم من 0.3 إلى 1.5 مم
  final TextEditingController _filterCtrl = TextEditingController(text: '0.30');
  int _filteredOutCount = 0;

  double _rotationDeg = 0.0;
  bool _flipH = false;
  bool _flipV = false;
  final Set<int> _deletedColors = {};
  List<int> _availableColors = [];
  int _trimStart = 0;
  int _trimEnd = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _widthCmCtrl.dispose();
    _heightCmCtrl.dispose();
    _marginCtrl.dispose();
    _runLenCtrl.dispose();
    _densityCtrl.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  String _anchorLabel(int anchor) {
    switch (anchor) {
      case 1: return tr('أعلى يسار', 'Top Left');
      case 2: return tr('أعلى وسط', 'Top Center');
      case 3: return tr('أعلى يمين', 'Top Right');
      case 4: return tr('وسط يسار', 'Mid Left');
      case 5: return tr('المركز', 'Center');
      case 6: return tr('وسط يمين', 'Mid Right');
      case 7: return tr('أسفل يسار', 'Bottom Left');
      case 8: return tr('أسفل وسط', 'Bottom Center');
      case 9: return tr('أسفل يمين', 'Bottom Right');
      default: return tr('الأصلي', 'Original');
    }
  }

  void _syncDimInputs(VectorDesignData? v) {
    if (v == null) return;
    final wCm = (v.widthMm ?? 0.0) / 10.0;
    final hCm = (v.heightMm ?? 0.0) / 10.0;
    if (wCm > 0) _widthCmCtrl.text = wCm.toStringAsFixed(1);
    if (hCm > 0) _heightCmCtrl.text = hCm.toStringAsFixed(1);
  }

  Future<void> _load() async {
    final v = widget.initialVector ?? (widget.design != null ? await loadAnyVectorDesign(widget.design!.filePath) : null);
    if (v != null && (v.seqX.isNotEmpty || v.beadX.isNotEmpty)) { await TarikProPbrSprites.ensureLoaded(); }
    if (!mounted) return;
    if (v != null) {
      final Set<int> cols = {};
      for (int i = 0; i < v.stColor.length; i++) {
        cols.add(v.stColor[i]);
      }
      final sortedCols = cols.toList()..sort();
      setState(() {
        _original = v;
        _availableColors = sortedCols;
        _trimStart = 0;
        _trimEnd = v.stX.length;
        _loading = false;
      });
      _rebuildEdited(syncDims: true);
    } else {
      setState(() => _loading = false);
    }
  }

  void _applyNumericWidth(String txt) {
    if (_original == null) return;
    final double? targetW = double.tryParse(txt.trim().replaceAll(',', '.'));
    final double baseW = (_original!.widthMm ?? 0.0) / 10.0;
    if (targetW == null || targetW < 0.2 || targetW > 500.0 || baseW <= 0.05) return;
    _scaleX = (targetW / baseW).clamp(0.05, 25.0);
    if (_lockAspect) _scaleY = _scaleX;
    _rebuildEdited(syncDims: true);
  }

  void _applyNumericHeight(String txt) {
    if (_original == null) return;
    final double? targetH = double.tryParse(txt.trim().replaceAll(',', '.'));
    final double baseH = (_original!.heightMm ?? 0.0) / 10.0;
    if (targetH == null || targetH < 0.2 || targetH > 500.0 || baseH <= 0.05) return;
    _scaleY = (targetH / baseH).clamp(0.05, 25.0);
    if (_lockAspect) _scaleX = _scaleY;
    _rebuildEdited(syncDims: true);
  }

  void _setMarginMm(double val, {bool syncText = true}) {
    final clamped = val.clamp(0.0, 30.0);
    _bastingMarginMm = double.parse(clamped.toStringAsFixed(1));
    if (syncText) _marginCtrl.text = _bastingMarginMm.toStringAsFixed(1);
    _rebuildEdited(syncDims: true);
  }

  void _setRunLenMm(double val, {bool syncText = true}) {
    final clamped = val.clamp(1.0, 10.0);
    _runLengthMm = double.parse(clamped.toStringAsFixed(1));
    if (syncText) _runLenCtrl.text = _runLengthMm.toStringAsFixed(1);
    _rebuildEdited();
  }

  void _setDensityMm(double val, {bool syncText = true}) {
    final clamped = val.clamp(0.25, 1.00);
    _densityMm = double.parse(clamped.toStringAsFixed(2));
    if (syncText) {
      _densityCtrl.text = _densityMm.toStringAsFixed(2);
    }
    _rebuildEdited();
  }

  void _setFilterMm(double val, {bool syncText = true}) {
    final clamped = val.clamp(0.30, 1.50);
    _minStitchFilterMm = double.parse(clamped.toStringAsFixed(2));
    if (syncText) {
      _filterCtrl.text = _minStitchFilterMm.toStringAsFixed(2);
    }
    _rebuildEdited();
  }

  void _rebuildEdited({bool syncDims = false}) {
    if (_original == null) return;
    final double factor = (0.50 / _densityMm).clamp(0.45, 2.0);
    final withoutFilter = VectorDesignEditor.transform(
      _original!,
      scaleX: _scaleX,
      scaleY: _scaleY,
      rotationDeg: _rotationDeg,
      flipH: _flipH,
      flipV: _flipV,
      deletedColors: _deletedColors,
      trimStart: _trimStart,
      trimEnd: _trimEnd,
      densityFactor: factor,
      minStitchFilterMm: 0.0,
      runStitchLengthMm: _runLengthMm,
      applyRunLengthToDesign: _applyRunToDesign,
      addBastingFrame: _addBastingFrame,
      bastingMarginMm: _bastingMarginMm,
      bastingSeparateColor: _bastingSeparateColor,
      startAnchor: _startAnchor,
      returnToStart: _returnToStart,
    );
    final VectorDesignData next;
    int removed = 0;
    if (_filterEnabled) {
      next = VectorDesignEditor.transform(
        _original!,
        scaleX: _scaleX,
        scaleY: _scaleY,
        rotationDeg: _rotationDeg,
        flipH: _flipH,
        flipV: _flipV,
        deletedColors: _deletedColors,
        trimStart: _trimStart,
        trimEnd: _trimEnd,
        densityFactor: factor,
        minStitchFilterMm: _minStitchFilterMm,
        runStitchLengthMm: _runLengthMm,
        applyRunLengthToDesign: _applyRunToDesign,
        addBastingFrame: _addBastingFrame,
        bastingMarginMm: _bastingMarginMm,
        bastingSeparateColor: _bastingSeparateColor,
        startAnchor: _startAnchor,
        returnToStart: _returnToStart,
      );
      removed = max(0, withoutFilter.stitches - next.stitches);
    } else {
      next = withoutFilter;
    }
    VectorDesignData finalVec = next;
    if (_addBastingFrame && finalVec.stColor.isNotEmpty && finalVec.paletteArgb.isNotEmpty) {
      final palCopy = Int32List.fromList(finalVec.paletteArgb);
      final int frameColIdx = finalVec.stColor[0] % palCopy.length;
      palCopy[frameColIdx] = _bastingColorArgb;
      finalVec = VectorDesignData(
        stX: finalVec.stX,
        stY: finalVec.stY,
        stMove: finalVec.stMove,
        stColor: finalVec.stColor,
        stDev: finalVec.stDev,
        seqX: finalVec.seqX,
        seqY: finalVec.seqY,
        seqCode: finalVec.seqCode,
        beadX: finalVec.beadX,
        beadY: finalVec.beadY,
        beadCode: finalVec.beadCode,
        paletteArgb: palCopy,
        stitches: finalVec.stitches,
        colorCount: finalVec.colorCount,
        stopsCount: finalVec.stopsCount,
        jumpsCount: finalVec.jumpsCount,
        sequinsCount: finalVec.sequinsCount,
        beadsCount: finalVec.beadsCount,
        trimsCount: finalVec.trimsCount,
        minX: finalVec.minX,
        maxX: finalVec.maxX,
        minY: finalVec.minY,
        maxY: finalVec.maxY,
        hasBounds: finalVec.hasBounds,
        machineType: finalVec.machineType,
      );
    }
    setState(() {
      _edited = finalVec;
      _filteredOutCount = removed;
    });
    if (syncDims) _syncDimInputs(next);
  }

  Future<void> _saveEdited() async {
    if (_edited == null || _saving) return;
    String targetExt = 'DST';
    String baseName = widget.defaultBaseName;
    String outDir = '/storage/emulated/0/Download';

    if (widget.design != null) {
      final origExt = widget.design!.filePath.split('.').last.toUpperCase();
      if (UniversalExporter.supportedFormats.any((f) => f['ext'] == origExt)) {
        targetExt = origExt;
      }
      baseName = '${widget.design!.fileName.replaceAll(RegExp(r'\.[^.]+$'), '')}_edit';
      outDir = File(widget.design!.filePath).parent.path;
    } else {
      baseName = '${widget.defaultBaseName}_${DateTime.now().millisecondsSinceEpoch}';
    }

    setState(() => _saving = true);
    try {
      String outPath = joinCleanPath(outDir, '$baseName.$targetExt');
      String? res = await TarikProDstEncoder.exportToFile(_edited!, outPath, targetExt, baseName: baseName);
      res ??= await TarikProDstEncoder.exportToFile(
        _edited!,
        '/storage/emulated/0/Download/$baseName.$targetExt',
        targetExt,
        baseName: baseName,
      );
      if (res != null && await File(res).exists()) {
        await DesignCacheManager.invalidate(res);
        await DesignCacheManager.getOrParse(res);
        notifyDesignFilesChanged(res);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${tr('تم حفظ التصميم المعدّل:', 'Edited design saved:')}\n$res'),
              backgroundColor: const Color(0xFF2E7D32),
            ),
          );
          Navigator.of(context).pop(res);
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('تعذر حفظ التصميم المعدّل', 'Failed to save edited design'))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _original?.stX.length ?? 0;
    final int densityPct = ((0.50 / _densityMm) * 100).round();
    final numFmt = intl.NumberFormat('#,###');

    return Scaffold(
      backgroundColor: const Color(0xFF0E131D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: Text(tr('تعديل الفلم', 'Edit Design'), style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 16)),
        actions: [
          if (_edited != null) ...[
            IconButton(
              icon: const Icon(Icons.play_circle_outline, color: Color(0xFFD4AF37), size: 21),
              tooltip: tr('محاكاة الغرز', 'Simulate'),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => StitchSimulatorScreen(initialVector: _edited)),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.select_all, color: Color(0xFF56CCF2), size: 21),
              tooltip: tr('تحديد عنصر', 'Select Element'),
              onPressed: () async {
                final resPath = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ObjectEditorScreen(
                      design: widget.design,
                      initialVector: _edited,
                      defaultBaseName: widget.defaultBaseName,
                    ),
                  ),
                );
                if (resPath != null && resPath.isNotEmpty && mounted) {
                  Navigator.of(context).pop(resPath);
                }
              },
            ),
          ],
          TextButton.icon(
            onPressed: _saving || _edited == null ? null : _saveEdited,
            icon: _saving
                ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD4AF37)))
                : const Icon(Icons.save, color: Color(0xFFD4AF37), size: 19),
            label: Text(tr('حفظ', 'Save'), style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFD4AF37)))
          : (_edited == null || total < 2)
              ? Center(child: Text(tr('تعذر تحميل التصميم للتعديل', 'Cannot edit this file'), style: const TextStyle(color: Colors.white70)))
              : Column(
                  children: [
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          children: [
                            InteractiveViewer(
                              minScale: 0.8,
                              maxScale: 8.0,
                              child: CustomPaint(
                                painter: _VectorStitchPainter(
                                  data: _edited!,
                                  limit: _edited!.stX.length,
                                  showNeedle: false,
                                  is3D: true,
                                  showOriginCrosshair: _startAnchor >= 1 && _startAnchor <= 9,
                                  showCmGrid: true,
                                ),
                                size: Size.infinite,
                              ),
                            ),
                            Positioned(
                              top: 8,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0E131D).withOpacity(0.84),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.55)),
                                ),
                                child: Text(
                                  '⊕ ${_anchorLabel(_startAnchor)}${_addBastingFrame ? ' • ${tr('إطار', 'Frame')} ${_bastingMarginMm.toStringAsFixed(0)}${tr('مم', 'mm')}' : ''}',
                                  style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.52),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                        decoration: const BoxDecoration(
                          color: Color(0xFF18202E),
                          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 1) جدول التكبير (العرض × الطول بالسم بالأرقام + قفل التناسب + شريط السحب)
                              Container(
                                padding: const EdgeInsets.all(10),
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: Colors.black26,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          '${tr('مقاس الفلم (سم)', 'Size (cm)')}  ${(_scaleX * 100).round()}%',
                                          style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 12),
                                        ),
                                        Text(
                                          '${tr('الغرز', 'Stitches')}: ${numFmt.format(_edited!.stitches)}',
                                          style: const TextStyle(color: Color(0xFF56CCF2), fontWeight: FontWeight.bold, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: _widthCmCtrl,
                                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                            decoration: InputDecoration(
                                              labelText: tr('العرض (سم)', 'Width (cm)'),
                                              labelStyle: const TextStyle(color: Colors.white60, fontSize: 11),
                                              isDense: true,
                                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                              filled: true,
                                              fillColor: const Color(0xFF0E131D),
                                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                                            ),
                                            onSubmitted: _applyNumericWidth,
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 6),
                                          child: IconButton(
                                            visualDensity: VisualDensity.compact,
                                            onPressed: () => setState(() => _lockAspect = !_lockAspect),
                                            icon: Icon(
                                              _lockAspect ? Icons.link : Icons.link_off,
                                              color: _lockAspect ? const Color(0xFFD4AF37) : Colors.white38,
                                            ),
                                            tooltip: tr('قفل التناسب', 'Lock Ratio'),
                                          ),
                                        ),
                                        Expanded(
                                          child: TextField(
                                            controller: _heightCmCtrl,
                                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                            decoration: InputDecoration(
                                              labelText: tr('الطول (سم)', 'Height (cm)'),
                                              labelStyle: const TextStyle(color: Colors.white60, fontSize: 11),
                                              isDense: true,
                                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                              filled: true,
                                              fillColor: const Color(0xFF0E131D),
                                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                                            ),
                                            onSubmitted: _applyNumericHeight,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        ElevatedButton(
                                          onPressed: () {
                                            FocusScope.of(context).unfocus();
                                            final curW = ((_edited?.widthMm ?? 0) / 10.0).toStringAsFixed(1);
                                            final curH = ((_edited?.heightMm ?? 0) / 10.0).toStringAsFixed(1);
                                            if (_widthCmCtrl.text.trim() != curW) {
                                              _applyNumericWidth(_widthCmCtrl.text);
                                            }
                                            if (!_lockAspect || _heightCmCtrl.text.trim() != curH) {
                                              if (!_lockAspect || _widthCmCtrl.text.trim() == curW) {
                                                _applyNumericHeight(_heightCmCtrl.text);
                                              }
                                            }
                                          },
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(0xFFD4AF37),
                                            foregroundColor: Colors.black,
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                            minimumSize: Size.zero,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                          ),
                                          child: const Icon(Icons.check, size: 18),
                                        ),
                                      ],
                                    ),
                                    Slider(
                                      value: _scaleX.clamp(0.4, 2.5),
                                      min: 0.4,
                                      max: 2.5,
                                      divisions: 42,
                                      activeColor: const Color(0xFFD4AF37),
                                      onChanged: (v) {
                                        final ratio = _scaleX > 0.01 ? (_scaleY / _scaleX) : 1.0;
                                        _scaleX = v;
                                        _scaleY = _lockAspect ? v : (v * ratio).clamp(0.2, 4.0);
                                        _rebuildEdited(syncDims: true);
                                      },
                                    ),
                                  ],
                                ),
                              ),

                              // 2) نقطة البداية والنهاية (شبكة ويلكم 3×3 ذات الـ 9 نقاط)
                              Container(
                                padding: const EdgeInsets.all(10),
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: Colors.black26,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: _startAnchor != 0 ? const Color(0xFFD4AF37).withOpacity(0.5) : Colors.white12,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    _WilcomStartPointGrid(
                                      selectedAnchor: _startAnchor,
                                      onChanged: (idx) {
                                        _startAnchor = idx;
                                        _rebuildEdited();
                                      },
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            tr('نقطة البداية والنهاية', 'Auto Start & End'),
                                            style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${tr('المكان المختار:', 'Selected:')} ${_anchorLabel(_startAnchor)}',
                                            style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 12),
                                          ),
                                          const SizedBox(height: 6),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  tr('العودة للبداية في النهاية', 'Return End to Start'),
                                                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                                                ),
                                              ),
                                              Switch(
                                                value: _returnToStart,
                                                activeColor: const Color(0xFFD4AF37),
                                                onChanged: _startAnchor == 0
                                                    ? null
                                                    : (v) {
                                                        _returnToStart = v;
                                                        _rebuildEdited();
                                                      },
                                              ),
                                            ],
                                          ),
                                          Align(
                                            alignment: AlignmentDirectional.centerStart,
                                            child: OutlinedButton(
                                              onPressed: () {
                                                _startAnchor = _startAnchor == 0 ? 5 : 0;
                                                _rebuildEdited();
                                              },
                                              style: OutlinedButton.styleFrom(
                                                side: const BorderSide(color: Colors.white24),
                                                visualDensity: VisualDensity.compact,
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                              ),
                                              child: Text(
                                                _startAnchor == 0
                                                    ? tr('تفعيل المركز', 'Use Center')
                                                    : tr('إرجاع للأصلي', 'Reset Original'),
                                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // 3) إطار الدرزة (Basting Box) + التحكم ببُعده + التحكم بطول الدرزة Run (للإطار وللرسمات)
                              Container(
                                padding: const EdgeInsets.all(10),
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: Colors.black26,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: (_addBastingFrame || _applyRunToDesign) ? Colors.tealAccent.withOpacity(0.55) : Colors.white12,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                tr('إطار درزة حول التصميم (Basting)', 'Basting Run Frame'),
                                                style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 12),
                                              ),
                                              Text(
                                                _addBastingFrame
                                                    ? '${tr('مفعّل — البُعد', 'Active — Margin')}: ${_bastingMarginMm.toStringAsFixed(1)} ${tr('مم', 'mm')}'
                                                    : tr('إضافة أو إلغاء إطار درزة لتثبيت القماش', 'Add or remove running basting frame'),
                                                style: const TextStyle(color: Colors.white60, fontSize: 10),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Switch(
                                          value: _addBastingFrame,
                                          activeColor: Colors.tealAccent,
                                          onChanged: (v) {
                                            _addBastingFrame = v;
                                            _rebuildEdited(syncDims: true);
                                          },
                                        ),
                                      ],
                                    ),
                                    if (_addBastingFrame) ...[
                                      const SizedBox(height: 4),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            tr('بُعد الإطار عن التصميم (مم)', 'Frame Margin (mm)'),
                                            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                                          ),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(tr('لون مستقل', 'Separate Color'), style: const TextStyle(color: Colors.white60, fontSize: 10)),
                                              Checkbox(
                                                value: _bastingSeparateColor,
                                                activeColor: Colors.tealAccent,
                                                checkColor: Colors.black,
                                                visualDensity: VisualDensity.compact,
                                                onChanged: (v) {
                                                  _bastingSeparateColor = v ?? true;
                                                  _rebuildEdited();
                                                },
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                      Row(
                                        children: [
                                          IconButton(
                                            visualDensity: VisualDensity.compact,
                                            onPressed: () => _setMarginMm(_bastingMarginMm - 1.0),
                                            icon: const Icon(Icons.remove_circle_outline, color: Colors.tealAccent),
                                          ),
                                          SizedBox(
                                            width: 62,
                                            child: TextField(
                                              controller: _marginCtrl,
                                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                              decoration: InputDecoration(
                                                isDense: true,
                                                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                                filled: true,
                                                fillColor: const Color(0xFF0E131D),
                                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                                              ),
                                              onSubmitted: (txt) {
                                                final v = double.tryParse(txt.trim().replaceAll(',', '.'));
                                                if (v != null) _setMarginMm(v, syncText: true);
                                              },
                                            ),
                                          ),
                                          IconButton(
                                            visualDensity: VisualDensity.compact,
                                            onPressed: () => _setMarginMm(_bastingMarginMm + 1.0),
                                            icon: const Icon(Icons.add_circle_outline, color: Colors.tealAccent),
                                          ),
                                          Expanded(
                                            child: Slider(
                                              value: _bastingMarginMm.clamp(0.0, 30.0),
                                              min: 0.0,
                                              max: 30.0,
                                              divisions: 30,
                                              activeColor: Colors.tealAccent,
                                              onChanged: (v) => _setMarginMm(v),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            tr('لون إطار الدرزة:', 'Frame Color:'),
                                            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                                          ),
                                          Row(
                                            children: _bastingColors.map((argb) {
                                              final bool sel = _bastingColorArgb == argb;
                                              return GestureDetector(
                                                onTap: () {
                                                  _bastingColorArgb = argb;
                                                  _rebuildEdited();
                                                },
                                                child: Container(
                                                  margin: const EdgeInsets.symmetric(horizontal: 3),
                                                  width: 22,
                                                  height: 22,
                                                  decoration: BoxDecoration(
                                                    color: Color(argb),
                                                    shape: BoxShape.circle,
                                                    border: Border.all(
                                                      color: sel ? const Color(0xFFD4AF37) : Colors.white38,
                                                      width: sel ? 2.4 : 1.0,
                                                    ),
                                                  ),
                                                ),
                                              );
                                            }).toList(),
                                          ),
                                        ],
                                      ),
                                    ],
                                    const Divider(color: Colors.white12, height: 14),
                                    // التحكم بطول الدرزة Run (يشمل الإطار + تعديل درزات الرسمة)
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          '${tr('طول الدرزة (Run)', 'Run Stitch Length')}: ${_runLengthMm.toStringAsFixed(1)} ${tr('مم', 'mm')}',
                                          style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          onPressed: () => _setRunLenMm(_runLengthMm - 0.5),
                                          icon: const Icon(Icons.remove_circle_outline, color: Color(0xFFD4AF37)),
                                        ),
                                        SizedBox(
                                          width: 62,
                                          child: TextField(
                                            controller: _runLenCtrl,
                                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                            decoration: InputDecoration(
                                              isDense: true,
                                              contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                              filled: true,
                                              fillColor: const Color(0xFF0E131D),
                                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                                            ),
                                            onSubmitted: (txt) {
                                              final v = double.tryParse(txt.trim().replaceAll(',', '.'));
                                              if (v != null) _setRunLenMm(v, syncText: true);
                                            },
                                          ),
                                        ),
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          onPressed: () => _setRunLenMm(_runLengthMm + 0.5),
                                          icon: const Icon(Icons.add_circle_outline, color: Color(0xFFD4AF37)),
                                        ),
                                        Expanded(
                                          child: Slider(
                                            value: _runLengthMm.clamp(1.0, 10.0),
                                            min: 1.0,
                                            max: 10.0,
                                            divisions: 18,
                                            activeColor: const Color(0xFFD4AF37),
                                            onChanged: (v) => _setRunLenMm(v),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            tr('تطبيق طول الدرزة على درزات الرسمة أيضاً (مع حماية الفستون والزوايا)', 'Apply Run length to design Run stitches too (protects Satin & corners)'),
                                            style: const TextStyle(color: Colors.white70, fontSize: 10.5),
                                          ),
                                        ),
                                        Switch(
                                          value: _applyRunToDesign,
                                          activeColor: const Color(0xFFD4AF37),
                                          onChanged: (v) {
                                            _applyRunToDesign = v;
                                            _rebuildEdited();
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),

                              // 4) نسبة الكثافة بالأرقام (الأساسية 0.50)
                              Container(
                                padding: const EdgeInsets.all(10),
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: Colors.black26,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${tr('الكثافة (الأساسية 0.50)', 'Density (Base 0.50)')}: $densityPct%',
                                            style: const TextStyle(color: Color(0xFF56CCF2), fontWeight: FontWeight.bold, fontSize: 12),
                                          ),
                                        ),
                                        Text(
                                          _densityMm < 0.49
                                              ? tr('تكثيف', 'Denser')
                                              : (_densityMm > 0.51 ? tr('تخفيف', 'Lighter') : tr('أصلي', 'Original')),
                                          style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 11),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          onPressed: () => _setDensityMm(_densityMm - 0.05),
                                          icon: const Icon(Icons.remove_circle_outline, color: Color(0xFF56CCF2)),
                                          tooltip: tr('تكثيف (-0.05)', 'Denser (-0.05)'),
                                        ),
                                        SizedBox(
                                          width: 68,
                                          child: TextField(
                                            controller: _densityCtrl,
                                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                            decoration: InputDecoration(
                                              isDense: true,
                                              contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                              filled: true,
                                              fillColor: const Color(0xFF0E131D),
                                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                                            ),
                                            onSubmitted: (txt) {
                                              final v = double.tryParse(txt.trim().replaceAll(',', '.'));
                                              if (v != null) _setDensityMm(v, syncText: true);
                                            },
                                          ),
                                        ),
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          onPressed: () => _setDensityMm(_densityMm + 0.05),
                                          icon: const Icon(Icons.add_circle_outline, color: Color(0xFF56CCF2)),
                                          tooltip: tr('تخفيف (+0.05)', 'Lighter (+0.05)'),
                                        ),
                                        Expanded(
                                          child: Slider(
                                            value: _densityMm.clamp(0.25, 1.00),
                                            min: 0.25,
                                            max: 1.00,
                                            divisions: 15,
                                            activeColor: const Color(0xFF56CCF2),
                                            onChanged: (v) => _setDensityMm(v),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),

                              // 5) فلترة الفلم (0.3 إلى 1.5 مم مع حماية غرز الزوايا)
                              Container(
                                padding: const EdgeInsets.all(10),
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: Colors.black26,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: _filterEnabled ? Colors.greenAccent.withOpacity(0.5) : Colors.white12,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                tr('فلترة الغرز القصيرة (0.3 - 1.5 مم)', 'Small-Stitch Filter (0.3 - 1.5 mm)'),
                                                style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 12),
                                              ),
                                              Text(
                                                _filterEnabled
                                                    ? '${tr('تمت فلترة', 'Filtered')} ${numFmt.format(_filteredOutCount)} ${tr('غرزة (مع حماية الزوايا)', 'st (corners protected)')}'
                                                    : tr('مع الحفاظ على غرز الزوايا دون تشويه', 'Preserves sharp corners automatically'),
                                                style: const TextStyle(color: Colors.white60, fontSize: 10),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Switch(
                                          value: _filterEnabled,
                                          activeColor: Colors.greenAccent,
                                          onChanged: (v) {
                                            _filterEnabled = v;
                                            _rebuildEdited();
                                          },
                                        ),
                                      ],
                                    ),
                                    if (_filterEnabled)
                                      Row(
                                        children: [
                                          IconButton(
                                            visualDensity: VisualDensity.compact,
                                            onPressed: () => _setFilterMm(_minStitchFilterMm - 0.10),
                                            icon: const Icon(Icons.remove_circle_outline, color: Colors.greenAccent),
                                          ),
                                          SizedBox(
                                            width: 68,
                                            child: TextField(
                                              controller: _filterCtrl,
                                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                              decoration: InputDecoration(
                                                isDense: true,
                                                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                                filled: true,
                                                fillColor: const Color(0xFF0E131D),
                                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                                              ),
                                              onSubmitted: (txt) {
                                                final v = double.tryParse(txt.trim().replaceAll(',', '.'));
                                                if (v != null) _setFilterMm(v, syncText: true);
                                              },
                                            ),
                                          ),
                                          IconButton(
                                            visualDensity: VisualDensity.compact,
                                            onPressed: () => _setFilterMm(_minStitchFilterMm + 0.10),
                                            icon: const Icon(Icons.add_circle_outline, color: Colors.greenAccent),
                                          ),
                                          Expanded(
                                            child: Slider(
                                              value: _minStitchFilterMm.clamp(0.30, 1.50),
                                              min: 0.30,
                                              max: 1.50,
                                              divisions: 12,
                                              activeColor: Colors.greenAccent,
                                              onChanged: (v) => _setFilterMm(v),
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ),

                              // 6) الدوران
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    '${tr('الدوران', 'Rotation')}: ${_rotationDeg.round()}°',
                                    style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [0, 90, 180, 270].map((deg) {
                                      final bool sel = _rotationDeg.round() == deg;
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 2),
                                        child: InkWell(
                                          onTap: () {
                                            _rotationDeg = deg.toDouble();
                                            _rebuildEdited(syncDims: true);
                                          },
                                          borderRadius: BorderRadius.circular(8),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: sel ? const Color(0xFFD4AF37) : Colors.white10,
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              '$deg°',
                                              style: TextStyle(
                                                color: sel ? Colors.black : Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ],
                              ),
                              Slider(
                                value: _rotationDeg.clamp(0.0, 360.0),
                                min: 0.0,
                                max: 360.0,
                                divisions: 360,
                                activeColor: const Color(0xFFD4AF37),
                                onChanged: (v) {
                                  _rotationDeg = v;
                                  _rebuildEdited(syncDims: true);
                                },
                              ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () {
                                      _flipH = !_flipH;
                                      _rebuildEdited();
                                    },
                                    icon: Icon(Icons.flip, size: 17, color: _flipH ? const Color(0xFFD4AF37) : Colors.white70),
                                    label: Text(tr('قلب أفقي', 'Flip H'), style: const TextStyle(color: Colors.white, fontSize: 12)),
                                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24)),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () {
                                      _flipV = !_flipV;
                                      _rebuildEdited();
                                    },
                                    icon: Icon(Icons.swap_vert, size: 17, color: _flipV ? const Color(0xFFD4AF37) : Colors.white70),
                                    label: Text(tr('قلب عمودي', 'Flip V'), style: const TextStyle(color: Colors.white, fontSize: 12)),
                                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24)),
                                  ),
                                ],
                              ),
                              if (_availableColors.length > 1) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(
                                    tr('اضغط على أي لون لحذفه أو إرجاعه:', 'Tap any color to delete/restore:'),
                                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                SizedBox(
                                  height: 32,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: _availableColors.length,
                                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                                    itemBuilder: (_, idx) {
                                      final cIdx = _availableColors[idx];
                                      final isDeleted = _deletedColors.contains(cIdx);
                                      final col = Color(_original!.paletteArgb[cIdx % _original!.paletteArgb.length]);
                                      return GestureDetector(
                                        onTap: () {
                                          if (isDeleted) {
                                            _deletedColors.remove(cIdx);
                                          } else if (_availableColors.length - _deletedColors.length > 1) {
                                            _deletedColors.add(cIdx);
                                          }
                                          _rebuildEdited(syncDims: true);
                                        },
                                        child: Container(
                                          width: 32,
                                          height: 32,
                                          decoration: BoxDecoration(
                                            color: isDeleted ? Colors.black38 : col,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: isDeleted ? Colors.redAccent : Colors.white,
                                              width: 2,
                                            ),
                                          ),
                                          child: isDeleted ? const Icon(Icons.close, size: 16, color: Colors.redAccent) : null,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(tr('قص الغرز (بداية / نهاية):', 'Trim Stitches (Start / End):'), style: const TextStyle(color: Colors.white70, fontSize: 11)),
                                  Text('$_trimStart - $_trimEnd', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                                ],
                              ),
                              RangeSlider(
                                values: RangeValues(_trimStart.toDouble(), _trimEnd.toDouble()),
                                min: 0,
                                max: total.toDouble(),
                                activeColor: const Color(0xFF56CCF2),
                                onChanged: (rv) {
                                  if (rv.end - rv.start >= 2) {
                                    _trimStart = rv.start.round();
                                    _trimEnd = rv.end.round();
                                    _rebuildEdited(syncDims: true);
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _VectorStitchPainter extends CustomPainter {
  final VectorDesignData data;
  final int limit;
  final bool showNeedle;
  final bool is3D;
  final bool showOriginCrosshair;
  final bool showCmGrid;
  final double zoomFactor;
  final Offset panOffset;

  _VectorStitchPainter({
    required this.data,
    required this.limit,
    required this.showNeedle,
    this.is3D = true,
    this.showOriginCrosshair = false,
    this.showCmGrid = false,
    this.zoomFactor = 1.0,
    this.panOffset = Offset.zero,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!data.hasBounds || data.stX.length < 2) return;
    final double rawW = data.maxX - data.minX;
    final double rawH = data.maxY - data.minY;
    if (rawW <= 0 || rawH <= 0) return;

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    const double pad = 22.0;
    final double baseScale = min((size.width - pad * 2) / rawW, (size.height - pad * 2) / rawH);
    final double scale = baseScale * zoomFactor;
    final double baseOffX = (size.width - rawW * baseScale) * 0.5 - data.minX * baseScale;
    final double baseOffY = (size.height - rawH * baseScale) * 0.5 - data.minY * baseScale;
    final double cx = size.width * 0.5;
    final double cy = size.height * 0.5;
    final double offX = (baseOffX - cx) * zoomFactor + cx + panOffset.dx;
    final double offY = (baseOffY - cy) * zoomFactor + cy + panOffset.dy;

    if (showCmGrid) {
      TarikUnifiedCanvasRenderer.drawCmGrid(
        canvas,
        size,
        scale: scale,
        originX: offX,
        originY: offY,
      );
    }

    final int count = limit.clamp(0, data.stX.length);
    TarikUnifiedCanvasRenderer.paintDesign(
      canvas: canvas,
      data: data,
      scale: scale,
      offX: offX,
      offY: offY,
      is3D: is3D,
      decorTheme: 0,
      stitchLimit: count,
      visibleRect: Offset.zero & size,
      stroke2DPx: TarikRenderSpecs.stroke2DScreenPx,
    );

    if (showOriginCrosshair) {
      final double ox = offX;
      final double oy = offY;
      const double arm = 12.0;
      canvas.drawCircle(Offset(ox, oy), 9.0, Paint()..color = Colors.white.withOpacity(0.85));
      canvas.drawCircle(
        Offset(ox, oy),
        8.0,
        Paint()
          ..color = const Color(0xFF00C853)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
      final crossBg = Paint()
        ..color = Colors.white
        ..strokeWidth = 3.6
        ..strokeCap = StrokeCap.round;
      final crossFg = Paint()
        ..color = const Color(0xFFD50000)
        ..strokeWidth = 1.9
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(ox - arm, oy), Offset(ox + arm, oy), crossBg);
      canvas.drawLine(Offset(ox, oy - arm), Offset(ox, oy + arm), crossBg);
      canvas.drawLine(Offset(ox - arm, oy), Offset(ox + arm, oy), crossFg);
      canvas.drawLine(Offset(ox, oy - arm), Offset(ox, oy + arm), crossFg);
    }

    if (showNeedle && count > 0) {
      final double lastX = data.stX[count - 1] * scale + offX;
      final double lastY = data.stY[count - 1] * scale + offY;
      const double arm = 9.0;
      final crossShadow = Paint()
        ..color = Colors.black.withOpacity(0.45)
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round;
      final crossPaint = Paint()
        ..color = Colors.redAccent
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(lastX - arm, lastY), Offset(lastX + arm, lastY), crossShadow);
      canvas.drawLine(Offset(lastX, lastY - arm), Offset(lastX, lastY + arm), crossShadow);
      canvas.drawLine(Offset(lastX - arm, lastY), Offset(lastX + arm, lastY), crossPaint);
      canvas.drawLine(Offset(lastX, lastY - arm), Offset(lastX, lastY + arm), crossPaint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _VectorStitchPainter oldDelegate) {
    return oldDelegate.limit != limit ||
        oldDelegate.data != data ||
        oldDelegate.is3D != is3D ||
        oldDelegate.showOriginCrosshair != showOriginCrosshair ||
        oldDelegate.showCmGrid != showCmGrid ||
        oldDelegate.zoomFactor != zoomFactor ||
        oldDelegate.panOffset != panOffset;
  }
}


/// شاشة الكتابة والتطريز المبسّطة: 5 فونطات عربي (A1–A5) + 5 فونطات إنجليزي (E1–E5) بدون أسماء + جدول طول وعرض بالأرقام + Auto-Branching بدون جنبات

enum _LetteringHandle {
  none,
  pan,
  resizeTL,
  resizeTR,
  resizeBR,
  resizeBL,
  rotate,
  curve,
}

/// لوحة الكتابة التفاعلية بمقياس سنتيمتر حقيقي (1 سم × 1 سم):
/// - الشبكة تتحرك وتتكبر مع النص تماماً عند التقريب بإصبعين أو التحريك
/// - عند تغيير عرض النص (من الشريط أو بسحب مقابض الزوايا) يظهر تكبير وتصغير الحروف فعلياً على الشبكة
/// - مقابض تفاعلية فوق الغرز تعمل 100% مثل الفوتوشوب وويلكم: 4 زوايا للتكبير، مقبض علوي للدوران، ومقبض أخضر للقوس/الدائرة/الموجة
class _InteractiveLetteringCanvas extends StatefulWidget {
  final VectorDesignData vec;
  final double widthCm;
  final double rotationDeg;
  final String pathMode;
  final double pathParam;
  final bool is3D;
  final ValueChanged<double> onWidthCmDrag;
  final ValueChanged<double> onRotationDrag;
  final ValueChanged<double> onPathParamDrag;
  final VoidCallback onInteractionEnd;

  const _InteractiveLetteringCanvas({
    required this.vec,
    required this.widthCm,
    required this.rotationDeg,
    required this.pathMode,
    required this.pathParam,
    required this.is3D,
    required this.onWidthCmDrag,
    required this.onRotationDrag,
    required this.onPathParamDrag,
    required this.onInteractionEnd,
  });

  @override
  State<_InteractiveLetteringCanvas> createState() => _InteractiveLetteringCanvasState();
}

class _InteractiveLetteringCanvasState extends State<_InteractiveLetteringCanvas> {
  double _viewZoom = 1.0;
  Offset _viewPan = Offset.zero;
  double _startViewZoom = 1.0;
  Offset _startViewPan = Offset.zero;
  Offset _startFocal = Offset.zero;
  bool _isCameraGesture = false;

  _LetteringHandle _activeHandle = _LetteringHandle.none;
  double _dragStartWidthCm = 12.0;
  double _dragStartRotDeg = 0.0;
  double _dragStartPathParam = 0.35;
  double _dragStartDist = 50.0;
  double _dragStartAngle = 0.0;
  Offset _dragStartPos = Offset.zero;
  double _liveScalePreview = 1.0;
  double _liveRotDeltaDeg = 0.0;
  String? _hudLabel;
  Size _canvasSize = Size.zero;

  double _pxPerCm(Size size) {
    // 18 سم افتراضياً عبر عرض اللوحة بحيث يرى المستخدم تكبير الحروف بوضوح من 3 سم حتى 30 سم على مربعات السنتيمتر!
    final double basePxPerCm = (size.width / 18.0).clamp(14.0, 32.0);
    return basePxPerCm * _viewZoom;
  }

  Rect _designScreenRect(Size size) {
    final double pxPerCm = _pxPerCm(size);
    final double pxPerUnit = pxPerCm / 100.0; // 100 وحدة = 1 سم
    final v = widget.vec;
    final double rawW = max(10.0, v.maxX - v.minX);
    final double rawH = max(10.0, v.maxY - v.minY);
    final double drawW = rawW * pxPerUnit * _liveScalePreview;
    final double drawH = rawH * pxPerUnit * _liveScalePreview;
    final Offset center = Offset(size.width * 0.5, size.height * 0.5) + _viewPan;
    return Rect.fromCenter(center: center, width: drawW, height: drawH);
  }

  Offset _rotatePt(Offset pt, Offset center, double deg) {
    final double r = deg * pi / 180.0;
    final double c = cos(r), s = sin(r);
    final double dx = pt.dx - center.dx;
    final double dy = pt.dy - center.dy;
    return Offset(center.dx + dx * c - dy * s, center.dy + dx * s + dy * c);
  }

  _LetteringHandle _hitTestHandle(Offset pos, Size size) {
    final Rect box = _designScreenRect(size).inflate(8.0);
    final Offset center = box.center;
    const double hitR = 26.0;

    final Offset rotPos = _rotatePt(Offset(box.center.dx, box.top - 26.0), center, _liveRotDeltaDeg);
    if ((pos - rotPos).distance <= hitR) return _LetteringHandle.rotate;

    if (widget.pathMode != 'linear') {
      final double curveOffsetPx = (-widget.pathParam * 22.0).clamp(-26.0, 26.0);
      final Offset curvePos = _rotatePt(Offset(box.center.dx, box.bottom + 24.0 + curveOffsetPx * 0.4), center, _liveRotDeltaDeg);
      if ((pos - curvePos).distance <= hitR) return _LetteringHandle.curve;
    }

    final corners = [
      (_LetteringHandle.resizeTL, _rotatePt(box.topLeft, center, _liveRotDeltaDeg)),
      (_LetteringHandle.resizeTR, _rotatePt(box.topRight, center, _liveRotDeltaDeg)),
      (_LetteringHandle.resizeBR, _rotatePt(box.bottomRight, center, _liveRotDeltaDeg)),
      (_LetteringHandle.resizeBL, _rotatePt(box.bottomLeft, center, _liveRotDeltaDeg)),
    ];
    for (final c in corners) {
      if ((pos - c.$2).distance <= hitR) return c.$1;
    }
    return _LetteringHandle.pan;
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (_canvasSize == Size.zero) return;
    if (details.pointerCount >= 2) {
      _isCameraGesture = true;
      _activeHandle = _LetteringHandle.none;
      _startViewZoom = _viewZoom;
      _startViewPan = _viewPan;
      _startFocal = details.localFocalPoint;
      return;
    }

    _isCameraGesture = false;
    final pos = details.localFocalPoint;
    final h = _hitTestHandle(pos, _canvasSize);
    final Rect box = _designScreenRect(_canvasSize);
    final Offset center = box.center;

    _activeHandle = h;
    _dragStartPos = pos;
    _startViewZoom = _viewZoom;
    _startViewPan = _viewPan;
    _startFocal = pos;
    _dragStartWidthCm = widget.widthCm;
    _dragStartRotDeg = widget.rotationDeg;
    _dragStartPathParam = widget.pathParam;
    _dragStartDist = max(18.0, (pos - center).distance);
    _dragStartAngle = atan2(pos.dy - center.dy, pos.dx - center.dx);
    _liveScalePreview = 1.0;
    _liveRotDeltaDeg = 0.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_canvasSize == Size.zero) return;

    if (_isCameraGesture || details.pointerCount >= 2) {
      if (!_isCameraGesture) {
        _isCameraGesture = true;
        _activeHandle = _LetteringHandle.none;
        _liveScalePreview = 1.0;
        _liveRotDeltaDeg = 0.0;
        _hudLabel = null;
        _startViewZoom = _viewZoom;
        _startViewPan = _viewPan;
        _startFocal = details.localFocalPoint;
      }
      setState(() {
        _viewZoom = (_startViewZoom * details.scale).clamp(0.45, 6.0);
        _viewPan = _startViewPan + (details.localFocalPoint - _startFocal);
      });
      return;
    }

    final pos = details.localFocalPoint;
    final Rect box = _designScreenRect(_canvasSize);
    final Offset center = box.center;

    if (_activeHandle == _LetteringHandle.pan) {
      setState(() {
        _viewPan = _startViewPan + (pos - _startFocal);
      });
      return;
    }

    if (_activeHandle == _LetteringHandle.resizeTL ||
        _activeHandle == _LetteringHandle.resizeTR ||
        _activeHandle == _LetteringHandle.resizeBR ||
        _activeHandle == _LetteringHandle.resizeBL) {
      final double curDist = max(12.0, (pos - center).distance);
      final double ratio = (curDist / _dragStartDist).clamp(0.10, 12.0);
      final double nextW = (_dragStartWidthCm * ratio).clamp(0.8, 250.0);
      setState(() {
        _liveScalePreview = nextW / max(0.5, _dragStartWidthCm);
        _hudLabel = '${tr('العرض', 'W')}: ${nextW.toStringAsFixed(1)} ${tr('سم', 'cm')}';
      });
      widget.onWidthCmDrag(nextW);
      return;
    }

    if (_activeHandle == _LetteringHandle.rotate) {
      final double curAng = atan2(pos.dy - center.dy, pos.dx - center.dx);
      double deltaDeg = (curAng - _dragStartAngle) * 180.0 / pi;
      double nextRot = ((_dragStartRotDeg + deltaDeg) % 360.0 + 360.0) % 360.0;
      for (final snap in [0.0, 90.0, 180.0, 270.0, 360.0]) {
        if ((nextRot - snap).abs() < 3.0) {
          nextRot = snap % 360.0;
          deltaDeg = nextRot - _dragStartRotDeg;
          break;
        }
      }
      setState(() {
        _liveRotDeltaDeg = deltaDeg;
        _hudLabel = '${tr('دوران', 'Rotate')}: ${nextRot.round()}°';
      });
      widget.onRotationDrag(nextRot);
      return;
    }

    if (_activeHandle == _LetteringHandle.curve) {
      final double dy = pos.dy - _dragStartPos.dy;
      final double nextP = (_dragStartPathParam - dy * 0.011).clamp(-1.0, 1.0);
      setState(() {
        _hudLabel = '${tr('انحناء', 'Curve')}: ${(nextP * 100).round()}%';
      });
      widget.onPathParamDrag(nextP);
      return;
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final bool needsRegen = _activeHandle != _LetteringHandle.none && _activeHandle != _LetteringHandle.pan;
    setState(() {
      _activeHandle = _LetteringHandle.none;
      _liveScalePreview = 1.0;
      _liveRotDeltaDeg = 0.0;
      _hudLabel = null;
      _isCameraGesture = false;
    });
    if (needsRegen) {
      widget.onInteractionEnd();
    }
  }

  void _resetView() {
    setState(() {
      _viewZoom = 1.0;
      _viewPan = Offset.zero;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        _canvasSize = Size(c.maxWidth, c.maxHeight);
        final double pxPerCm = _pxPerCm(_canvasSize);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: _resetView,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                child: CustomPaint(
                  painter: _InteractiveLetteringPainter(
                    vec: widget.vec,
                    pxPerCm: pxPerCm,
                    viewPan: _viewPan,
                    liveScalePreview: _liveScalePreview,
                    liveRotDeltaDeg: _liveRotDeltaDeg,
                    pathMode: widget.pathMode,
                    pathParam: widget.pathParam,
                    activeHandle: _activeHandle,
                    is3D: widget.is3D,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
            if (_hudLabel != null)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E131D).withOpacity(0.90),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFD4AF37)),
                    ),
                    child: Text(
                      _hudLabel!,
                      style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                ),
              ),
            Positioned(
              bottom: 6,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF0E131D).withOpacity(0.72),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '1cm • ${widget.widthCm.toStringAsFixed(1)}×${((widget.vec.heightMm ?? 0) / 10.0).toStringAsFixed(1)}cm',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            Positioned(
              bottom: 6,
              right: 8,
              child: Material(
                color: const Color(0xFF0E131D).withOpacity(0.78),
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  onTap: _resetView,
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.all(5),
                    child: Icon(Icons.fit_screen, size: 16, color: Color(0xFFD4AF37)),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _InteractiveLetteringPainter extends CustomPainter {
  final VectorDesignData vec;
  final double pxPerCm;
  final Offset viewPan;
  final double liveScalePreview;
  final double liveRotDeltaDeg;
  final String pathMode;
  final double pathParam;
  final _LetteringHandle activeHandle;
  final bool is3D;

  const _InteractiveLetteringPainter({
    required this.vec,
    required this.pxPerCm,
    required this.viewPan,
    required this.liveScalePreview,
    required this.liveRotDeltaDeg,
    required this.pathMode,
    required this.pathParam,
    required this.activeHandle,
    required this.is3D,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final Offset origin = Offset(size.width * 0.5, size.height * 0.5) + viewPan;

    // 1) رسم شبكة السنتيمتر الحقيقية الموحّدة (100 وحدة = 1 سم)
    final double baseUnitScale = pxPerCm / TarikRenderSpecs.unitsPerCm;
    TarikUnifiedCanvasRenderer.drawCmGrid(
      canvas,
      size,
      scale: baseUnitScale,
      originX: origin.dx,
      originY: origin.dy,
    );

    if (!vec.hasBounds || vec.stX.length < 2) { canvas.restore(); return; }

    // 2) رسم الغرز بالمحرك الموحّد (2D ثابت السماكة أو 3D خيط مبروم حقيقي 0.41 مم)
    final double scale = baseUnitScale * liveScalePreview;
    final double rawCx = (vec.minX + vec.maxX) * 0.5;
    final double rawCy = (vec.minY + vec.maxY) * 0.5;

    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    if (liveRotDeltaDeg.abs() > 0.05) {
      canvas.rotate(liveRotDeltaDeg * pi / 180.0);
    }

    TarikUnifiedCanvasRenderer.paintDesign(
      canvas: canvas,
      data: vec,
      scale: scale,
      offX: -rawCx * scale,
      offY: -rawCy * scale,
      is3D: is3D,
      decorTheme: 0,
      stroke2DPx: TarikRenderSpecs.stroke2DScreenPx,
    );

    // 3) رسم إطار التحديد والمقابض التفاعلية فوق النص مباشرةً (مثل فوتوشوب وويلكم)
    final double drawW = max(10.0, vec.maxX - vec.minX) * scale;
    final double drawH = max(10.0, vec.maxY - vec.minY) * scale;
    final Rect box = Rect.fromCenter(center: Offset.zero, width: drawW, height: drawH).inflate(8.0);

    canvas.drawRect(
      box,
      Paint()
        ..color = const Color(0xFFD4AF37).withOpacity(0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );

    // 4 مقابض الزوايا للتكبير والتصغير (صفراء بارزة)
    final corners = [
      (_LetteringHandle.resizeTL, box.topLeft),
      (_LetteringHandle.resizeTR, box.topRight),
      (_LetteringHandle.resizeBR, box.bottomRight),
      (_LetteringHandle.resizeBL, box.bottomLeft),
    ];
    for (final cn in corners) {
      final bool act = activeHandle == cn.$1;
      final double r = act ? 10.5 : 8.5;
      canvas.drawCircle(cn.$2, r, Paint()..color = act ? const Color(0xFF56CCF2) : const Color(0xFFD4AF37));
      canvas.drawCircle(
        cn.$2,
        r,
        Paint()
          ..color = const Color(0xFF0E131D)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }

    // مقبض الدوران العلوي (سماوي بارز مع خط وصل)
    final Offset rotPos = Offset(0, box.top - 26.0);
    canvas.drawLine(
      Offset(0, box.top),
      rotPos,
      Paint()
        ..color = const Color(0xFF0284C7)
        ..strokeWidth = 1.6,
    );
    final bool rotAct = activeHandle == _LetteringHandle.rotate;
    canvas.drawCircle(rotPos, rotAct ? 11.5 : 9.5, Paint()..color = rotAct ? const Color(0xFFD4AF37) : const Color(0xFF56CCF2));
    canvas.drawCircle(
      rotPos,
      rotAct ? 11.5 : 9.5,
      Paint()
        ..color = const Color(0xFF0E131D)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    canvas.drawArc(
      Rect.fromCircle(center: rotPos, radius: 4.5),
      -pi * 0.7,
      pi * 1.4,
      false,
      Paint()
        ..color = const Color(0xFF0E131D)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    // مقبض الانحناء الأخضر التفاعلي (قوس / دائري / متعرج)
    if (pathMode != 'linear') {
      final double curveOffsetPx = (-pathParam * 22.0).clamp(-26.0, 26.0);
      final Offset curvePos = Offset(0, box.bottom + 24.0 + curveOffsetPx * 0.4);
      final Path guide = Path()
        ..moveTo(box.left, box.bottom + 6.0)
        ..quadraticBezierTo(0, curvePos.dy, box.right, box.bottom + 6.0);
      canvas.drawPath(
        guide,
        Paint()
          ..color = const Color(0xFF16A34A).withOpacity(0.65)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      final bool curveAct = activeHandle == _LetteringHandle.curve;
      canvas.drawCircle(curvePos, curveAct ? 11.5 : 9.5, Paint()..color = curveAct ? const Color(0xFFD4AF37) : Colors.greenAccent);
      canvas.drawCircle(
        curvePos,
        curveAct ? 11.5 : 9.5,
        Paint()
          ..color = const Color(0xFF0E131D)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }

    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _InteractiveLetteringPainter oldDelegate) => true;
}

class TextToEmbroideryScreen extends StatefulWidget {
  const TextToEmbroideryScreen({super.key});
  @override
  State<TextToEmbroideryScreen> createState() => _TextToEmbroideryScreenState();
}

class _TextToEmbroideryScreenState extends State<TextToEmbroideryScreen> {
  final TextEditingController _textCtrl = TextEditingController(text: 'بسم الله');
  final TextEditingController _widthCmCtrl = TextEditingController(text: '12.0');
  final TextEditingController _heightCmCtrl = TextEditingController(text: '3.5');

  VectorDesignData? _vec;
  bool _generating = false;
  bool _saving = false;
  bool _loadingCatalog = true;

  // اختيار مبسّط: لغة الفونط (A = عربي، E = إنجليزي) + رقم الفونط (1..5)
  bool _arabicGroup = true;
  int _fontNumber = 2; // يبدأ تلقائياً على A2 (خط ويلكم العربي الأصلي) وعند التحويل لـ E ينتقل لـ E1

  // الفونطات الأصلية المحمّلة من Wilcom (.DST) و Ink/Stitch (A1..A5 + E1..E5)
  final Map<int, EmbFontMeta> _arProFonts = {};
  final Map<int, EmbFontMeta> _enProFonts = {};

  static const List<String> _arTtfFallbacks = ['Lalezar', 'Lalezar', 'ReemKufi', 'Tajawal', 'Amiri'];
  static const List<String> _enTtfFallbacks = ['Tajawal', 'BebasNeue', 'Cinzel', 'Lobster', 'Pacifico'];

  // المقاس بالأرقام (العرض × الطول بالـ سم) + قفل التناسب + شريط السحب
  double _widthCm = 12.0;
  double? _customHeightCm;
  bool _lockAspect = true;
  double _densityMm = 0.45;
  double _extraSpacingMm = 0.0;
  double _satinWidthOffsetMm = 0.0;
  bool _autoSplit8Mm = true;
  String _pathMode = 'linear';
  double _pathParam = 0.35;
  double _rotationDeg = 0.0;
  Timer? _liveTypeTimer;
  int _underlayMode = 1;
  bool _isSatin = true;
  double _tatamiAngleDeg = 0.0;
  int _tatamiPattern = 0; // 0=قياسي 1/3، 1=مائل 1/4، 2=متعرج، 3=منسوج
  int _selectedColor = 0xFFFF1744;
  String _exportFormat = 'DST';
  String? _hintMsg;

  static const List<int> _threadColors = [
    0xFFFF1744,
    0xFF007BFF,
    0xFF00C853,
    0xFFFFB300,
    0xFFD500F9,
    0xFF000000,
    0xFFD4AF37,
  ];

  @override
  void initState() {
    super.initState();
    _initFontsAndGenerate();
  }

  Future<void> _initFontsAndGenerate() async {
    final fonts = await TarikProFontCatalog.loadIndex();
    if (!mounted) return;
    _arProFonts.clear();
    _enProFonts.clear();
    final List<EmbFontMeta> extraAr = [];
    final List<EmbFontMeta> extraEn = [];
    final arCodeRe = RegExp(r'^A(\d+)$', caseSensitive: false);
    final enCodeRe = RegExp(r'^E(\d+)$', caseSensitive: false);
    for (final f in fonts) {
      final code = f.nameEn.trim();
      final mAr = arCodeRe.firstMatch(code);
      final mEn = enCodeRe.firstMatch(code);
      if (mAr != null) {
        final slot = int.parse(mAr.group(1)!);
        _arProFonts[slot] = f;
      } else if (mEn != null) {
        final slot = int.parse(mEn.group(1)!);
        _enProFonts[slot] = f;
      } else if (f.rtl) {
        extraAr.add(f);
      } else {
        extraEn.add(f);
      }
    }
    for (final f in extraAr) {
      int s = 1;
      while (_arProFonts.containsKey(s)) {
        s++;
      }
      _arProFonts[s] = f;
    }
    for (final f in extraEn) {
      int s = 1;
      while (_enProFonts.containsKey(s)) {
        s++;
      }
      _enProFonts[s] = f;
    }
    setState(() {
      _loadingCatalog = false;
    });
    await _generate();
  }

  List<int> _visibleFontSlots() {
    final map = _arabicGroup ? _arProFonts : _enProFonts;
    final keys = map.keys.toList()..sort();
    if (keys.isNotEmpty) return keys;
    return [1, 2, 3, 4];
  }

  void _scheduleLiveGenerate() {
    _liveTypeTimer?.cancel();
    _liveTypeTimer = Timer(const Duration(milliseconds: 160), () {
      if (mounted) _generate();
    });
  }

  @override
  void dispose() {
    _liveTypeTimer?.cancel();
    _textCtrl.dispose();
    _widthCmCtrl.dispose();
    _heightCmCtrl.dispose();
    super.dispose();
  }

  String get _activeCode => '${_arabicGroup ? 'A' : 'E'}$_fontNumber';

  void _syncDimFields(VectorDesignData? v) {
    if (v == null) return;
    final wCm = (v.widthMm ?? 0.0) / 10.0;
    final hCm = (v.heightMm ?? 0.0) / 10.0;
    if (wCm > 0.1) {
      _widthCm = wCm.clamp(0.5, 500.0);
      _widthCmCtrl.text = wCm.toStringAsFixed(1);
    }
    if (hCm > 0.1) {
      _heightCmCtrl.text = hCm.toStringAsFixed(1);
    }
  }

  Future<void> _generate() async {
    final txt = _textCtrl.text.trim();
    if (txt.isEmpty) {
      if (mounted) {
        setState(() {
          _vec = null;
          _generating = false;
        });
      }
      return;
    }

    setState(() {
      _generating = true;
      _hintMsg = null;
    });

    try {
      VectorDesignData? v;
      final EmbFontMeta? activeMeta = _arabicGroup
          ? (_arProFonts[_fontNumber] ?? (_arProFonts.isNotEmpty ? _arProFonts.values.first : null))
          : (_enProFonts[_fontNumber] ?? (_enProFonts.isNotEmpty ? _enProFonts.values.first : null));

      if (activeMeta != null) {
        v = await TarikProFontEngine.generate(
          meta: activeMeta,
          text: txt,
          letterHeightCm: (_customHeightCm ?? 2.8).clamp(0.5, 120.0),
          targetWidthCm: _widthCm,
          targetHeightCm: _lockAspect ? null : _customHeightCm,
          densityMm: _densityMm,
          extraSpacingMm: _extraSpacingMm,
          satinWidthOffsetMm: _satinWidthOffsetMm,
          autoSplit8Mm: _autoSplit8Mm,
          isTatami: !_isSatin,
          tatamiAngleDeg: _tatamiAngleDeg,
          tatamiPattern: _tatamiPattern,
          pathMode: _pathMode,
          pathParam: _pathParam,
          rotationDeg: _rotationDeg,
          underlayMode: _underlayMode,
          colorArgb: _selectedColor,
        );
      }

      if (mounted) {
        setState(() {
          _vec = v;
          _generating = false;
        });
        _syncDimFields(v);
      }
    } catch (_) {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _applyWidthInput(String txt) {
    final double? w = double.tryParse(txt.trim().replaceAll(',', '.'));
    if (w == null || w < 0.5 || w > 500.0) return;
    _widthCm = w;
    if (_lockAspect) _customHeightCm = null;
    _generate();
  }

  void _applyHeightInput(String txt) {
    final double? h = double.tryParse(txt.trim().replaceAll(',', '.'));
    if (h == null || h < 0.3 || h > 500.0) return;
    if (_lockAspect && _vec != null && (_vec!.widthMm ?? 0) > 0 && (_vec!.heightMm ?? 0) > 0) {
      final ratio = _vec!.widthMm! / _vec!.heightMm!;
      _widthCm = (h * ratio).clamp(0.5, 500.0);
      _customHeightCm = null;
    } else {
      _customHeightCm = h;
    }
    _generate();
  }

  Future<void> _exportText({required bool shareAfter}) async {
    if (_vec == null || _saving) return;
    setState(() => _saving = true);
    try {
      final rawAscii = _textCtrl.text.trim().replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      final prefix = rawAscii.isNotEmpty ? rawAscii.substring(0, min(8, rawAscii.length)) : 'text';
      final shortId = (DateTime.now().millisecondsSinceEpoch % 10000).toString().padLeft(4, '0');
      final safeName = '${prefix}_${_activeCode}_$shortId';
      final ext = _exportFormat.toUpperCase();
      final String outPath = shareAfter
          ? joinCleanPath((await getTemporaryDirectory()).path, '$safeName.$ext')
          : joinCleanPath('/storage/emulated/0/Download', '$safeName.$ext');

      final res = await TarikProDstEncoder.exportToFile(
        _vec!,
        outPath,
        ext,
        baseName: safeName,
      );
      if (res != null && await File(res).exists()) {
        if (shareAfter) {
          await Share.shareXFiles([XFile(res)], text: '$safeName.$ext');
        } else {
          await DesignCacheManager.invalidate(res);
          await DesignCacheManager.getOrParse(res);
          notifyDesignFilesChanged(res);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${tr('تم حفظ ملف التطريز في:', 'Saved embroidery file to:')}\n$res'),
              backgroundColor: const Color(0xFF2E7D32),
              duration: const Duration(seconds: 4),
            ),
          );
          }
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: true,
      bottom: true,
      child: Scaffold(
      backgroundColor: const Color(0xFF0E131D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: Text(
          '${tr('الكتابة والتطريز', 'Lettering')} ($_activeCode)',
          style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 16, fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_vec != null) ...[
            IconButton(
              icon: const Icon(Icons.tune, color: Colors.greenAccent, size: 21),
              tooltip: tr('تعديل الفلم (البداية والإطار)', 'Edit Film (Start & Frame)'),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DesignEditorScreen(
                      initialVector: _vec,
                      defaultBaseName: 'text_$_activeCode',
                    ),
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.select_all, color: Color(0xFF56CCF2), size: 21),
              tooltip: tr('تحديد عنصر', 'Select Element'),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ObjectEditorScreen(
                      initialVector: _vec,
                      defaultBaseName: 'text_$_activeCode',
                    ),
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.play_circle_outline, color: Color(0xFFD4AF37), size: 22),
              tooltip: tr('محاكاة الغرز', 'Simulate'),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => StitchSimulatorScreen(initialVector: _vec)),
                );
              },
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: TextField(
              controller: _textCtrl,
              minLines: 1,
              maxLines: 2,
              textInputAction: TextInputAction.done,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: tr('اكتب هنا ليظهر مباشرة كغرز...', 'Type to preview stitches live...'),
                prefixIcon: const Icon(Icons.bolt, color: Color(0xFFD4AF37), size: 18),
                filled: true,
                fillColor: const Color(0xFF18202E),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              onChanged: (_) => _scheduleLiveGenerate(),
              onSubmitted: (_) => _generate(),
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(10, 2, 10, 6),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
              clipBehavior: Clip.antiAlias,
              child: (_loadingCatalog && _vec == null)
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFD4AF37)))
                  : (_vec == null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              _hintMsg ?? tr('اكتب نصاً ليظهر فوراً كغرز', 'Type text to preview stitches live'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.black54, fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                        )
                      : Stack(
                          children: [
                            Positioned.fill(
                              child: _InteractiveLetteringCanvas(
                                vec: _vec!,
                                widthCm: _widthCm,
                                rotationDeg: _rotationDeg,
                                pathMode: _pathMode,
                                pathParam: _pathParam,
                                is3D: true,
                                onWidthCmDrag: (w) {
                                  setState(() {
                                    _widthCm = w;
                                    _widthCmCtrl.text = w.toStringAsFixed(1);
                                    if (_lockAspect) _customHeightCm = null;
                                  });
                                },
                                onRotationDrag: (r) => setState(() => _rotationDeg = r),
                                onPathParamDrag: (p) {
                                  setState(() => _pathParam = p);
                                  _scheduleLiveGenerate();
                                },
                                onInteractionEnd: _generate,
                              ),
                            ),
                            Positioned(
                              top: 6,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0E131D).withOpacity(0.84),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.6)),
                                ),
                                child: Text(
                                  '$_activeCode${!_isSatin ? ' • Tatami' : ' • Pro'} • ${_vec!.stitches} ${tr('غرزة', 'st')}',
                                  style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                            if (_generating)
                              Positioned(
                                top: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0E131D).withOpacity(0.84),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD4AF37)),
                                  ),
                                ),
                              ),
                          ],
                        )),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.49),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              decoration: const BoxDecoration(
                color: Color(0xFF18202E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // شريط مبسّط: زر A للعربي وزر E للإنجليزي + أرقام الفونط 1..5 بدون أسماء
                    Row(
                      children: [
                        ChoiceChip(
                          label: const Text('A', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                          selected: _arabicGroup,
                          selectedColor: const Color(0xFFD4AF37),
                          backgroundColor: Colors.white10,
                          labelStyle: TextStyle(color: _arabicGroup ? Colors.black : Colors.white),
                          onSelected: (_) {
                            if (!_arabicGroup) {
                              setState(() {
                                _arabicGroup = true;
                                if (!_arProFonts.containsKey(_fontNumber) && _arProFonts.containsKey(2)) {
                                  _fontNumber = 2;
                                }
                                if (_textCtrl.text.trim() == 'Tarik') _textCtrl.text = 'بسم الله';
                              });
                              _generate();
                            }
                          },
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: const Text('E', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                          selected: !_arabicGroup,
                          selectedColor: const Color(0xFF56CCF2),
                          backgroundColor: Colors.white10,
                          labelStyle: TextStyle(color: !_arabicGroup ? Colors.black : Colors.white),
                          onSelected: (_) {
                            if (_arabicGroup) {
                              setState(() {
                                _arabicGroup = false;
                                if (!_enProFonts.containsKey(_fontNumber) && _enProFonts.containsKey(1)) {
                                  _fontNumber = 1;
                                }
                                if (_textCtrl.text.trim() == 'بسم الله') _textCtrl.text = 'Tarik';
                              });
                              _generate();
                            }
                          },
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SizedBox(
                            height: 40,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: _visibleFontSlots().map((numIdx) {
                                final bool sel = _fontNumber == numIdx;
                                final String code = '${_arabicGroup ? 'A' : 'E'}$numIdx';
                                final Color activeCol = _arabicGroup ? const Color(0xFFD4AF37) : const Color(0xFF56CCF2);
                                final EmbFontMeta? slotMeta = _arabicGroup ? _arProFonts[numIdx] : _enProFonts[numIdx];
                                final bool isWilcomSlot = slotMeta != null && slotMeta.id.startsWith('wilcom_');
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 2.5),
                                  child: InkWell(
                                    onTap: () {
                                      if (_fontNumber != numIdx) {
                                        setState(() => _fontNumber = numIdx);
                                        _generate();
                                      }
                                    },
                                    borderRadius: BorderRadius.circular(10),
                                    child: Container(
                                      constraints: const BoxConstraints(minWidth: 46),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: sel ? activeCol : Colors.white10,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: sel ? activeCol : (isWilcomSlot ? activeCol.withOpacity(0.55) : Colors.white12),
                                          width: isWilcomSlot ? 1.4 : 1.0,
                                        ),
                                      ),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            code,
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: sel ? Colors.black : Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12.5,
                                            ),
                                          ),
                                          if (isWilcomSlot)
                                            Container(
                                              margin: const EdgeInsets.only(top: 2),
                                              width: 5,
                                              height: 5,
                                              decoration: BoxDecoration(
                                                color: sel ? Colors.black : activeCol,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // جدول التكبير (العرض × الطول بالـ سم بالأرقام + قفل التناسب + شريط السحب)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _widthCmCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            decoration: InputDecoration(
                              labelText: tr('العرض (سم)', 'Width (cm)'),
                              labelStyle: const TextStyle(color: Colors.white60, fontSize: 11),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                              filled: true,
                              fillColor: const Color(0xFF0E131D),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                            ),
                            onSubmitted: _applyWidthInput,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(() => _lockAspect = !_lockAspect),
                          icon: Icon(
                            _lockAspect ? Icons.link : Icons.link_off,
                            color: _lockAspect ? const Color(0xFFD4AF37) : Colors.white38,
                            size: 20,
                          ),
                          tooltip: tr('قفل التناسب', 'Lock Ratio'),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _heightCmCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            decoration: InputDecoration(
                              labelText: tr('الطول (سم)', 'Height (cm)'),
                              labelStyle: const TextStyle(color: Colors.white60, fontSize: 11),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                              filled: true,
                              fillColor: const Color(0xFF0E131D),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                            ),
                            onSubmitted: _applyHeightInput,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _widthCm.clamp(1.0, max(60.0, _widthCm.ceilToDouble())),
                      min: 1.0,
                      max: max(60.0, _widthCm.ceilToDouble()),
                      activeColor: const Color(0xFFD4AF37),
                      onChanged: (v) {
                        setState(() {
                          _widthCm = v;
                          _widthCmCtrl.text = v.toStringAsFixed(1);
                          if (_lockAspect) _customHeightCm = null;
                        });
                      },
                      onChangeEnd: (_) => _generate(),
                    ),

                    // فستون / تاتامي + الكثافة
                    Row(
                      children: [
                        ChoiceChip(
                          label: Text(tr('فستون', 'Satin'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _isSatin ? Colors.black : Colors.white)),
                          selected: _isSatin,
                          selectedColor: const Color(0xFFD4AF37),
                          backgroundColor: Colors.white10,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) {
                            if (!_isSatin) {
                              setState(() => _isSatin = true);
                              _generate();
                            }
                          },
                        ),
                        const SizedBox(width: 6),
                        ChoiceChip(
                          label: Text(tr('تاتامي', 'Tatami'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: !_isSatin ? Colors.black : Colors.white)),
                          selected: !_isSatin,
                          selectedColor: const Color(0xFFD4AF37),
                          backgroundColor: Colors.white10,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) {
                            if (_isSatin) {
                              setState(() => _isSatin = false);
                              _generate();
                            }
                          },
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Row(
                            children: [
                              Text(
                                '${tr('الكثافة', 'Dens')}: ${_densityMm.toStringAsFixed(2)}',
                                style: const TextStyle(color: Color(0xFF56CCF2), fontWeight: FontWeight.bold, fontSize: 11),
                              ),
                              Expanded(
                                child: Slider(
                                  value: _densityMm.clamp(0.30, 0.80),
                                  min: 0.30,
                                  max: 0.80,
                                  divisions: 10,
                                  activeColor: const Color(0xFF56CCF2),
                                  onChanged: (v) => setState(() => _densityMm = v),
                                  onChangeEnd: (_) => _generate(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (!_isSatin) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            '${tr('زاوية التاتامي', 'Angle')}: ${_tatamiAngleDeg.round()}°',
                            style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 11),
                          ),
                          Expanded(
                            child: Slider(
                              value: _tatamiAngleDeg.clamp(0.0, 180.0),
                              min: 0.0,
                              max: 180.0,
                              divisions: 36,
                              activeColor: Colors.tealAccent,
                              onChanged: (v) {
                                setState(() => _tatamiAngleDeg = v);
                                _scheduleLiveGenerate();
                              },
                            ),
                          ),
                          for (final d in [0, 45, 90, 135])
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 1.5),
                              child: InkWell(
                                onTap: () {
                                  setState(() => _tatamiAngleDeg = d.toDouble());
                                  _generate();
                                },
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: _tatamiAngleDeg.round() == d ? Colors.tealAccent : Colors.white10,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '$d°',
                                    style: TextStyle(
                                      color: _tatamiAngleDeg.round() == d ? Colors.black : Colors.white70,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            tr('نقشة التاتامي:', 'Pattern:'),
                            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                          for (final pt in [
                            (0, tr('قياسي', 'Brick')),
                            (1, tr('مائل', 'Twill')),
                            (2, tr('متعرج', 'Wave')),
                            (3, tr('منسوج', 'Weave')),
                          ])
                            ChoiceChip(
                              label: Text(
                                pt.$2,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: _tatamiPattern == pt.$1 ? Colors.black : Colors.white,
                                ),
                              ),
                              selected: _tatamiPattern == pt.$1,
                              selectedColor: Colors.tealAccent,
                              backgroundColor: Colors.white10,
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) {
                                setState(() => _tatamiPattern = pt.$1);
                                _generate();
                              },
                            ),
                        ],
                      ),
                    ],

                    Row(
                      children: [
                        Text(
                          '${tr('تباعد', 'Sp')}: ${_extraSpacingMm.toStringAsFixed(1)}mm',
                          style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        Expanded(
                          child: Slider(
                            value: _extraSpacingMm.clamp(-2.0, 8.0),
                            min: -2.0,
                            max: 8.0,
                            divisions: 20,
                            activeColor: const Color(0xFFD4AF37),
                            onChanged: (v) {
                              setState(() => _extraSpacingMm = v);
                              _scheduleLiveGenerate();
                            },
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final pm in [
                          ('linear', tr('مستقيم', 'Line')),
                          ('arc', tr('قوس', 'Arc')),
                          ('circle', tr('دائري', 'Circle')),
                          ('wave', tr('متعرج', 'Wave')),
                        ])
                          ChoiceChip(
                            label: Text(pm.$2, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: _pathMode == pm.$1 ? Colors.black : Colors.white)),
                            selected: _pathMode == pm.$1,
                            selectedColor: const Color(0xFF56CCF2),
                            backgroundColor: Colors.white10,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) {
                              setState(() => _pathMode = pm.$1);
                              _generate();
                            },
                          ),
                      ],
                    ),
                    if (_pathMode != 'linear')
                      Row(
                        children: [
                          Text(
                            '${tr('انحناء', 'Curve')}: ${(_pathParam * 100).round()}%',
                            style: const TextStyle(color: Color(0xFF56CCF2), fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                          Expanded(
                            child: Slider(
                              value: _pathParam.clamp(-1.0, 1.0),
                              min: -1.0,
                              max: 1.0,
                              divisions: 40,
                              activeColor: const Color(0xFF56CCF2),
                              onChanged: (v) {
                                setState(() => _pathParam = v);
                                _scheduleLiveGenerate();
                              },
                            ),
                          ),
                          if (_rotationDeg.abs() > 0.5)
                            TextButton(
                              onPressed: () {
                                setState(() => _rotationDeg = 0.0);
                                _generate();
                              },
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 6),
                                minimumSize: Size.zero,
                              ),
                              child: const Text('0°', style: TextStyle(color: Color(0xFFD4AF37), fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          '${tr('فستون', 'Sat')}: ${_satinWidthOffsetMm >= 0 ? '+' : ''}${_satinWidthOffsetMm.toStringAsFixed(1)}mm',
                          style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                        Expanded(
                          child: Slider(
                            value: _satinWidthOffsetMm.clamp(-0.5, 1.0),
                            min: -0.5,
                            max: 1.0,
                            divisions: 15,
                            activeColor: Colors.greenAccent,
                            onChanged: (v) {
                              setState(() => _satinWidthOffsetMm = v);
                              _scheduleLiveGenerate();
                            },
                          ),
                        ),
                        FilterChip(
                          label: Text(tr('قسم >7مم', 'Split >7mm'), style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: _autoSplit8Mm ? Colors.black : Colors.white70)),
                          selected: _autoSplit8Mm,
                          selectedColor: const Color(0xFFD4AF37),
                          backgroundColor: Colors.white10,
                          visualDensity: VisualDensity.compact,
                          onSelected: (v) {
                            setState(() => _autoSplit8Mm = v);
                            _generate();
                          },
                        ),
                      ],
                    ),
                    // لون الخيط
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(tr('لون الخيط:', 'Thread:'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        Row(
                          children: _threadColors.map((c) {
                            final sel = c == _selectedColor;
                            return GestureDetector(
                              onTap: () {
                                setState(() => _selectedColor = c);
                                _generate();
                              },
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 4),
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: Color(c),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: sel ? const Color(0xFFD4AF37) : Colors.white38, width: sel ? 2.5 : 1),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // اختيار صيغة التصدير + أزرار الحفظ والمشاركة
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _exportFormat,
                              dropdownColor: const Color(0xFF18202E),
                              style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12),
                              items: UniversalExporter.supportedFormats
                                  .map((f) => DropdownMenuItem<String>(
                                        value: f['ext'],
                                        child: Text('.${f['ext']}'),
                                      ))
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) setState(() => _exportFormat = v);
                              },
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _saving || _vec == null ? null : () => _exportText(shareAfter: false),
                            icon: const Icon(Icons.save_alt, size: 17, color: Color(0xFFD4AF37)),
                            label: Text(
                              '${tr('حفظ', 'Save')} $_exportFormat',
                              style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFFD4AF37)),
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _saving || _vec == null ? null : () => _exportText(shareAfter: true),
                            icon: const Icon(Icons.ios_share, size: 17),
                            label: Text(
                              '${tr('مشاركة', 'Share')} $_exportFormat',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFD4AF37),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

enum _WilcomHandle {
  none,
  move,
  topLeft,
  topCenter,
  topRight,
  centerRight,
  bottomRight,
  bottomCenter,
  bottomLeft,
  centerLeft,
  rotateKnob,
}

/// نافذة تحديد وتعديل العناصر الفردية مثل برنامج ويلكم (سحب مقابض الزوايا والحواف للتكبير، مقبض الدوران العلوي أو نقرتان للتدوير، سحب للتحريك، تكبير/تصغير/دوران بالأرقام، زوم بإصبعين، تحديد الكل، تكرار وحذف)
class ObjectEditorScreen extends StatefulWidget {
  final EmbDesignInfo? design;
  final VectorDesignData? initialVector;
  final String defaultBaseName;

  const ObjectEditorScreen({
    super.key,
    this.design,
    this.initialVector,
    this.defaultBaseName = 'tarik_obj_edit',
  });

  @override
  State<ObjectEditorScreen> createState() => _ObjectEditorScreenState();
}

class _ObjectEditorScreenState extends State<ObjectEditorScreen> {
  VectorDesignData? _original;
  VectorDesignData? _composed;
  List<ProDesignObject> _objects = const [];
  List<ProObjectTransform> _transforms = [];
  List<int> _palette = [];
  final List<List<ProObjectTransform>> _undoStack = [];

  static const List<int> _extraThreadColors = [
    0xFFFF1744, 0xFF007BFF, 0xFF00C853, 0xFFFFB300,
    0xFFD500F9, 0xFFFF5722, 0xFF00E5FF, 0xFFFF007F,
    0xFFD4AF37, 0xFF1B5E20, 0xFF3E2723, 0xFF000000,
  ];

  int? _selectedTfIndex;
  bool _selectAllMode = false;
  bool _rotateHandlesMode = false; // مثل ويلكم: نقرة ثانية على العنصر تبدّل بين مقابض التحجيم ومقابض الدوران
  bool _loading = true;
  bool _saving = false;
  bool _lockAspect = true;
  Size _canvasSize = Size.zero;

  // كاميرا اللوحة (تكبير وتقريب بإصبعين)
  double _viewZoom = 1.0;
  Offset _viewPan = Offset.zero;
  double _startViewZoom = 1.0;
  Offset _startViewPan = Offset.zero;
  Offset _startFocal = Offset.zero;
  bool _isCameraGesture = false;

  // حالة السحب التفاعلي المباشر للمقابض
  _WilcomHandle _activeHandle = _WilcomHandle.none;
  List<ProObjectTransform>? _dragStartTransforms;
  Offset _dragStartDesign = Offset.zero;
  Offset _dragGroupCenter = Offset.zero;
  String? _liveHudText;

  // مربعات الإدخال الرقمية (عرض × طول بالسم + نسبة % + زاوية °)
  final TextEditingController _objWCtrl = TextEditingController();
  final TextEditingController _objHCtrl = TextEditingController();
  final TextEditingController _objPctCtrl = TextEditingController(text: '100');
  final TextEditingController _objRotCtrl = TextEditingController(text: '0');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _objWCtrl.dispose();
    _objHCtrl.dispose();
    _objPctCtrl.dispose();
    _objRotCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final v = widget.initialVector ?? (widget.design != null ? await loadAnyVectorDesign(widget.design!.filePath) : null);
    if (!mounted) return;
    if (v != null && v.stX.length >= 2) {
      final objs = TarikProObjectEditor.segment(v);
      final tfs = List.generate(objs.length, (i) => ProObjectTransform(sourceObjectId: i));
      setState(() {
        _original = v;
        _objects = objs;
        _transforms = tfs;
        _palette = v.paletteArgb.toList();
        _composed = v;
        _selectedTfIndex = tfs.isNotEmpty ? 0 : null;
        _selectAllMode = false;
        _loading = false;
      });
      _syncNumericFields();
    } else {
      setState(() => _loading = false);
    }
  }

  List<int> get _targetIndices {
    if (_selectAllMode) {
      final res = <int>[];
      for (int i = 0; i < _transforms.length; i++) {
        if (!_transforms[i].deleted) res.add(i);
      }
      return res;
    }
    if (_selectedTfIndex != null && _selectedTfIndex! < _transforms.length && !_transforms[_selectedTfIndex!].deleted) {
      return [_selectedTfIndex!];
    }
    return const [];
  }

  (double, double, double, double)? _selectionBoundsDesign([List<ProObjectTransform>? tfsOverride]) {
    final tfs = tfsOverride ?? _transforms;
    final indices = _targetIndices;
    if (indices.isEmpty) return null;
    double bMinX = double.infinity, bMaxX = -double.infinity;
    double bMinY = double.infinity, bMaxY = -double.infinity;
    for (final idx in indices) {
      if (idx >= tfs.length || tfs[idx].deleted) continue;
      final tf = tfs[idx];
      final obj = _objects[tf.sourceObjectId];
      final b = tf.transformedBounds(obj);
      if (b.$1 < bMinX) bMinX = b.$1;
      if (b.$2 > bMaxX) bMaxX = b.$2;
      if (b.$3 < bMinY) bMinY = b.$3;
      if (b.$4 > bMaxY) bMaxY = b.$4;
    }
    if (!bMinX.isFinite) return null;
    return (bMinX, bMaxX, bMinY, bMaxY);
  }

  void _pushUndo() {
    _undoStack.add(_transforms.map((t) => t.copyWith()).toList());
    if (_undoStack.length > 30) _undoStack.removeAt(0);
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    setState(() {
      _transforms = _undoStack.removeLast();
      if (_selectedTfIndex != null && (_selectedTfIndex! >= _transforms.length || _transforms[_selectedTfIndex!].deleted)) {
        _selectedTfIndex = null;
      }
    });
    _rebuild();
  }

  void _syncNumericFields() {
    final b = _selectionBoundsDesign();
    if (b == null) return;
    final double wCm = (b.$2 - b.$1) / 10.0;
    final double hCm = (b.$4 - b.$3) / 10.0;
    _objWCtrl.text = wCm.toStringAsFixed(1);
    _objHCtrl.text = hCm.toStringAsFixed(1);
    final indices = _targetIndices;
    if (indices.length == 1) {
      final tf = _transforms[indices.first];
      _objPctCtrl.text = (tf.scaleX * 100.0).round().toString();
      _objRotCtrl.text = tf.rotationDeg.round().toString();
    } else if (indices.isNotEmpty) {
      double avgS = 0.0;
      for (final idx in indices) {
        avgS += _transforms[idx].scaleX;
      }
      _objPctCtrl.text = ((avgS / indices.length) * 100.0).round().toString();
      _objRotCtrl.text = _transforms[indices.first].rotationDeg.round().toString();
    }
  }

  void _rebuild({bool syncNums = true}) {
    if (_original == null) return;
    final next = TarikProObjectEditor.apply(
      _original!,
      _objects,
      _transforms,
      customPaletteArgb: _palette,
    );
    setState(() => _composed = next);
    if (syncNums) _syncNumericFields();
  }

  void _setSelectedColorIndex(int colorIdx) {
    final indices = _targetIndices;
    if (indices.isEmpty) return;
    _pushUndo();
    for (final idx in indices) {
      _transforms[idx].colorIndexOverride = colorIdx;
    }
    _rebuild(syncNums: false);
  }

  Future<void> _pickAndAddNewColor() async {
    final int? pickedArgb = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF18202E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr('إضافة لون جديد للعنصر المحدد', 'Add New Color for Selected Element'),
                style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: _extraThreadColors.map((argb) {
                  return GestureDetector(
                    onTap: () => Navigator.pop(ctx, argb),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Color(argb),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white70, width: 2),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
    if (pickedArgb == null || !mounted) return;
    int existingIdx = _palette.indexOf(pickedArgb);
    if (existingIdx == -1) {
      setState(() => _palette.add(pickedArgb));
      existingIdx = _palette.length - 1;
    }
    _setSelectedColorIndex(existingIdx);
  }

  void _toggleSelectedTrim() {
    final indices = _targetIndices;
    if (indices.isEmpty) return;
    _pushUndo();
    final bool nextVal = !_transforms[indices.first].insertTrimAfter;
    for (final idx in indices) {
      _transforms[idx].insertTrimAfter = nextVal;
    }
    _rebuild(syncNums: false);
  }

  /// تحويل إحداثيات التصميم <-> إحداثيات الشاشة مع دعم الزوم والتحريك بإصبعين
  (double, double, double) _canvasTransformParams(Size size) {
    final data = _original!;
    final double rawW = max(1.0, data.maxX - data.minX);
    final double rawH = max(1.0, data.maxY - data.minY);
    const double pad = 34.0;
    final double baseScale = min((size.width - pad * 2) / rawW, (size.height - pad * 2) / rawH);
    final double scale = baseScale * _viewZoom;
    final double baseOffX = (size.width - rawW * baseScale) * 0.5 - data.minX * baseScale;
    final double baseOffY = (size.height - rawH * baseScale) * 0.5 - data.minY * baseScale;
    final double cx = size.width * 0.5;
    final double cy = size.height * 0.5;
    final double offX = (baseOffX - cx) * _viewZoom + cx + _viewPan.dx;
    final double offY = (baseOffY - cy) * _viewZoom + cy + _viewPan.dy;
    return (scale, offX, offY);
  }

  Offset _screenToDesign(Offset pt) {
    final p = _canvasTransformParams(_canvasSize);
    return Offset((pt.dx - p.$2) / p.$1, (pt.dy - p.$3) / p.$1);
  }

  Rect? _selectionScreenRect() {
    if (_original == null || _canvasSize == Size.zero) return null;
    final b = _selectionBoundsDesign();
    if (b == null) return null;
    final p = _canvasTransformParams(_canvasSize);
    return Rect.fromLTRB(
      b.$1 * p.$1 + p.$2 - 6,
      b.$3 * p.$1 + p.$3 - 6,
      b.$2 * p.$1 + p.$2 + 6,
      b.$4 * p.$1 + p.$3 + 6,
    );
  }

  _WilcomHandle _hitTestHandles(Offset screenPos) {
    final rect = _selectionScreenRect();
    if (rect == null) return _WilcomHandle.none;
    const double hitR = 24.0;

    // 1) مقبض الدوران العلوي الدائري (دائماً متاح فوق الصندوق!)
    final knobPos = Offset(rect.center.dx, rect.top - 28.0);
    if ((screenPos - knobPos).distance <= hitR + 4.0) {
      return _WilcomHandle.rotateKnob;
    }

    // 2) المقابض الـ 8 (4 زوايا + 4 أضلاع)
    final handleMap = <(_WilcomHandle, Offset)>[
      (_WilcomHandle.topLeft, rect.topLeft),
      (_WilcomHandle.topRight, rect.topRight),
      (_WilcomHandle.bottomLeft, rect.bottomLeft),
      (_WilcomHandle.bottomRight, rect.bottomRight),
      (_WilcomHandle.topCenter, rect.topCenter),
      (_WilcomHandle.bottomCenter, rect.bottomCenter),
      (_WilcomHandle.centerLeft, rect.centerLeft),
      (_WilcomHandle.centerRight, rect.centerRight),
    ];

    _WilcomHandle bestH = _WilcomHandle.none;
    double bestD = hitR;
    for (final entry in handleMap) {
      final d = (screenPos - entry.$2).distance;
      if (d < bestD) {
        bestD = d;
        bestH = entry.$1;
      }
    }
    if (bestH != _WilcomHandle.none) return bestH;

    // 3) داخل الصندوق المحيط = تحريك العنصر
    if (rect.inflate(8.0).contains(screenPos)) {
      return _WilcomHandle.move;
    }
    return _WilcomHandle.none;
  }

  void _onCanvasTap(Offset localPos) {
    if (_original == null || _canvasSize == Size.zero) return;
    final designPt = _screenToDesign(localPos);
    final p = _canvasTransformParams(_canvasSize);
    final hit = TarikProObjectEditor.hitTest(_objects, _transforms, designPt.dx, designPt.dy, padUnits: 24.0 / p.$1);

    setState(() {
      if (hit != null) {
        if (!_selectAllMode && hit == _selectedTfIndex) {
          // مثل برنامج ويلكم: النقر مرة ثانية على نفس العنصر المحدد يبدّل بين مقابض التحجيم ومقابض الدوران!
          _rotateHandlesMode = !_rotateHandlesMode;
        } else {
          _selectAllMode = false;
          _selectedTfIndex = hit;
          _rotateHandlesMode = false;
        }
      } else {
        _selectAllMode = false;
        _selectedTfIndex = null;
        _rotateHandlesMode = false;
      }
    });
    _syncNumericFields();
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (_original == null || _canvasSize == Size.zero) return;
    if (details.pointerCount >= 2) {
      _isCameraGesture = true;
      _activeHandle = _WilcomHandle.none;
      _startViewZoom = _viewZoom;
      _startViewPan = _viewPan;
      _startFocal = details.localFocalPoint;
      return;
    }

    _isCameraGesture = false;
    final pos = details.localFocalPoint;
    _WilcomHandle h = _hitTestHandles(pos);

    // إذا لم يضغط على مقبض أو داخل الصندوق الحالي، نفحص إن كان لمس عنصراً آخر فنحدده ونحرّكه فوراً
    if (h == _WilcomHandle.none) {
      final designPt = _screenToDesign(pos);
      final p = _canvasTransformParams(_canvasSize);
      final hit = TarikProObjectEditor.hitTest(_objects, _transforms, designPt.dx, designPt.dy, padUnits: 22.0 / p.$1);
      if (hit != null) {
        setState(() {
          _selectAllMode = false;
          _selectedTfIndex = hit;
          _rotateHandlesMode = false;
        });
        h = _WilcomHandle.move;
      } else {
        // سحب على المساحة الفارغة = تحريك الكاميرا
        _isCameraGesture = true;
        _startViewZoom = _viewZoom;
        _startViewPan = _viewPan;
        _startFocal = pos;
        return;
      }
    }

    final b = _selectionBoundsDesign();
    if (b == null) return;

    _pushUndo();
    _activeHandle = h;
    _dragStartTransforms = _transforms.map((t) => t.copyWith()).toList();
    _dragStartDesign = _screenToDesign(pos);
    _dragGroupCenter = Offset((b.$1 + b.$2) * 0.5, (b.$3 + b.$4) * 0.5);
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_original == null || _canvasSize == Size.zero) return;

    // 1) تحريك أو تكبير الكاميرا بإصبعين (أو سحب الخلفية الفارغة)
    if (_isCameraGesture || details.pointerCount >= 2) {
      if (!_isCameraGesture) {
        // انتقل من إصبع واحد إلى إصبعين منتصف الحركة -> نلغي سحب العنصر ونبدأ الزوم
        if (_dragStartTransforms != null) {
          _transforms = _dragStartTransforms!.map((t) => t.copyWith()).toList();
          _dragStartTransforms = null;
          _activeHandle = _WilcomHandle.none;
          _liveHudText = null;
        }
        _isCameraGesture = true;
        _startViewZoom = _viewZoom;
        _startViewPan = _viewPan;
        _startFocal = details.localFocalPoint;
      }
      setState(() {
        _viewZoom = (_startViewZoom * details.scale).clamp(0.5, 8.0);
        _viewPan = _startViewPan + (details.localFocalPoint - _startFocal);
      });
      return;
    }

    if (_activeHandle == _WilcomHandle.none || _dragStartTransforms == null) return;
    final indices = _targetIndices;
    if (indices.isEmpty) return;

    final curDesign = _screenToDesign(details.localFocalPoint);
    final startTfs = _dragStartTransforms!;
    final gCx = _dragGroupCenter.dx;
    final gCy = _dragGroupCenter.dy;

    final bool isCorner = _activeHandle == _WilcomHandle.topLeft ||
        _activeHandle == _WilcomHandle.topRight ||
        _activeHandle == _WilcomHandle.bottomLeft ||
        _activeHandle == _WilcomHandle.bottomRight;

    // 2) دوران مباشر (من مقبض الدوران العلوي أو من الزوايا عند تفعيل وضع الدوران مثل ويلكم)
    if (_activeHandle == _WilcomHandle.rotateKnob || (_rotateHandlesMode && isCorner)) {
      final double ang0 = atan2(_dragStartDesign.dy - gCy, _dragStartDesign.dx - gCx);
      final double ang1 = atan2(curDesign.dy - gCy, curDesign.dx - gCx);
      double deltaDeg = (ang1 - ang0) * 180.0 / pi;

      // مغناطيس ناعم عند الزوايا القائمة (0 / 90 / 180 / 270)
      if (indices.length == 1) {
        final double rawTarget = ((startTfs[indices.first].rotationDeg + deltaDeg) % 360.0 + 360.0) % 360.0;
        for (final snap in [0.0, 90.0, 180.0, 270.0, 360.0]) {
          if ((rawTarget - snap).abs() < 2.5) {
            deltaDeg += (snap - rawTarget);
            break;
          }
        }
      }

      final double rad = deltaDeg * pi / 180.0;
      final double ca = cos(rad), sa = sin(rad);

      for (final idx in indices) {
        final tf0 = startTfs[idx];
        final obj = _objects[tf0.sourceObjectId];
        final double rx0 = (obj.centerX + tf0.dx) - gCx;
        final double ry0 = (obj.centerY + tf0.dy) - gCy;
        final double newCx = gCx + rx0 * ca - ry0 * sa;
        final double newCy = gCy + rx0 * sa + ry0 * ca;
        _transforms[idx].dx = newCx - obj.centerX;
        _transforms[idx].dy = newCy - obj.centerY;
        _transforms[idx].rotationDeg = ((tf0.rotationDeg + deltaDeg) % 360.0 + 360.0) % 360.0;
      }

      final displayAngle = _transforms[indices.first].rotationDeg.round();
      _liveHudText = '${tr('دوران', 'Rotate')}: $displayAngle°';
      _rebuild(syncNums: true);
      return;
    }

    // 3) تحريك العنصر بالسحب المباشر
    if (_activeHandle == _WilcomHandle.move) {
      final double ddx = curDesign.dx - _dragStartDesign.dx;
      final double ddy = curDesign.dy - _dragStartDesign.dy;
      for (final idx in indices) {
        _transforms[idx].dx = startTfs[idx].dx + ddx;
        _transforms[idx].dy = startTfs[idx].dy + ddy;
      }
      _liveHudText = 'X: ${(ddx / 10.0).toStringAsFixed(1)}  Y: ${(ddy / 10.0).toStringAsFixed(1)} ${tr('سم', 'cm')}';
      _rebuild(syncNums: false);
      return;
    }

    // 4) تكبير وتصغير مباشر عبر سحب الزوايا أو الحواف (مثل ويلكم)
    double fx = 1.0;
    double fy = 1.0;
    if (isCorner) {
      if (_lockAspect) {
        final double r0 = max(10.0, (_dragStartDesign - _dragGroupCenter).distance);
        final double r1 = (curDesign - _dragGroupCenter).distance;
        final double f = (r1 / r0).clamp(0.05, 20.0);
        fx = f;
        fy = f;
      } else {
        final double dx0 = max(8.0, (_dragStartDesign.dx - gCx).abs());
        final double dy0 = max(8.0, (_dragStartDesign.dy - gCy).abs());
        fx = ((curDesign.dx - gCx).abs() / dx0).clamp(0.05, 20.0);
        fy = ((curDesign.dy - gCy).abs() / dy0).clamp(0.05, 20.0);
      }
    } else if (_activeHandle == _WilcomHandle.centerLeft || _activeHandle == _WilcomHandle.centerRight) {
      final double dx0 = max(8.0, (_dragStartDesign.dx - gCx).abs());
      fx = ((curDesign.dx - gCx).abs() / dx0).clamp(0.05, 20.0);
      fy = 1.0;
    } else if (_activeHandle == _WilcomHandle.topCenter || _activeHandle == _WilcomHandle.bottomCenter) {
      final double dy0 = max(8.0, (_dragStartDesign.dy - gCy).abs());
      fx = 1.0;
      fy = ((curDesign.dy - gCy).abs() / dy0).clamp(0.05, 20.0);
    }

    for (final idx in indices) {
      final tf0 = startTfs[idx];
      final obj = _objects[tf0.sourceObjectId];
      final double rx0 = (obj.centerX + tf0.dx) - gCx;
      final double ry0 = (obj.centerY + tf0.dy) - gCy;
      _transforms[idx].dx = (gCx + rx0 * fx) - obj.centerX;
      _transforms[idx].dy = (gCy + ry0 * fy) - obj.centerY;
      _transforms[idx].scaleX = (tf0.scaleX * fx).clamp(0.05, 20.0);
      _transforms[idx].scaleY = (tf0.scaleY * fy).clamp(0.05, 20.0);
    }

    final nb = _selectionBoundsDesign();
    if (nb != null) {
      final wCm = ((nb.$2 - nb.$1) / 10.0).toStringAsFixed(1);
      final hCm = ((nb.$4 - nb.$3) / 10.0).toStringAsFixed(1);
      _liveHudText = '$wCm × $hCm ${tr('سم', 'cm')}';
    }
    _rebuild(syncNums: true);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_activeHandle != _WilcomHandle.none || _liveHudText != null) {
      setState(() {
        _activeHandle = _WilcomHandle.none;
        _dragStartTransforms = null;
        _liveHudText = null;
      });
      _syncNumericFields();
    }
    _isCameraGesture = false;
  }

  void _selectRelative(int delta) {
    final activeIndices = <int>[];
    for (int i = 0; i < _transforms.length; i++) {
      if (!_transforms[i].deleted) activeIndices.add(i);
    }
    if (activeIndices.isEmpty) return;
    int pos = _selectedTfIndex != null ? activeIndices.indexOf(_selectedTfIndex!) : -1;
    pos = (pos + delta) % activeIndices.length;
    if (pos < 0) pos += activeIndices.length;
    setState(() {
      _selectAllMode = false;
      _selectedTfIndex = activeIndices[pos];
      _rotateHandlesMode = false;
    });
    _syncNumericFields();
  }

  void _scaleSelectionByFactors(double fx, double fy) {
    final indices = _targetIndices;
    final b = _selectionBoundsDesign();
    if (indices.isEmpty || b == null) return;
    _pushUndo();
    final double gCx = (b.$1 + b.$2) * 0.5;
    final double gCy = (b.$3 + b.$4) * 0.5;
    for (final idx in indices) {
      final tf = _transforms[idx];
      final obj = _objects[tf.sourceObjectId];
      final double rx = (obj.centerX + tf.dx) - gCx;
      final double ry = (obj.centerY + tf.dy) - gCy;
      tf.dx = (gCx + rx * fx) - obj.centerX;
      tf.dy = (gCy + ry * fy) - obj.centerY;
      tf.scaleX = (tf.scaleX * fx).clamp(0.05, 20.0);
      tf.scaleY = (tf.scaleY * fy).clamp(0.05, 20.0);
    }
    _rebuild(syncNums: true);
  }

  void _applyNumericWidth(String txt) {
    final b = _selectionBoundsDesign();
    final double? targetW = double.tryParse(txt.trim().replaceAll(',', '.'));
    if (b == null || targetW == null || targetW < 0.2 || targetW > 500.0) return;
    final double curW = (b.$2 - b.$1) / 10.0;
    if (curW <= 0.05) return;
    final double fx = (targetW / curW).clamp(0.05, 20.0);
    _scaleSelectionByFactors(fx, _lockAspect ? fx : 1.0);
  }

  void _applyNumericHeight(String txt) {
    final b = _selectionBoundsDesign();
    final double? targetH = double.tryParse(txt.trim().replaceAll(',', '.'));
    if (b == null || targetH == null || targetH < 0.2 || targetH > 500.0) return;
    final double curH = (b.$4 - b.$3) / 10.0;
    if (curH <= 0.05) return;
    final double fy = (targetH / curH).clamp(0.05, 20.0);
    _scaleSelectionByFactors(_lockAspect ? fy : 1.0, fy);
  }

  void _applyNumericPercent(String txt) {
    final indices = _targetIndices;
    final double? pct = double.tryParse(txt.trim().replaceAll(',', '.').replaceAll('%', ''));
    if (indices.isEmpty || pct == null || pct < 5.0 || pct > 2000.0) return;
    final double targetScale = (pct / 100.0).clamp(0.05, 20.0);
    final double curScale = _transforms[indices.first].scaleX;
    if (curScale <= 0.01) return;
    final double f = (targetScale / curScale).clamp(0.05, 20.0);
    _scaleSelectionByFactors(f, f);
  }

  void _applyNumericRotation(String txt) {
    final indices = _targetIndices;
    final b = _selectionBoundsDesign();
    final double? targetDeg = double.tryParse(txt.trim().replaceAll(',', '.').replaceAll('°', ''));
    if (indices.isEmpty || b == null || targetDeg == null) return;
    final double curDeg = _transforms[indices.first].rotationDeg;
    final double deltaDeg = targetDeg - curDeg;
    if (deltaDeg.abs() < 0.05) return;
    _pushUndo();
    final double gCx = (b.$1 + b.$2) * 0.5;
    final double gCy = (b.$3 + b.$4) * 0.5;
    final double rad = deltaDeg * pi / 180.0;
    final double ca = cos(rad), sa = sin(rad);
    for (final idx in indices) {
      final tf = _transforms[idx];
      final obj = _objects[tf.sourceObjectId];
      final double rx = (obj.centerX + tf.dx) - gCx;
      final double ry = (obj.centerY + tf.dy) - gCy;
      tf.dx = (gCx + rx * ca - ry * sa) - obj.centerX;
      tf.dy = (gCy + rx * sa + ry * ca) - obj.centerY;
      tf.rotationDeg = ((tf.rotationDeg + deltaDeg) % 360.0 + 360.0) % 360.0;
    }
    _rebuild(syncNums: true);
  }

  void _applyAllNumericInputs() {
    FocusScope.of(context).unfocus();
    final b = _selectionBoundsDesign();
    if (b == null) return;
    final curW = ((b.$2 - b.$1) / 10.0).toStringAsFixed(1);
    final curH = ((b.$4 - b.$3) / 10.0).toStringAsFixed(1);
    final indices = _targetIndices;
    final curPct = indices.isNotEmpty ? (_transforms[indices.first].scaleX * 100.0).round().toString() : '100';
    final curRot = indices.isNotEmpty ? _transforms[indices.first].rotationDeg.round().toString() : '0';

    if (_objWCtrl.text.trim() != curW) {
      _applyNumericWidth(_objWCtrl.text);
    } else if (_objHCtrl.text.trim() != curH) {
      _applyNumericHeight(_objHCtrl.text);
    } else if (_objPctCtrl.text.trim() != curPct) {
      _applyNumericPercent(_objPctCtrl.text);
    }
    if (_objRotCtrl.text.trim() != curRot) {
      _applyNumericRotation(_objRotCtrl.text);
    }
  }

  Future<void> _saveDesign() async {
    if (_composed == null || _saving) return;
    setState(() => _saving = true);
    try {
      String targetExt = 'DST';
      String baseName = widget.defaultBaseName;
      String outDir = '/storage/emulated/0/Download';

      if (widget.design != null) {
        final origExt = widget.design!.filePath.split('.').last.toUpperCase();
        if (UniversalExporter.supportedFormats.any((f) => f['ext'] == origExt)) {
          targetExt = origExt;
        }
        baseName = '${widget.design!.fileName.replaceAll(RegExp(r'\.[^.]+$'), '')}_pro';
        outDir = File(widget.design!.filePath).parent.path;
      } else {
        baseName = '${widget.defaultBaseName}_${DateTime.now().millisecondsSinceEpoch}';
      }

      String? res = await TarikProDstEncoder.exportToFile(_composed!, joinCleanPath(outDir, '$baseName.$targetExt'), targetExt, baseName: baseName);
      res ??= await TarikProDstEncoder.exportToFile(_composed!, '/storage/emulated/0/Download/$baseName.$targetExt', targetExt, baseName: baseName);

      if (res != null && await File(res).exists()) {
        await DesignCacheManager.invalidate(res);
        await DesignCacheManager.getOrParse(res);
        notifyDesignFilesChanged(res);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${tr('تم حفظ التصميم المعدّل:', 'Saved modified design:')}\n$res'),
              backgroundColor: const Color(0xFF2E7D32),
            ),
          );
          Navigator.of(context).pop(res);
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeCount = _transforms.where((t) => !t.deleted).length;
    final indices = _targetIndices;
    final bool hasSelection = indices.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF0E131D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: Text(
          tr('تعديل العناصر', 'Object Editor'),
          style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 15, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            onPressed: () => setState(() {
              _viewZoom = 1.0;
              _viewPan = Offset.zero;
            }),
            icon: const Icon(Icons.fit_screen, color: Colors.white70, size: 20),
            tooltip: tr('إعادة ضبط العرض', 'Fit View'),
          ),
          IconButton(
            onPressed: _undoStack.isEmpty ? null : _undo,
            icon: const Icon(Icons.undo, color: Colors.white, size: 21),
            tooltip: tr('تراجع', 'Undo'),
          ),
          TextButton.icon(
            onPressed: _saving || _composed == null ? null : _saveDesign,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD4AF37)))
                : const Icon(Icons.save, color: Color(0xFFD4AF37), size: 19),
            label: Text(tr('حفظ', 'Save'), style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFD4AF37)))
          : (_original == null || _objects.isEmpty)
              ? Center(child: Text(tr('لا توجد عناصر قابلة للتحديد', 'No selectable elements'), style: const TextStyle(color: Colors.white70)))
              : Column(
                  children: [
                    // شريط اختيار العنصر + تبديل (عنصر / الكل) + تبديل مقابض (تحجيم / دوران)
                    Container(
                      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF18202E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            padding: EdgeInsets.zero,
                            onPressed: () => _selectRelative(-1),
                            icon: const Icon(Icons.chevron_left, color: Color(0xFFD4AF37)),
                          ),
                          Expanded(
                            child: Text(
                              _selectAllMode
                                  ? '${tr('الكل محدد', 'All Selected')} ($activeCount)'
                                  : (hasSelection
                                      ? (() {
                                          final tf = _transforms[_selectedTfIndex!];
                                          final obj = _objects[tf.sourceObjectId];
                                          final extra = StringBuffer();
                                          if (obj.sequinsCount > 0) extra.write(' ✨${obj.sequinsCount}');
                                          if (obj.beadsCount > 0) extra.write(' ●${obj.beadsCount}');
                                          if (tf.insertTrimAfter) extra.write(' ✂️');
                                          return '${tr('عنصر', 'Obj')} #${_selectedTfIndex! + 1}/$activeCount$extra';
                                        })()
                                      : tr('اضغط على عنصر', 'Tap element')),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            padding: EdgeInsets.zero,
                            onPressed: () => _selectRelative(1),
                            icon: const Icon(Icons.chevron_right, color: Color(0xFFD4AF37)),
                          ),
                          const SizedBox(width: 4),
                          ChoiceChip(
                            label: Text(
                              tr('الكل', 'All'),
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _selectAllMode ? Colors.black : Colors.white),
                            ),
                            selected: _selectAllMode,
                            selectedColor: const Color(0xFFD4AF37),
                            backgroundColor: Colors.white10,
                            visualDensity: VisualDensity.compact,
                            onSelected: (v) {
                              setState(() {
                                _selectAllMode = v;
                                if (!v && _selectedTfIndex == null && _transforms.isNotEmpty) {
                                  _selectedTfIndex = 0;
                                }
                              });
                              _syncNumericFields();
                            },
                          ),
                          const SizedBox(width: 4),
                          ChoiceChip(
                            label: Icon(
                              _rotateHandlesMode ? Icons.rotate_right : Icons.open_with,
                              size: 16,
                              color: _rotateHandlesMode ? Colors.black : const Color(0xFF56CCF2),
                            ),
                            selected: _rotateHandlesMode,
                            selectedColor: const Color(0xFF56CCF2),
                            backgroundColor: Colors.white10,
                            visualDensity: VisualDensity.compact,
                            onSelected: (v) => setState(() => _rotateHandlesMode = v),
                          ),
                        ],
                      ),
                    ),

                    // شاشة العمل التفاعلية بمقابض ويلكم المباشرة (تحريك + تكبير بالزوايا والحواف + مقبض الدوران العلوي + زوم بإصبعين)
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(12, 2, 12, 6),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                        clipBehavior: Clip.antiAlias,
                        child: LayoutBuilder(
                          builder: (ctx, constraints) {
                            _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                            return Stack(
                              children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapUp: (d) => _onCanvasTap(d.localPosition),
                                  onScaleStart: _onScaleStart,
                                  onScaleUpdate: _onScaleUpdate,
                                  onScaleEnd: _onScaleEnd,
                                  child: CustomPaint(
                                    painter: _ObjectEditorCanvasPainter(
                                      original: _original!,
                                      objects: _objects,
                                      transforms: _transforms,
                                      paletteArgb: _palette,
                                      selectedIndices: indices.toSet(),
                                      selectionBounds: _selectionBoundsDesign(),
                                      rotateHandlesMode: _rotateHandlesMode,
                                      activeHandle: _activeHandle,
                                      viewZoom: _viewZoom,
                                      viewPan: _viewPan,
                                    ),
                                    size: Size.infinite,
                                  ),
                                ),
                                if (_liveHudText != null)
                                  Positioned(
                                    top: 10,
                                    left: 0,
                                    right: 0,
                                    child: Center(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF0E131D).withOpacity(0.90),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(color: const Color(0xFFD4AF37)),
                                        ),
                                        child: Text(
                                          _liveHudText!,
                                          style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 13),
                                        ),
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  bottom: 6,
                                  left: 8,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0E131D).withOpacity(0.75),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      tr('اسحب الزوايا للتكبير • الدائرة الخضراء للدوران • إصبعين للتقريب', 'Drag corners: Resize • Green knob: Rotate • 2 fingers: Zoom'),
                                      style: const TextStyle(color: Colors.white, fontSize: 10),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),

                    // لوحة الأرقام والأدوات السريعة (ويلكم)
                    if (hasSelection)
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.40),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                          decoration: const BoxDecoration(
                            color: Color(0xFF18202E),
                            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // الصف 1: جدول الأرقام (عرض سم × طول سم + قفل التناسب + زر تطبيق ✓)
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _objWCtrl,
                                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                        decoration: InputDecoration(
                                          labelText: tr('العرض (سم)', 'W (cm)'),
                                          labelStyle: const TextStyle(color: Colors.white60, fontSize: 10),
                                          isDense: true,
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                                          filled: true,
                                          fillColor: const Color(0xFF0E131D),
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                                        ),
                                        onSubmitted: _applyNumericWidth,
                                      ),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                      padding: EdgeInsets.zero,
                                      onPressed: () => setState(() => _lockAspect = !_lockAspect),
                                      icon: Icon(
                                        _lockAspect ? Icons.link : Icons.link_off,
                                        color: _lockAspect ? const Color(0xFFD4AF37) : Colors.white38,
                                        size: 19,
                                      ),
                                      tooltip: tr('قفل التناسب', 'Lock Aspect'),
                                    ),
                                    Expanded(
                                      child: TextField(
                                        controller: _objHCtrl,
                                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                        decoration: InputDecoration(
                                          labelText: tr('الطول (سم)', 'H (cm)'),
                                          labelStyle: const TextStyle(color: Colors.white60, fontSize: 10),
                                          isDense: true,
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                                          filled: true,
                                          fillColor: const Color(0xFF0E131D),
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                                        ),
                                        onSubmitted: _applyNumericHeight,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    SizedBox(
                                      width: 58,
                                      child: TextField(
                                        controller: _objPctCtrl,
                                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 13),
                                        decoration: InputDecoration(
                                          labelText: '%',
                                          labelStyle: const TextStyle(color: Colors.greenAccent, fontSize: 10),
                                          isDense: true,
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                                          filled: true,
                                          fillColor: const Color(0xFF0E131D),
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                                        ),
                                        onSubmitted: _applyNumericPercent,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    SizedBox(
                                      width: 54,
                                      child: TextField(
                                        controller: _objRotCtrl,
                                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(color: Color(0xFF56CCF2), fontWeight: FontWeight.bold, fontSize: 13),
                                        decoration: InputDecoration(
                                          labelText: '°',
                                          labelStyle: const TextStyle(color: Color(0xFF56CCF2), fontSize: 11),
                                          isDense: true,
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                                          filled: true,
                                          fillColor: const Color(0xFF0E131D),
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.white24)),
                                        ),
                                        onSubmitted: _applyNumericRotation,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    ElevatedButton(
                                      onPressed: _applyAllNumericInputs,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFFD4AF37),
                                        foregroundColor: Colors.black,
                                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
                                        minimumSize: Size.zero,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      child: const Icon(Icons.check, size: 17),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),

                                // الصف 2: أزرار تكبير/تصغير سريعة + دوران +90° + قلب + تكرار + حذف
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  alignment: WrapAlignment.center,
                                  children: [
                                    OutlinedButton(
                                      onPressed: () => _scaleSelectionByFactors(0.90, 0.90),
                                      style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24), visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                                      child: const Text('-10%', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                                    ),
                                    OutlinedButton(
                                      onPressed: () => _scaleSelectionByFactors(1.10, 1.10),
                                      style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24), visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                                      child: const Text('+10%', style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 11)),
                                    ),
                                    OutlinedButton(
                                      onPressed: () {
                                        final cur = _transforms[indices.first].rotationDeg;
                                        _applyNumericRotation(((cur + 90.0) % 360.0).toStringAsFixed(0));
                                      },
                                      style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24), visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                                      child: const Text('+90°', style: TextStyle(color: Color(0xFF56CCF2), fontWeight: FontWeight.bold, fontSize: 11)),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () {
                                        _pushUndo();
                                        for (final idx in indices) {
                                          _transforms[idx].flipH = !_transforms[idx].flipH;
                                        }
                                        _rebuild();
                                      },
                                      icon: const Icon(Icons.flip, size: 15, color: Color(0xFFD4AF37)),
                                      label: Text(tr('أفقي', 'H'), style: const TextStyle(color: Colors.white, fontSize: 11)),
                                      style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24), visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () {
                                        _pushUndo();
                                        for (final idx in indices) {
                                          _transforms[idx].flipV = !_transforms[idx].flipV;
                                        }
                                        _rebuild();
                                      },
                                      icon: const Icon(Icons.swap_vert, size: 15, color: Color(0xFFD4AF37)),
                                      label: Text(tr('عمودي', 'V'), style: const TextStyle(color: Colors.white, fontSize: 11)),
                                      style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24), visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                                    ),
                                    if (!_selectAllMode && _selectedTfIndex != null) ...[
                                      OutlinedButton.icon(
                                        onPressed: () {
                                          _pushUndo();
                                          final selTf = _transforms[_selectedTfIndex!];
                                          final dup = selTf.copyWith(dx: selTf.dx + 45.0, dy: selTf.dy + 45.0);
                                          _transforms.add(dup);
                                          _selectedTfIndex = _transforms.length - 1;
                                          _rebuild();
                                        },
                                        icon: const Icon(Icons.copy, size: 15, color: Colors.greenAccent),
                                        label: Text(tr('تكرار', 'Dup'), style: const TextStyle(color: Colors.greenAccent, fontSize: 11)),
                                        style: OutlinedButton.styleFrom(side: BorderSide(color: Colors.greenAccent.withOpacity(0.5)), visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: activeCount > 1
                                            ? () {
                                                _pushUndo();
                                                _transforms[_selectedTfIndex!].deleted = true;
                                                _selectedTfIndex = null;
                                                _rebuild(syncNums: false);
                                              }
                                            : null,
                                        icon: const Icon(Icons.delete_outline, size: 15, color: Colors.redAccent),
                                        label: Text(tr('حذف', 'Del'), style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
                                        style: OutlinedButton.styleFrom(side: BorderSide(color: Colors.redAccent.withOpacity(0.5)), visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                                      ),
                                    ],
                                    OutlinedButton.icon(
                                      onPressed: _toggleSelectedTrim,
                                      icon: Icon(
                                        Icons.content_cut,
                                        size: 15,
                                        color: _transforms[indices.first].insertTrimAfter ? Colors.black : Colors.orangeAccent,
                                      ),
                                      label: Text(
                                        tr('مقص', 'Trim'),
                                        style: TextStyle(
                                          color: _transforms[indices.first].insertTrimAfter ? Colors.black : Colors.orangeAccent,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11,
                                        ),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        backgroundColor: _transforms[indices.first].insertTrimAfter ? Colors.orangeAccent : null,
                                        side: BorderSide(color: Colors.orangeAccent.withOpacity(0.65)),
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(horizontal: 8),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                // الصف 3: تغيير لون العنصر أو إضافة لون جديد
                                Row(
                                  children: [
                                    Text(
                                      tr('اللون:', 'Color:'),
                                      style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: SizedBox(
                                        height: 28,
                                        child: ListView.separated(
                                          scrollDirection: Axis.horizontal,
                                          itemCount: _palette.length + 1,
                                          separatorBuilder: (_, __) => const SizedBox(width: 6),
                                          itemBuilder: (_, idx) {
                                            if (idx == _palette.length) {
                                              return GestureDetector(
                                                onTap: _pickAndAddNewColor,
                                                child: Container(
                                                  width: 28,
                                                  height: 28,
                                                  decoration: BoxDecoration(
                                                    color: const Color(0xFFD4AF37).withOpacity(0.2),
                                                    shape: BoxShape.circle,
                                                    border: Border.all(color: const Color(0xFFD4AF37), width: 1.5),
                                                  ),
                                                  child: const Icon(Icons.add, size: 16, color: Color(0xFFD4AF37)),
                                                ),
                                              );
                                            }
                                            final tf0 = _transforms[indices.first];
                                            final int activeColorIdx = tf0.colorIndexOverride ?? _objects[tf0.sourceObjectId].colorIndex;
                                            final bool isColSel = (activeColorIdx % _palette.length) == idx;
                                            return GestureDetector(
                                              onTap: () => _setSelectedColorIndex(idx),
                                              child: Container(
                                                width: 26,
                                                height: 26,
                                                decoration: BoxDecoration(
                                                  color: Color(_palette[idx]),
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                    color: isColSel ? const Color(0xFFD4AF37) : Colors.white38,
                                                    width: isColSel ? 2.6 : 1.2,
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _ObjectEditorCanvasPainter extends CustomPainter {
  final VectorDesignData original;
  final List<ProDesignObject> objects;
  final List<ProObjectTransform> transforms;
  final List<int> paletteArgb;
  final Set<int> selectedIndices;
  final (double, double, double, double)? selectionBounds;
  final bool rotateHandlesMode;
  final _WilcomHandle activeHandle;
  final double viewZoom;
  final Offset viewPan;

  _ObjectEditorCanvasPainter({
    required this.original,
    required this.objects,
    required this.transforms,
    required this.paletteArgb,
    required this.selectedIndices,
    required this.selectionBounds,
    required this.rotateHandlesMode,
    required this.activeHandle,
    required this.viewZoom,
    required this.viewPan,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!original.hasBounds || original.stX.length < 2) return;
    final double rawW = max(1.0, original.maxX - original.minX);
    final double rawH = max(1.0, original.maxY - original.minY);
    const double pad = 34.0;
    final double baseScale = min((size.width - pad * 2) / rawW, (size.height - pad * 2) / rawH);
    final double scale = baseScale * viewZoom;
    final double baseOffX = (size.width - rawW * baseScale) * 0.5 - original.minX * baseScale;
    final double baseOffY = (size.height - rawH * baseScale) * 0.5 - original.minY * baseScale;
    final double scx = size.width * 0.5;
    final double scy = size.height * 0.5;
    final double offX = (baseOffX - scx) * viewZoom + scx + viewPan.dx;
    final double offY = (baseOffY - scy) * viewZoom + scy + viewPan.dy;

    final List<int> activePal = paletteArgb.isNotEmpty ? paletteArgb : original.paletteArgb.toList();
    final int palLen = max(1, activePal.length);
    final bool hasAnySel = selectedIndices.isNotEmpty;
    final Uint8List? devArr = original.stDev;
    const seqColors = [
      Color(0xFFE53935),
      Color(0xFFFB8C00),
      Color(0xFF1E88E5),
      Color(0xFF8E24AA),
    ];
    const beadColors = [
      Color(0xFFD4A017),
      Color(0xFF00ACC1),
      Color(0xFF8E24AA),
    ];

    for (int tIdx = 0; tIdx < transforms.length; tIdx++) {
      final tf = transforms[tIdx];
      if (tf.deleted) continue;
      final obj = objects[tf.sourceObjectId];
      final bool isSel = selectedIndices.contains(tIdx);

      final double cx = obj.centerX;
      final double cy = obj.centerY;
      final double rad = tf.rotationDeg * pi / 180.0;
      final double ca = cos(rad);
      final double sa = sin(rad);

      final path = Path();
      bool hasMove = false;
      final List<(double, double, int)> objSeqs = [];
      final List<(double, double, int)> objBeads = [];

      for (final rng in obj.ranges) {
        final int s = rng.$1.clamp(0, original.stX.length);
        final int e = rng.$2.clamp(s, original.stX.length);
        for (int i = s; i < e; i++) {
          final double lx = (original.stX[i] - cx) * tf.scaleX * (tf.flipH ? -1.0 : 1.0);
          final double ly = (original.stY[i] - cy) * tf.scaleY * (tf.flipV ? -1.0 : 1.0);
          final double rx = lx * ca - ly * sa + cx + tf.dx;
          final double ry = lx * sa + ly * ca + cy + tf.dy;
          final double sx = rx * scale + offX;
          final double sy = ry * scale + offY;
          if (i == s || original.stMove[i] != 0 || !hasMove) {
            path.moveTo(sx, sy);
            hasMove = true;
          } else {
            path.lineTo(sx, sy);
          }
          if (devArr != null && i < devArr.length) {
            final int dt = devArr[i] & 0x0F;
            if (dt >= 1 && dt <= 4) {
              objSeqs.add((sx, sy, dt - 1));
            } else if (dt >= 5 && dt <= 7) {
              objBeads.add((sx, sy, dt - 5));
            }
          }
        }
      }

      final int effectiveColorIdx = tf.colorIndexOverride ?? obj.colorIndex;
      final Color col = Color(activePal[effectiveColorIdx % palLen]);
      final double opacity = isSel ? 1.0 : (hasAnySel ? 0.38 : 1.0);
      canvas.drawPath(
        path,
        Paint()
          ..color = col.withOpacity(opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = isSel ? TarikRenderSpecs.stroke2DScreenPx : (TarikRenderSpecs.stroke2DScreenPx * 0.85)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );

      if (objSeqs.isNotEmpty) {
        final double sr = (18.0 * scale * max(tf.scaleX, tf.scaleY)).clamp(1.6, 11.0);
        for (final sq in objSeqs) {
          canvas.drawCircle(
            Offset(sq.$1, sq.$2),
            sr,
            Paint()
              ..color = seqColors[sq.$3 % 4].withOpacity(opacity)
              ..style = PaintingStyle.stroke
              ..strokeWidth = (sr * 0.28).clamp(0.7, 2.0),
          );
        }
      }

      if (objBeads.isNotEmpty) {
        final double br = (12.0 * scale * max(tf.scaleX, tf.scaleY)).clamp(1.5, 6.5);
        for (final bd in objBeads) {
          canvas.drawCircle(
            Offset(bd.$1, bd.$2),
            br,
            Paint()..color = beadColors[bd.$3 % 3].withOpacity(opacity),
          );
        }
      }
    }

    // إطار تحديد تفاعلي مثل برنامج ويلكم بمقابض زوايا وأضلاع ومقبض دوران علوي ومركز الدوران ⊕
    if (selectionBounds != null) {
      final b = selectionBounds!;
      final rect = Rect.fromLTRB(
        b.$1 * scale + offX - 6,
        b.$3 * scale + offY - 6,
        b.$2 * scale + offX + 6,
        b.$4 * scale + offY + 6,
      );

      // خلفية خفيفة وإطار أزرق/ذهبي
      canvas.drawRect(
        rect,
        Paint()
          ..color = (rotateHandlesMode ? const Color(0xFF00ACC1) : const Color(0xFF007BFF)).withOpacity(0.06)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = rotateHandlesMode ? const Color(0xFF00ACC1) : const Color(0xFF007BFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );

      // علامة مركز العنصر (Pivot ⊕)
      final center = rect.center;
      final pivotPaint = Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas.drawCircle(center, 4.0, pivotPaint);
      canvas.drawLine(Offset(center.dx - 7, center.dy), Offset(center.dx + 7, center.dy), pivotPaint);
      canvas.drawLine(Offset(center.dx, center.dy - 7), Offset(center.dx, center.dy + 7), pivotPaint);

      // مقبض الدوران العلوي الدائري (أخضر/ذهبي بارز)
      final knobPos = Offset(rect.center.dx, rect.top - 28.0);
      canvas.drawLine(
        rect.topCenter,
        knobPos,
        Paint()
          ..color = const Color(0xFF2E7D32)
          ..strokeWidth = 1.8,
      );
      final bool knobActive = activeHandle == _WilcomHandle.rotateKnob;
      canvas.drawCircle(
        knobPos,
        knobActive ? 11.0 : 9.0,
        Paint()..color = knobActive ? const Color(0xFFD4AF37) : const Color(0xFF2E7D32),
      );
      canvas.drawCircle(
        knobPos,
        knobActive ? 11.0 : 9.0,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );
      // رمز سهم دائري صغير داخل مقبض الدوران
      canvas.drawArc(
        Rect.fromCircle(center: knobPos, radius: 4.2),
        -pi * 0.7,
        pi * 1.4,
        false,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );

      // المقابض الـ 8 (زوايا + أضلاع)
      final corners = [
        (_WilcomHandle.topLeft, rect.topLeft),
        (_WilcomHandle.topRight, rect.topRight),
        (_WilcomHandle.bottomLeft, rect.bottomLeft),
        (_WilcomHandle.bottomRight, rect.bottomRight),
      ];
      final edges = [
        (_WilcomHandle.topCenter, rect.topCenter),
        (_WilcomHandle.bottomCenter, rect.bottomCenter),
        (_WilcomHandle.centerLeft, rect.centerLeft),
        (_WilcomHandle.centerRight, rect.centerRight),
      ];

      for (final c in corners) {
        final bool isAct = activeHandle == c.$1;
        if (rotateHandlesMode) {
          // مقابض دوران دائرية مفرّغة مثل ويلكم
          canvas.drawCircle(c.$2, isAct ? 9.0 : 7.0, Paint()..color = isAct ? const Color(0xFF56CCF2) : Colors.white);
          canvas.drawCircle(
            c.$2,
            isAct ? 9.0 : 7.0,
            Paint()
              ..color = const Color(0xFF007BFF)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0,
          );
        } else {
          // مقابض تحجيم مربعة مثل ويلكم (أكبر وأسهل للمس بالأصبع)
          final hRect = Rect.fromCenter(center: c.$2, width: isAct ? 14.0 : 11.0, height: isAct ? 14.0 : 11.0);
          canvas.drawRect(hRect, Paint()..color = isAct ? const Color(0xFF56CCF2) : const Color(0xFFD4AF37));
          canvas.drawRect(
            hRect,
            Paint()
              ..color = Colors.black
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
        }
      }

      for (final e in edges) {
        final bool isAct = activeHandle == e.$1;
        final hRect = Rect.fromCenter(center: e.$2, width: isAct ? 12.0 : 9.5, height: isAct ? 12.0 : 9.5);
        canvas.drawRect(hRect, Paint()..color = isAct ? const Color(0xFF56CCF2) : Colors.white);
        canvas.drawRect(
          hRect,
          Paint()
            ..color = const Color(0xFF007BFF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ObjectEditorCanvasPainter oldDelegate) => true;
}

/// شاشة حساب التطريز المبسطة (حساب مباشر للغرز والترتر والخرز والخيط والوقت + سعر الـ 1000 غرزة الافتراضي 0.09$ + عدد القطع)
class EmbroideryCalculatorScreen extends StatefulWidget {
  final EmbDesignInfo? design;
  const EmbroideryCalculatorScreen({super.key, this.design});
  @override
  State<EmbroideryCalculatorScreen> createState() => _EmbroideryCalculatorScreenState();
}

class _EmbroideryCalculatorScreenState extends State<EmbroideryCalculatorScreen> {
  final TextEditingController _stitchesCtrl = TextEditingController();
  final TextEditingController _pricePer1kCtrl = TextEditingController(text: '0.09');
  final TextEditingController _qtyCtrl = TextEditingController(text: '1');
  final TextEditingController _sequinsCtrl = TextEditingController(text: '0');
  final TextEditingController _priceSeq1kCtrl = TextEditingController(text: '0.00');
  final TextEditingController _beadsCtrl = TextEditingController(text: '0');
  final TextEditingController _priceBead1kCtrl = TextEditingController(text: '0.00');
  final TextEditingController _speedCtrl = TextEditingController(text: '800');
  final TextEditingController _colorsCtrl = TextEditingController(text: '1');

  static const List<String> _ratePresets = ['0.07', '0.08', '0.09', '0.10', '0.12', '0.15'];

  @override
  void initState() {
    super.initState();
    final d = widget.design;
    if (d != null) {
      _stitchesCtrl.text = '${d.stitches}';
      _sequinsCtrl.text = '${d.sequinsCount}';
      _beadsCtrl.text = '${d.beadsCount}';
      _colorsCtrl.text = '${max(1, d.colorCount)}';
    } else {
      _stitchesCtrl.text = '10000';
    }
    _loadSavedRates();
  }

  @override
  void dispose() {
    _stitchesCtrl.dispose();
    _pricePer1kCtrl.dispose();
    _qtyCtrl.dispose();
    _sequinsCtrl.dispose();
    _priceSeq1kCtrl.dispose();
    _beadsCtrl.dispose();
    _priceBead1kCtrl.dispose();
    _speedCtrl.dispose();
    _colorsCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedRates() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/tarik_calc_prefs_v2.json');
      if (await f.exists()) {
        final Map<String, dynamic> map = jsonDecode(await f.readAsString());
        if (!mounted) return;
        setState(() {
          if (map['pricePer1k'] != null) _pricePer1kCtrl.text = map['pricePer1k'].toString();
          if (map['priceSeq1k'] != null) _priceSeq1kCtrl.text = map['priceSeq1k'].toString();
          if (map['priceBead1k'] != null) _priceBead1kCtrl.text = map['priceBead1k'].toString();
          if (map['speed'] != null) _speedCtrl.text = map['speed'].toString();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveRates() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/tarik_calc_prefs_v2.json');
      await f.writeAsString(jsonEncode({
        'pricePer1k': _pricePer1kCtrl.text.trim(),
        'priceSeq1k': _priceSeq1kCtrl.text.trim(),
        'priceBead1k': _priceBead1kCtrl.text.trim(),
        'speed': _speedCtrl.text.trim(),
      }));
    } catch (_) {}
  }

  double _p(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.')) ?? 0.0;

  @override
  Widget build(BuildContext context) {
    final bool fromDesign = widget.design != null;
    final double stitches = _p(_stitchesCtrl).clamp(0, 1e9);
    final double rate1k = _p(_pricePer1kCtrl).clamp(0, 1e6);
    final double sequins = _p(_sequinsCtrl).clamp(0, 1e9);
    final double rateSeq1k = _p(_priceSeq1kCtrl).clamp(0, 1e6);
    final double beads = _p(_beadsCtrl).clamp(0, 1e9);
    final double rateBead1k = _p(_priceBead1kCtrl).clamp(0, 1e6);
    final int qty = max(1, _p(_qtyCtrl).round());
    final double speedSpm = _p(_speedCtrl).clamp(100, 3000);
    final int colors = max(1, _p(_colorsCtrl).round());

    final double stitchCost = (stitches / 1000.0) * rate1k;
    final double seqCost = (sequins / 1000.0) * rateSeq1k;
    final double beadCost = (beads / 1000.0) * rateBead1k;
    final double unitTotalUsd = stitchCost + seqCost + beadCost;
    final double grandTotalUsd = unitTotalUsd * qty;

    // تقدير استهلاك الخيط (متر): ~5.2 متر خيط علوي + ~1.8 متر بوبين لكل 1000 غرزة
    final double upperThreadM = (stitches / 1000.0) * 5.2;
    final double bobbinThreadM = (stitches / 1000.0) * 1.8;

    // تقدير الوقت بالدقائق: وقت الغرز + 12 ثانية لكل تغيير لون
    final double runMinutes = (stitches / speedSpm) + ((colors - 1) * 0.2);
    final int mins = runMinutes.floor();
    final int secs = ((runMinutes - mins) * 60).round();

    final numFmt = intl.NumberFormat('#,###');

    return Scaffold(
      backgroundColor: const Color(0xFF0E131D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: Text(tr('حساب التطريز (\$)', 'Embroidery Calculator (\$)'), style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.share, color: Color(0xFFD4AF37)),
            tooltip: tr('مشاركة التسعيرة', 'Share Quote'),
            onPressed: () {
              final title = widget.design?.fileName ?? tr('تسعيرة تطريز', 'Embroidery Quote');
              final seqLine = sequins > 0 ? '• ${tr('الترتر', 'Sequins')}: ${numFmt.format(sequins.round())}\n' : '';
              final beadLine = beads > 0 ? '• ${tr('الخرز', 'Beads')}: ${numFmt.format(beads.round())}\n' : '';
              final totalLine = qty > 1 ? '💰 ${tr('الإجمالي', 'Total')} ($qty): \$${grandTotalUsd.toStringAsFixed(2)}' : '';
              final msg = '🧵 $title\n'
                  '• ${tr('الغرز', 'Stitches')}: ${numFmt.format(stitches.round())}\n'
                  '$seqLine'
                  '$beadLine'
                  '• ${tr('الوقت التقديري', 'Est. Time')}: $mins ${tr('د', 'm')} $secs ${tr('ث', 's')}\n'
                  '• ${tr('الخيط العلوي', 'Upper Thread')}: ${upperThreadM.toStringAsFixed(1)} ${tr('م', 'm')}\n'
                  '• ${tr('سعر الـ 1000 غرزة', 'Rate / 1K')}: \$${rate1k.toStringAsFixed(2)}\n'
                  '💵 ${tr('سعر القطعة', 'Unit Price')}: \$${unitTotalUsd.toStringAsFixed(2)}\n'
                  '$totalLine';
              Share.share(msg);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
        children: [
          if (fromDesign)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF18202E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.4)),
              ),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  widget.design!.fileName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
            ),

          // 1) بطاقة النتيجة والإحصائيات المباشرة للتصميم
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1F2B3E), Color(0xFF141C2B)],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFD4AF37), width: 1.4),
            ),
            child: Column(
              children: [
                Text(tr('سعر القطعة الواحدة', 'Unit Price'), style: const TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                Text(
                  '\$${unitTotalUsd.toStringAsFixed(2)}',
                  style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 36),
                ),
                if (qty > 1) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E7D32).withOpacity(0.35),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${tr('الإجمالي لـ', 'Total for')} $qty ${tr('قطعة', 'pcs')}:  \$${grandTotalUsd.toStringAsFixed(2)}',
                      style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                ],
                const Divider(color: Colors.white12, height: 22),
                Wrap(
                  spacing: 18,
                  runSpacing: 12,
                  alignment: WrapAlignment.spaceAround,
                  children: [
                    _StatBadge(
                      label: tr('الغرز', 'Stitches'),
                      value: numFmt.format(stitches.round()),
                      color: const Color(0xFF56CCF2),
                    ),
                    if (sequins > 0)
                      _StatBadge(
                        label: tr('الترتر', 'Sequins'),
                        value: numFmt.format(sequins.round()),
                        color: Colors.pinkAccent,
                      ),
                    if (beads > 0)
                      _StatBadge(
                        label: tr('الخرز', 'Beads'),
                        value: numFmt.format(beads.round()),
                        color: const Color(0xFFFFCA28),
                      ),
                    _StatBadge(
                      label: tr('الوقت', 'Time'),
                      value: '$mins:${secs.toString().padLeft(2, '0')} ${tr('د', 'm')}',
                      color: Colors.purpleAccent,
                    ),
                    _StatBadge(
                      label: tr('خيط علوي', 'Upper'),
                      value: '${upperThreadM.toStringAsFixed(1)} ${tr('م', 'm')}',
                      color: Colors.lightGreenAccent,
                    ),
                    _StatBadge(
                      label: tr('مكوك', 'Bobbin'),
                      value: '${bobbinThreadM.toStringAsFixed(1)} ${tr('م', 'm')}',
                      color: Colors.orangeAccent,
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 2) الحقول الأساسية المبسّطة فقط: سعر الـ 1000 غرزة + عدد القطع
          if (!fromDesign) ...[
            _buildCalcField(
              label: tr('عدد الغرز', 'Stitch Count'),
              controller: _stitchesCtrl,
              onChanged: () => setState(() {}),
            ),
            const SizedBox(height: 12),
          ],

          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                flex: 3,
                child: _buildCalcField(
                  label: tr('سعر الـ 1000 غرزة (\$)', 'Price / 1K Stitches (\$)'),
                  controller: _pricePer1kCtrl,
                  onChanged: () {
                    setState(() {});
                    _saveRates();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('عدد القطع', 'Quantity'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 4),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF18202E),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(minWidth: 34, minHeight: 42),
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.remove, color: Color(0xFFD4AF37), size: 18),
                            onPressed: qty > 1
                                ? () {
                                    _qtyCtrl.text = '${qty - 1}';
                                    setState(() {});
                                  }
                                : null,
                          ),
                          Expanded(
                            child: TextField(
                              controller: _qtyCtrl,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                              decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(minWidth: 34, minHeight: 42),
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.add, color: Color(0xFFD4AF37), size: 18),
                            onPressed: () {
                              _qtyCtrl.text = '${qty + 1}';
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // أزرار سريعة لأسعار الـ 1000 غرزة الشائعة (مثل 9 سنت)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _ratePresets.map((preset) {
              final sel = _pricePer1kCtrl.text.trim() == preset;
              return ChoiceChip(
                label: Text(
                  '\$$preset',
                  style: TextStyle(
                    color: sel ? Colors.black : Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                selected: sel,
                selectedColor: const Color(0xFFD4AF37),
                backgroundColor: const Color(0xFF18202E),
                visualDensity: VisualDensity.compact,
                onSelected: (_) {
                  _pricePer1kCtrl.text = preset;
                  setState(() {});
                  _saveRates();
                },
              );
            }).toList(),
          ),

          const SizedBox(height: 14),

          // 3) إعدادات متقدمة مطوية (سرعة الماكينة / تسعير إضافي للترتر والخرز / تعديل الغرز)
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF18202E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10),
            ),
            child: ExpansionTile(
              iconColor: const Color(0xFFD4AF37),
              collapsedIconColor: Colors.white60,
              title: Text(
                tr('إعدادات إضافية (سرعة الماكينة / الترتر والخرز)', 'More Options (Speed / Sequins & Beads)'),
                style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
              ),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: [
                if (fromDesign) ...[
                  _buildCalcField(
                    label: tr('تعديل عدد الغرز يدوياً', 'Override Stitch Count'),
                    controller: _stitchesCtrl,
                    onChanged: () => setState(() {}),
                  ),
                  const SizedBox(height: 10),
                ],
                _buildPairRow(
                  leftLabel: tr('عدد الترتر', 'Sequins'),
                  leftCtrl: _sequinsCtrl,
                  rightLabel: tr('سعر الألف ترتر (\$)', 'Price / 1K Sequins'),
                  rightCtrl: _priceSeq1kCtrl,
                  saveRight: true,
                ),
                const SizedBox(height: 10),
                _buildPairRow(
                  leftLabel: tr('عدد الخرز', 'Beads'),
                  leftCtrl: _beadsCtrl,
                  rightLabel: tr('سعر الألف خرزة (\$)', 'Price / 1K Beads'),
                  rightCtrl: _priceBead1kCtrl,
                  saveRight: true,
                ),
                const SizedBox(height: 10),
                _buildPairRow(
                  leftLabel: tr('سرعة الماكينة (غرزة/د)', 'Speed (SPM)'),
                  leftCtrl: _speedCtrl,
                  rightLabel: tr('عدد الألوان', 'Colors'),
                  rightCtrl: _colorsCtrl,
                  saveLeft: true,
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),
          Text(
            tr(
              '* يتم حفظ سعر الـ 1000 غرزة تلقائياً (الافتراضي 0.09\$ = 9 سنت).',
              '* Your default price per 1K stitches is saved automatically (default \$0.09).',
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildPairRow({
    required String leftLabel,
    required TextEditingController leftCtrl,
    required String rightLabel,
    required TextEditingController rightCtrl,
    bool saveLeft = false,
    bool saveRight = false,
  }) {
    return Row(
      children: [
        Expanded(
          child: _buildCalcField(
            label: leftLabel,
            controller: leftCtrl,
            onChanged: () {
              setState(() {});
              if (saveLeft) _saveRates();
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildCalcField(
            label: rightLabel,
            controller: rightCtrl,
            onChanged: () {
              setState(() {});
              if (saveRight) _saveRates();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCalcField({
    required String label,
    required TextEditingController controller,
    required VoidCallback onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF0E131D),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.white12)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Colors.white12)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFD4AF37))),
          ),
          onChanged: (_) => onChanged(),
        ),
      ],
    );
  }
}
// Tarik emb - Pro v6.6
