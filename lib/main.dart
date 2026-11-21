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

final ValueNotifier<bool> isArabicNotifier = ValueNotifier<bool>(true);

String tr(String ar, String en) => isArabicNotifier.value ? ar : en;
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

Future<EmbDesignInfo?> parseAnyDesignFile(String path) async {
  final lower = path.toLowerCase();
  if (lower.endsWith('.dst')) {
    return await DstParser.parseFile(path, maxCanvas: 640.0);
  } else if (lower.endsWith('.emb')) {
    return await EmbParser.parseFile(path);
  } else if (lower.endsWith('.dhp') || lower.endsWith('.dha') || lower.endsWith('.dhe')) {
    return await DahaoParser.parseFile(path, maxCanvas: 640.0);
  } else if (UniversalFormatParser.isSupported(lower)) {
    return await UniversalFormatParser.parseFile(path, maxCanvas: 640.0);
  } else {
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
}

/// مدير الكاش والمزامنة الدائمة على ذاكرة الهاتف لفتح المجلدات فوراً بدون انتظار
class DesignCacheManager {
  static final Map<String, EmbDesignInfo> _memCache = {};
  static Directory? _cacheDir;

  static Future<Directory> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory('${supportDir.path}/design_cache_v4');
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
          if (hasImg) {
            await imgFile.writeAsBytes(parsed.previewJpeg!, flush: false);
          }
          final metaMap = {
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
            child: child ?? const SizedBox.shrink(),
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

class _FoldersGalleryPageState extends State<FoldersGalleryPage> {
  static const MethodChannel _intentChannel = MethodChannel('tarik_emb/file_intent');
  bool _isScanning = false;
  bool _isBackgroundSyncing = false;
  String _statusText = '';
  final List<EmbFolderGroup> _folders = [];
  int _scanToken = 0;

  int get _totalFilesCount => _folders.fold(0, (sum, folder) => sum + folder.filePaths.length);

  @override
  void initState() {
    super.initState();
    _setupIncomingFileHandler();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.license['activated'] != true) _showTrialToast();
      _showSignatureDialog();
      _startBackgroundScan();
    });
  }

  Future<void> _setupIncomingFileHandler() async {
    _intentChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFileOpened' && call.arguments is String) {
        await _openIncomingEmbFile(call.arguments as String);
      }
    });
    try {
      final initialPath = await _intentChannel.invokeMethod('getInitialFile');
      if (initialPath is String && initialPath.isNotEmpty) {
        await _openIncomingEmbFile(initialPath);
      }
    } catch (_) {}
  }

  Future<void> _openIncomingEmbFile(String path) async {
    final EmbDesignInfo? info = await DesignCacheManager.getOrParse(path);
    if (info == null || !mounted) return;
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

  Future<void> _startBackgroundScan() async {
    final int currentToken = ++_scanToken;
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
    setState(() {
      _isScanning = true;
      _folders.clear();
      _statusText = tr('جاري البحث عن المجلدات...', 'Scanning folders...');
    });

    final List<String> savedDirs = await _readSavedFolders();
    final Set<String> candidateDirs = {
      ...savedDirs,
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Documents',
      '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Documents',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Documents',
      '/storage/emulated/0/Telegram/Telegram Documents',
    };

    final Map<String, List<String>> folderMap = {};

    for (final rootPath in candidateDirs) {
      if (currentToken != _scanToken) return;
      final rootDir = Directory(rootPath);
      if (await rootDir.exists()) {
        try {
          int count = 0;
          await for (final entity in rootDir.list(recursive: true, followLinks: false)) {
            if (currentToken != _scanToken) return;
            count++;
            if (count % 40 == 0) await Future.delayed(const Duration(milliseconds: 1));
            final p = entity.path.toLowerCase();
            if (entity is File && validExtensions.any((ext) => p.endsWith(ext))) {
              folderMap.putIfAbsent(entity.parent.path, () => []).add(entity.path);
            }
          }
        } catch (_) {}
      }
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
            title: const Text(
              'Tarik emb',
              style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFD4AF37), letterSpacing: 0.6),
            ),
            actions: [
              if (_isBackgroundSyncing)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD4AF37)),
                    ),
                  ),
                ),
              if (widget.license['activated'] != true)
                IconButton(
                  icon: const Icon(Icons.lock_open, color: Colors.greenAccent),
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
              TextButton.icon(
                onPressed: () async {
                  await _EmbGalleryAppState.toggleLanguage();
                  setState(() {});
                },
                icon: const Icon(Icons.language, color: Color(0xFFD4AF37), size: 18),
                label: Text(isAr ? 'EN' : 'عربي', style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold)),
              ),
              IconButton(
                icon: const Icon(Icons.text_fields, color: Color(0xFFD4AF37)),
                tooltip: tr('كتابة وتحويل لغرز', 'Text to Stitches'),
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TextToEmbroideryScreen()),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.refresh, color: Color(0xFFD4AF37)),
                tooltip: tr('تحديث', 'Refresh'),
                onPressed: _startBackgroundScan,
              ),
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
                            onTap: () {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => FolderDetailsScreen(folderGroup: folder)));
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
                                        Container(
                                          color: Colors.white,
                                          padding: const EdgeInsets.all(6),
                                          child: folder.coverBytes != null
                                              ? Image.memory(folder.coverBytes!, fit: BoxFit.contain, filterQuality: FilterQuality.high)
                                              : const Center(child: Icon(Icons.folder_rounded, size: 54, color: Color(0xFFD4AF37))),
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
  String _searchQuery = '';
  SortOption _sortOption = SortOption.nameDesc;

  @override
  void initState() {
    super.initState();
    _loadFolderDesignsInBackground();
  }

  Future<void> _loadFolderDesignsInBackground() async {
    final List<String> paths = List<String>.from(widget.folderGroup.filePaths)
      ..sort((a, b) => compareNatural(
            b.split(Platform.pathSeparator).last,
            a.split(Platform.pathSeparator).last,
          ));

    final List<String> pendingPaths = [];
    for (final path in paths) {
      final cached = DesignCacheManager.getFromMemory(path);
      if (cached != null) {
        _designs.add(cached);
      } else {
        pendingPaths.add(path);
      }
    }
    if (_designs.isNotEmpty) {
      _applyFilterAndSort();
    }

    int count = 0;
    for (final path in pendingPaths) {
      if (!mounted) return;
      final EmbDesignInfo? info = await DesignCacheManager.getOrParse(path);
      if (info != null) {
        _designs.add(info);
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

  @override
  Widget build(BuildContext context) {
    final numFmt = intl.NumberFormat('#,###');
    return ValueListenableBuilder<bool>(
      valueListenable: isArabicNotifier,
      builder: (context, isAr, _) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF0E131D),
            title: Directionality(
              textDirection: TextDirection.ltr,
              child: Text(widget.folderGroup.folderName, style: const TextStyle(fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            actions: [
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
              Padding(
                padding: const EdgeInsets.all(12),
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
              if (_isLoading) const LinearProgressIndicator(color: Color(0xFFD4AF37)),
              Expanded(
                child: _filteredDesigns.isEmpty
                    ? Center(
                        child: Text(
                          _isLoading ? tr('جاري القراءة...', 'Loading...') : tr('لا يوجد تطابق', 'No match'),
                          style: const TextStyle(color: Colors.white70),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 0.70,
                        ),
                        itemCount: _filteredDesigns.length,
                        itemBuilder: (context, index) {
                          final item = _filteredDesigns[index];
                          return _DesignGridCard(
                            design: item,
                            formattedStitches: numFmt.format(item.stitches),
                            onTap: () async {
                              final exportedPath = await Navigator.push<String>(
                                context,
                                MaterialPageRoute(builder: (_) => DesignDetailScreen(design: item)),
                              );
                              if (exportedPath != null && exportedPath.isNotEmpty && mounted) {
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
        );
      },
    );
  }
}

class _DesignGridCard extends StatelessWidget {
  final EmbDesignInfo design;
  final String formattedStitches;
  final VoidCallback onTap;
  const _DesignGridCard({required this.design, required this.formattedStitches, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final dimCmText = formatDimensionsCm(design.widthMm, design.heightMm);
    final ext = design.filePath.split('.').last.toUpperCase();
    final hasPreview = design.previewJpeg != null;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF18202E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white10),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(6),
                child: hasPreview
                    ? Image.memory(design.previewJpeg!, fit: BoxFit.contain, filterQuality: FilterQuality.high)
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

  void _openFullScreenViewer() {
    if (widget.design.previewJpeg == null) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => FullScreenDesignViewer(design: widget.design)));
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
        outPath = '${tempDir.path}/$baseName.$chosenExt';
      } else {
        final parentDir = File(widget.design.filePath).parent.path;
        outPath = '$parentDir/$baseName.$chosenExt';
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
          // توليد معاينة التصميم للملف المُصدَّر فوراً ليظهر بصورته مباشرة في المجلد
          await DesignCacheManager.getOrParse(resultPath);
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
        final fullDimText = formatDimensionsCm(d.widthMm, d.heightMm, includeMm: true);
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
          body: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF18202E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: _openFullScreenViewer,
                      child: Stack(
                        children: [
                          Container(
                            height: 360,
                            width: double.infinity,
                            color: Colors.white,
                            child: d.previewJpeg != null
                                ? InteractiveViewer(
                                    minScale: 0.8,
                                    maxScale: 8.0,
                                    child: Center(
                                      child: Image.memory(
                                        d.previewJpeg!,
                                        fit: BoxFit.contain,
                                        filterQuality: FilterQuality.high,
                                        isAntiAlias: true,
                                      ),
                                    ),
                                  )
                                : Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        const Icon(Icons.architecture, size: 80, color: Color(0xFF3E522B)),
                                        const SizedBox(height: 12),
                                        Text('$ext Format', style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.bold, fontSize: 22)),
                                        const SizedBox(height: 4),
                                        Text(
                                          tr('صيغة تشغيل ماكينة (معلومات التصميم بالأسفل)', 'Machine Format (Design Specs Below)'),
                                          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                          if (d.previewJpeg != null)
                            Positioned(
                              bottom: 10,
                              left: 10,
                              child: Material(
                                color: const Color(0xFF0E131D).withOpacity(0.88),
                                borderRadius: BorderRadius.circular(20),
                                child: InkWell(
                                  onTap: _openFullScreenViewer,
                                  borderRadius: BorderRadius.circular(20),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.zoom_in, size: 18, color: Color(0xFFD4AF37)),
                                        const SizedBox(width: 4),
                                        Text(tr('تكبير بوضوح', 'HD Zoom'), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        children: [
                          Directionality(
                            textDirection: TextDirection.ltr,
                            child: Text(d.fileName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
                            child: Row(
                              children: [
                                const Icon(Icons.folder_open, size: 15, color: Color(0xFFD4AF37)),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Directionality(
                                    textDirection: TextDirection.ltr,
                                    child: SelectableText(d.filePath, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (fullDimText != null) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFF3E522B).withOpacity(0.45),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.greenAccent.withOpacity(0.4)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.straighten, size: 16, color: Colors.greenAccent),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      '${tr('المقاس', 'Size')}: $fullDimText',
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 16,
                            runSpacing: 10,
                            alignment: WrapAlignment.spaceAround,
                            children: [
                              if (d.stitches > 0) _StatBadge(label: tr('الغرز', 'Stitches'), value: numFmt.format(d.stitches), color: const Color(0xFF56CCF2)),
                              if (shortCmText != null) _StatBadge(label: tr('المقاس (سم)', 'Size (cm)'), value: shortCmText, color: Colors.lightGreenAccent),
                              _StatBadge(label: tr('الألوان', 'Colors'), value: '${d.colorCount}', color: const Color(0xFFD4AF37)),
                              if (d.sequinsCount > 0) _StatBadge(label: tr('الترتر', 'Sequins'), value: numFmt.format(d.sequinsCount), color: Colors.pinkAccent),
                              if (d.beadsCount > 0) _StatBadge(label: tr('الخرز', 'Beads'), value: numFmt.format(d.beadsCount), color: const Color(0xFFFFCA28)),
                              _StatBadge(label: tr('الماكينة', 'Machine'), value: d.machineType, color: Colors.purpleAccent),
                            ],
                          ),
                          if (VectorDesignLoader.supportsVectorView(d.filePath)) ...[
                            const SizedBox(height: 14),
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
                                    icon: const Icon(Icons.play_circle_outline, size: 19),
                                    label: Text(
                                      tr('محاكاة الغرز', 'Simulate'),
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF283852),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 11),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
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
                                    icon: const Icon(Icons.tune, size: 19),
                                    label: Text(
                                      tr('تعديل التصميم', 'Edit Design'),
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF3E522B),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 11),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (UniversalExporter.canExport(d.filePath)) ...[
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _isExportingDst ? null : () => _showFormatPickerAndExport(shareAfter: false),
                                    icon: _isExportingDst
                                        ? const SizedBox(
                                            width: 15,
                                            height: 15,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD4AF37)),
                                          )
                                        : const Icon(Icons.save_alt, size: 18, color: Color(0xFFD4AF37)),
                                    label: Text(
                                      tr('تصدير وحفظ', 'Export Only'),
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFD4AF37)),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Color(0xFFD4AF37), width: 1.3),
                                      padding: const EdgeInsets.symmetric(vertical: 11),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: _isExportingDst ? null : () => _showFormatPickerAndExport(shareAfter: true),
                                    icon: _isExportingDst
                                        ? const SizedBox(
                                            width: 15,
                                            height: 15,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                                          )
                                        : const Icon(Icons.ios_share, size: 18),
                                    label: Text(
                                      tr('تصدير ومشاركة', 'Export & Share'),
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
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
                        ],
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
    );
  }
}

class FullScreenDesignViewer extends StatefulWidget {
  final EmbDesignInfo design;
  const FullScreenDesignViewer({super.key, required this.design});
  @override
  State<FullScreenDesignViewer> createState() => _FullScreenDesignViewerState();
}

class _FullScreenDesignViewerState extends State<FullScreenDesignViewer> {
  final TransformationController _transformController = TransformationController();
  TapDownDetails? _doubleTapDetails;
  Color _canvasBg = Colors.white;
  bool _enhanceClarity = true;
  bool _is3D = false;
  double _currentScale = 1.0;
  Uint8List? _hdBytes;
  bool _loadingHd = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _transformController.addListener(() {
      final scale = _transformController.value.getMaxScaleOnAxis();
      if ((scale - _currentScale).abs() > 0.05) setState(() => _currentScale = scale);
    });
    _loadHdIfSupported();
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _transformController.dispose();
    super.dispose();
  }

  Future<void> _loadHdIfSupported() async {
    final lower = widget.design.filePath.toLowerCase();
    final isDst = lower.endsWith('.dst');
    final isDahao = lower.endsWith('.dhp') || lower.endsWith('.dha') || lower.endsWith('.dhe');
    final isUniversal = UniversalFormatParser.isSupported(lower);
    if (!isDst && !isDahao && !isUniversal) return;

    if (mounted) setState(() => _loadingHd = true);
    Uint8List? hd;
    try {
      if (isDst) {
        hd = await DstParser.renderHighResPreview(widget.design.filePath, maxCanvas: 2200.0, is3D: _is3D);
      } else if (isDahao) {
        hd = await DahaoParser.renderHighResPreview(widget.design.filePath, maxCanvas: 2200.0, is3D: _is3D);
      } else {
        hd = await UniversalFormatParser.renderHighResPreview(widget.design.filePath, maxCanvas: 2200.0, is3D: _is3D);
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        if (hd != null && hd.isNotEmpty) _hdBytes = hd;
        _loadingHd = false;
      });
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
    final displayBytes = _hdBytes ?? d.previewJpeg!;
    final imageWidget = Image.memory(
      displayBytes,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      isAntiAlias: true,
      gaplessPlayback: true,
    );
    return Scaffold(
      backgroundColor: _canvasBg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        foregroundColor: Colors.white,
        title: Directionality(textDirection: TextDirection.ltr, child: Text(d.fileName, style: const TextStyle(fontSize: 14))),
        actions: [
          if (_loadingHd)
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
          IconButton(onPressed: () => _transformController.value = Matrix4.identity(), icon: const Icon(Icons.fit_screen)),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onDoubleTapDown: (details) => _doubleTapDetails = details,
              onDoubleTap: _handleDoubleTap,
              child: InteractiveViewer(
                transformationController: _transformController,
                minScale: 0.5,
                maxScale: 12.0,
                boundaryMargin: const EdgeInsets.all(120),
                child: Center(
                  child: _enhanceClarity
                      ? ColorFiltered(
                          colorFilter: const ColorFilter.matrix([
                            1.28, -0.09, -0.09, 0, -14,
                            -0.09, 1.28, -0.09, 0, -14,
                            -0.09, -0.09, 1.28, 0, -14,
                            0, 0, 0, 1, 0,
                          ]),
                          child: imageWidget,
                        )
                      : imageWidget,
                ),
              ),
            ),
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
                      if (VectorDesignLoader.supportsVectorView(d.filePath)) ...[
                        TextButton.icon(
                          onPressed: _loadingHd
                              ? null
                              : () {
                                  setState(() => _is3D = !_is3D);
                                  _loadHdIfSupported();
                                },
                          style: TextButton.styleFrom(
                            backgroundColor: _is3D ? const Color(0xFFD4AF37).withOpacity(0.26) : Colors.white10,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          ),
                          icon: Icon(Icons.view_in_ar, size: 15, color: _is3D ? const Color(0xFFD4AF37) : Colors.white60),
                          label: Text(
                            '3D',
                            style: TextStyle(
                              color: _is3D ? const Color(0xFFD4AF37) : Colors.white60,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      TextButton.icon(
                        onPressed: () => setState(() => _enhanceClarity = !_enhanceClarity),
                        style: TextButton.styleFrom(
                          backgroundColor: _enhanceClarity ? const Color(0xFFD4AF37).withOpacity(0.22) : Colors.white10,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        ),
                        icon: Icon(Icons.auto_fix_high, size: 15, color: _enhanceClarity ? const Color(0xFFD4AF37) : Colors.white60),
                        label: Text(
                          tr('وضوح عالٍ', 'HD'),
                          style: TextStyle(color: _enhanceClarity ? const Color(0xFFD4AF37) : Colors.white60, fontSize: 12),
                        ),
                      ),
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
      children: [
        Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.white60)),
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
  final EmbDesignInfo design;
  const StitchSimulatorScreen({super.key, required this.design});
  @override
  State<StitchSimulatorScreen> createState() => _StitchSimulatorScreenState();
}

class _StitchSimulatorScreenState extends State<StitchSimulatorScreen> {
  VectorDesignData? _vec;
  bool _loading = true;
  bool _playing = false;
  int _currentStitch = 0;
  int _speedIndex = 1; // 0=1x, 1=3x, 2=8x, 3=20x
  static const List<int> _speedSteps = [8, 28, 90, 260];
  static const List<String> _speedLabels = ['1x', '3x', '8x', '20x'];
  Timer? _timer;

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

  Future<void> _loadVector() async {
    final v = await VectorDesignLoader.load(widget.design.filePath);
    if (!mounted) return;
    setState(() {
      _vec = v;
      _loading = false;
      _currentStitch = 0;
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
    _timer = Timer.periodic(const Duration(milliseconds: 30), (_) {
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
    return Scaffold(
      backgroundColor: const Color(0xFF0E131D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: Text(tr('محاكاة سير الغرز', 'Stitch Simulator'), style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 16)),
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
                        child: InteractiveViewer(
                          minScale: 0.8,
                          maxScale: 8.0,
                          child: CustomPaint(
                            painter: _VectorStitchPainter(data: _vec!, limit: _currentStitch, showNeedle: true),
                            size: Size.infinite,
                          ),
                        ),
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, MediaQuery.of(context).padding.bottom + 14),
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
                                style: const TextStyle(color: Color(0xFF56CCF2), fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                              Text(
                                '${((_currentStitch / max(1, total)) * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 13),
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
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              IconButton(
                                onPressed: () {
                                  _pausePlayback();
                                  setState(() => _currentStitch = 0);
                                },
                                icon: const Icon(Icons.replay, color: Colors.white70),
                                tooltip: tr('إعادة', 'Reset'),
                              ),
                              ElevatedButton.icon(
                                onPressed: _playing ? _pausePlayback : _startPlayback,
                                icon: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 24),
                                label: Text(_playing ? tr('إيقاف', 'Pause') : tr('تشغيل', 'Play')),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFD4AF37),
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  setState(() => _speedIndex = (_speedIndex + 1) % _speedSteps.length);
                                },
                                style: TextButton.styleFrom(
                                  backgroundColor: Colors.white10,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                ),
                                child: Text(
                                  '${tr('السرعة', 'Speed')}: ${_speedLabels[_speedIndex]}',
                                  style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold),
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

/// شاشة تعديل التصميم (تكبير/تصغير، دوران، قلب، حذف لون، حذف غرز، وحفظ)
class DesignEditorScreen extends StatefulWidget {
  final EmbDesignInfo design;
  const DesignEditorScreen({super.key, required this.design});
  @override
  State<DesignEditorScreen> createState() => _DesignEditorScreenState();
}

class _DesignEditorScreenState extends State<DesignEditorScreen> {
  VectorDesignData? _original;
  VectorDesignData? _edited;
  bool _loading = true;
  bool _saving = false;

  double _scale = 1.0;
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

  Future<void> _load() async {
    final v = await VectorDesignLoader.load(widget.design.filePath);
    if (!mounted) return;
    if (v != null) {
      final Set<int> cols = {};
      for (int i = 0; i < v.stColor.length; i++) {
        cols.add(v.stColor[i]);
      }
      final sortedCols = cols.toList()..sort();
      setState(() {
        _original = v;
        _edited = v;
        _availableColors = sortedCols;
        _trimStart = 0;
        _trimEnd = v.stX.length;
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  void _rebuildEdited() {
    if (_original == null) return;
    final next = VectorDesignEditor.transform(
      _original!,
      scale: _scale,
      rotationDeg: _rotationDeg,
      flipH: _flipH,
      flipV: _flipV,
      deletedColors: _deletedColors,
      trimStart: _trimStart,
      trimEnd: _trimEnd,
    );
    setState(() => _edited = next);
  }

  Future<void> _saveEdited() async {
    if (_edited == null || _saving) return;
    final origExt = widget.design.filePath.split('.').last.toUpperCase();
    final targetExt = UniversalExporter.supportedFormats.any((f) => f['ext'] == origExt) ? origExt : 'DST';

    setState(() => _saving = true);
    try {
      final baseName = '${widget.design.fileName.replaceAll(RegExp(r'\.[^.]+$'), '')}_edit';
      final parentDir = File(widget.design.filePath).parent.path;
      String outPath = '$parentDir/$baseName.$targetExt';
      String? res = await VectorDesignEditor.exportVectorToFile(_edited!, outPath, targetExt, baseName: baseName);
      res ??= await VectorDesignEditor.exportVectorToFile(
        _edited!,
        '/storage/emulated/0/Download/$baseName.$targetExt',
        targetExt,
        baseName: baseName,
      );
      if (res != null && await File(res).exists()) {
        await DesignCacheManager.getOrParse(res);
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
    final dimText = formatDimensionsCm(_edited?.widthMm, _edited?.heightMm);
    return Scaffold(
      backgroundColor: const Color(0xFF0E131D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: Text(tr('تعديل التصميم', 'Edit Design'), style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 16)),
        actions: [
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
                        child: InteractiveViewer(
                          minScale: 0.8,
                          maxScale: 8.0,
                          child: CustomPaint(
                            painter: _VectorStitchPainter(data: _edited!, limit: _edited!.stX.length, showNeedle: false),
                            size: Size.infinite,
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
                                '${tr('الحجم', 'Scale')}: ${(_scale * 100).round()}%${dimText != null ? '  ($dimText)' : ''}',
                                style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                              Text(
                                '${tr('الغرز', 'Stitches')}: ${_edited!.stitches}',
                                style: const TextStyle(color: Color(0xFF56CCF2), fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                            ],
                          ),
                          Slider(
                            value: _scale,
                            min: 0.5,
                            max: 2.0,
                            divisions: 30,
                            activeColor: const Color(0xFFD4AF37),
                            onChanged: (v) {
                              _scale = v;
                              _rebuildEdited();
                            },
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () {
                                  _rotationDeg = (_rotationDeg + 90) % 360;
                                  _rebuildEdited();
                                },
                                icon: const Icon(Icons.rotate_right, size: 17, color: Color(0xFFD4AF37)),
                                label: Text('${_rotationDeg.round()}°', style: const TextStyle(color: Colors.white, fontSize: 12)),
                                style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24)),
                              ),
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
                                      _rebuildEdited();
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
                                _rebuildEdited();
                              }
                            },
                          ),
                        ],
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

  _VectorStitchPainter({required this.data, required this.limit, required this.showNeedle});

  @override
  void paint(Canvas canvas, Size size) {
    if (!data.hasBounds || data.stX.length < 2) return;
    final double rawW = data.maxX - data.minX;
    final double rawH = data.maxY - data.minY;
    if (rawW <= 0 || rawH <= 0) return;

    const double pad = 18.0;
    final double scale = min((size.width - pad * 2) / rawW, (size.height - pad * 2) / rawH);
    final double offX = (size.width - rawW * scale) * 0.5 - data.minX * scale;
    final double offY = (size.height - rawH * scale) * 0.5 - data.minY * scale;

    final int count = limit.clamp(0, data.stX.length);
    final int palLen = data.paletteArgb.length;
    Path path = Path();
    int activeColor = -1;
    bool hasMove = false;
    double lastX = 0, lastY = 0;

    void flush() {
      if (!hasMove || activeColor < 0) return;
      final paint = Paint()
        ..color = Color(data.paletteArgb[activeColor % palLen])
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      canvas.drawPath(path, paint);
      path = Path();
      hasMove = false;
    }

    for (int i = 0; i < count; i++) {
      final int c = data.stColor[i];
      if (c != activeColor) {
        flush();
        activeColor = c;
      }
      final double sx = data.stX[i] * scale + offX;
      final double sy = data.stY[i] * scale + offY;
      lastX = sx;
      lastY = sy;
      if (data.stMove[i] != 0 || !hasMove) {
        path.moveTo(sx, sy);
        hasMove = true;
      } else {
        path.lineTo(sx, sy);
      }
    }
    flush();

    if (showNeedle && count > 0) {
      canvas.drawCircle(Offset(lastX, lastY), 7.5, Paint()..color = const Color(0xFFD4AF37).withOpacity(0.35));
      canvas.drawCircle(Offset(lastX, lastY), 3.8, Paint()..color = Colors.redAccent);
    }
  }

  @override
  bool shouldRepaint(covariant _VectorStitchPainter oldDelegate) {
    return oldDelegate.limit != limit || oldDelegate.data != data;
  }
}


/// شاشة الكتابة بالعربي والإنجليزي وتحويلها مباشرة إلى غرز تطريز (.DST / .EXP / .XXX ...)
class TextToEmbroideryScreen extends StatefulWidget {
  const TextToEmbroideryScreen({super.key});
  @override
  State<TextToEmbroideryScreen> createState() => _TextToEmbroideryScreenState();
}

class _TextToEmbroideryScreenState extends State<TextToEmbroideryScreen> {
  final TextEditingController _textCtrl = TextEditingController(text: 'Tarik emb');
  VectorDesignData? _vec;
  bool _generating = false;
  bool _saving = false;
  double _widthCm = 12.0;
  double _densityMm = 0.45;
  int _selectedColor = 0xFFFF1744;

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
    _generate();
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_textCtrl.text.trim().isEmpty) return;
    setState(() => _generating = true);
    try {
      final v = await TextToStitchEngine.generateFromText(
        text: _textCtrl.text,
        widthCm: _widthCm,
        densityMm: _densityMm,
        colorArgb: _selectedColor,
      );
      if (mounted) {
        setState(() {
          _vec = v;
          _generating = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _exportText({required bool shareAfter}) async {
    if (_vec == null || _saving) return;
    setState(() => _saving = true);
    try {
      final safeName = 'text_${DateTime.now().millisecondsSinceEpoch}';
      final String outPath = shareAfter
          ? '${(await getTemporaryDirectory()).path}/$safeName.DST'
          : '/storage/emulated/0/Download/$safeName.DST';

      final res = await VectorDesignEditor.exportVectorToFile(
        _vec!,
        outPath,
        'DST',
        baseName: safeName,
      );
      if (res != null && await File(res).exists()) {
        if (shareAfter) {
          await Share.shareXFiles([XFile(res)], text: '$safeName.DST');
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${tr('تم حفظ ملف التطريز في:', 'Saved embroidery file to:')}\n$res'),
              backgroundColor: const Color(0xFF2E7D32),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dimText = formatDimensionsCm(_vec?.widthMm, _vec?.heightMm);
    return Scaffold(
      backgroundColor: const Color(0xFF0E131D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: Text(tr('الكتابة وتحويلها لغرز', 'Text to Stitches'), style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 16)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: tr('اكتب نصاً بالعربي أو الإنجليزي...', 'Type Arabic or English text...'),
                      filled: true,
                      fillColor: const Color(0xFF18202E),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onSubmitted: (_) => _generate(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _generating ? null : _generate,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD4AF37),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(tr('توليد', 'Create'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
              clipBehavior: Clip.antiAlias,
              child: _generating
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFD4AF37)))
                  : (_vec == null
                      ? Center(child: Text(tr('اكتب نصاً واضغط توليد', 'Enter text and tap Create'), style: const TextStyle(color: Colors.black54)))
                      : InteractiveViewer(
                          minScale: 0.8,
                          maxScale: 8.0,
                          child: CustomPaint(
                            painter: _VectorStitchPainter(data: _vec!, limit: _vec!.stX.length, showNeedle: false),
                            size: Size.infinite,
                          ),
                        )),
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
                      '${tr('العرض', 'Width')}: ${_widthCm.toStringAsFixed(1)} ${tr('سم', 'cm')}${dimText != null ? '  ($dimText)' : ''}',
                      style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    Text(
                      '${tr('الغرز', 'Stitches')}: ${_vec?.stitches ?? 0}',
                      style: const TextStyle(color: Color(0xFF56CCF2), fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ],
                ),
                Slider(
                  value: _widthCm,
                  min: 4.0,
                  max: 30.0,
                  divisions: 26,
                  activeColor: const Color(0xFFD4AF37),
                  onChanged: (v) => setState(() => _widthCm = v),
                  onChangeEnd: (_) => _generate(),
                ),
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
                            width: 26,
                            height: 26,
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
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _saving || _vec == null ? null : () => _exportText(shareAfter: false),
                        icon: const Icon(Icons.save_alt, size: 18, color: Color(0xFFD4AF37)),
                        label: Text(tr('حفظ DST', 'Save DST'), style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFFD4AF37)),
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _saving || _vec == null ? null : () => _exportText(shareAfter: true),
                        icon: const Icon(Icons.ios_share, size: 18),
                        label: Text(tr('مشاركة DST', 'Share DST'), style: const TextStyle(fontWeight: FontWeight.bold)),
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
        ],
      ),
    );
  }
}
