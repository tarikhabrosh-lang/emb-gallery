import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' as intl;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'parsers/emb_parser.dart'; // هذا السطر الآن يجلب كل شيء (EMB + DST)

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final ValueNotifier<bool> isArabicNotifier = ValueNotifier<bool>(true);

String tr(String ar, String en) => isArabicNotifier.value ? ar : en;
final validExtensions = ['.emb', '.dst', '.pes', '.pec', '.exp', '.ef', '.vp3', '.xxx', '.u01'];

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
  static Future> checkLicense() async {
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
      if (parts.length != 3) return {'valid': false, 'activated': false, 'id': 'Error', 'days': 0};
      
      final installTime = int.tryParse(parts[0]) ?? 0;
      final activated = parts[1] == 'true';
      final id = parts[2];
      
      if (activated) return {'valid': true, 'activated': true, 'id': id, 'days': 0};
      
      final now = DateTime.now().millisecondsSinceEpoch;
      final diff = now - installTime;
      final daysPassed = diff / (1000 * 60 * 60 * 24);
      final remaining = 7 - daysPassed.floor();
      
      if (remaining > 0) return {'valid': true, 'activated': false, 'id': id, 'days': remaining};
      return {'valid': false, 'activated': false, 'id': id, 'days': 0};
    } catch (e) { return {'valid': true, 'activated': false, 'id': '123456', 'days': 7}; }
  }

  static Future<bool> activate(String deviceId, String enteredCode) async {
    try {
      final idNum = int.tryParse(deviceId) ?? 0;
      final expectedCode = (idNum * 7) + 2026;
      if (enteredCode.trim() == expectedCode.toString()) {
        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/tarik_license.txt');
        final data = await file.readAsString();
        final parts = data.split('|');
        await file.writeAsString('${parts[0]}|true|${parts[2]}');
        return true;
      }
      return false;
    } catch (_) { return false; }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final license = await LicenseManager.checkLicense();
  runApp(EmbGalleryApp(license: license));
}

class EmbGalleryApp extends StatefulWidget {
  final Map<String, dynamic> license;
  const EmbGalleryApp({super.key, required this.license});
  @override
  State<EmbGalleryApp> createState() => _EmbGalleryAppState();
}

class _EmbGalleryAppState extends State<EmbGalleryApp> {
  static const MethodChannel _intentChannel = MethodChannel('tarik_emb/file_intent');

  @override
  void initState() {
    super.initState();
    _loadLanguagePreference();
    if (widget.license['valid']) _setupIncomingFileHandler();
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

  Future<void> _setupIncomingFileHandler() async {
    _intentChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFileOpened' && call.arguments is String) await _openIncomingEmbFile(call.arguments as String);
    });
    try {
      final initialPath = await _intentChannel.invokeMethod<String>('getInitialFile');
      if (initialPath != null && initialPath.isNotEmpty) await _openIncomingEmbFile(initialPath);
    } catch (_) {}
  }

  Future<void> _openIncomingEmbFile(String path) async {
    final lower = path.toLowerCase();
    EmbDesignInfo? info;
    if (lower.endsWith('.dst')) {
      info = await DstParser.parseFile(path);
    } else if (lower.endsWith('.emb')) {
      info = await EmbParser.parseFile(path);
    } else {
      final name = path.split(Platform.pathSeparator).last;
      info = EmbDesignInfo(filePath: path, fileName: name, stitches: 0, colorCount: 0, jumpsCount: 0, sequinsCount: 0, machineType: 'Other', colorSequence: []);
    }
    
    if (info == null) return;
    Future.delayed(const Duration(milliseconds: 250), () {
      rootNavigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => DesignDetailScreen(design: info!)));
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isArabicNotifier,
      builder: (context, isAr, _) {
        return MaterialApp(
          navigatorKey: rootNavigatorKey, title: 'Tarik emb', debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFD4AF37), brightness: Brightness.dark), scaffoldBackgroundColor: const Color(0xFF0E131D), cardColor: const Color(0xFF18202E)),
          builder: (context, child) => Directionality(textDirection: isAr ? TextDirection.rtl : TextDirection.ltr, child: child!),
          home: widget.license['valid'] ? FoldersGalleryPage(license: widget.license) : ActivationScreen(deviceId: widget.license['id'], isExpired: true),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('تم تفعيل البرنامج بنجاح! أعد تشغيل التطبيق.', 'App activated successfully! Restart app.')), backgroundColor: Colors.green));
        Future.delayed(const Duration(seconds: 2), () => exit(0));
      }
    } else {
      setState(() => _isError = true);
    }
  }

  void _openWhatsApp() async {
    final msg = tr('مرحباً، أود شراء تفعيل لتطبيق Tarik emb. رقم جهازي هو: ', 'Hello, I want to buy activation for Tarik emb. My Device ID is: ') + widget.deviceId;
    final url = Uri.parse("https://wa.me/963956739715?text=${Uri.encodeComponent(msg)}");
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
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
            decoration: BoxDecoration(color: const Color(0xFF18202E), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFD4AF37))),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.isExpired ? Icons.lock : Icons.lock_open, size: 64, color: const Color(0xFFD4AF37)),
                const SizedBox(height: 16),
                Text(
                  widget.isExpired ? tr('انتهت الفترة التجريبية', 'Trial Period Expired') : tr('تفعيل النسخة الدائمة', 'Activate Full Version'), 
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)
                ),
                const SizedBox(height: 8),
                Text(
                  tr('لتفعيل النسخة الدائمة، أرسل هذا الكود إلى مزود الخدمة على الواتساب:', 'To activate the full version, send this code to the provider on WhatsApp:'), 
                  textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)
                ),
                const SizedBox(height: 16),
                SelectableText(widget.deviceId, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFF56CCF2), letterSpacing: 2)),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _openWhatsApp,
                  icon: const Icon(Icons.chat, size: 20),
                  label: Text(tr('تواصل عبر واتساب (+963956739715)', 'Contact via WhatsApp (+963956739715)')),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF25D366), foregroundColor: Colors.white),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _codeController, keyboardType: TextInputType.number, textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20, letterSpacing: 4),
                  decoration: InputDecoration(hintText: tr('أدخل كود التفعيل هنا', 'Enter Activation Code'), filled: true, fillColor: Colors.black26, errorText: _isError ? tr('الكود غير صحيح', 'Invalid Code') : null, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _verify,
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD4AF37), foregroundColor: Colors.black, minimumSize: const Size.fromHeight(50)),
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
  bool _isScanning = false;
  String _statusText = '';
  final List<EmbFolderGroup> _folders = [];
  int _scanToken = 0;

  int get _totalFilesCount => _folders.fold(0, (sum, folder) => sum + folder.filePaths.length);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.license['activated']) _showTrialToast();
      _showSignatureDialog();
      _startBackgroundScan();
    });
  }

  void _showTrialToast() {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('نسخة تجريبية - متبقي', 'Trial - Remaining')} ${widget.license['days']} ${tr('أيام', 'days')}'), backgroundColor: const Color(0xFFD4AF37), duration: const Duration(seconds: 4)));
  }

  void _showSignatureDialog() {
    showDialog(
      context: context, barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF18202E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFFD4AF37), width: 1.5)),
        content: const Column(mainAxisSize: MainAxisSize.min, children: [SizedBox(height: 8), Text('By Tarik Habrosh', style: TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 18, letterSpacing: 1.2)), SizedBox(height: 8)]),
        actions: [Center(child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3E522B), foregroundColor: Colors.white), onPressed: () => Navigator.pop(ctx), child: Text(tr('موافق', 'OK'))))],
      ),
    );
  }

  Future<List<String>> _readSavedFolders() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/saved_emb_folders.txt');
      if (await f.exists()) return (await f.readAsLines()).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    } catch (_) {}
    return [];
  }

  Future<void> _saveFolderToHistory(String folderPath) async {
    try {
      final current = await _readSavedFolders();
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
    if (await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted) return true;
    final manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) return true;
    return (await Permission.storage.request()).isGranted;
  }

  Future<void> _startBackgroundScan() async {
    final int currentToken = ++_scanToken;
    final hasPerm = await _ensureStoragePermission();
    if (!hasPerm) {
      if (!mounted) return;
      setState(() { _isScanning = false; _statusText = tr('يرجى منح إذن الملفات', 'Please grant file permission'); });
      return;
    }
    if (!mounted) return;
    setState(() { _isScanning = true; _folders.clear(); _statusText = tr('جاري البحث عن المجلدات...', 'Scanning folders...'); });

    final savedDirs = await _readSavedFolders();
    final candidateDirs = <String>{
      ...savedDirs, '/storage/emulated/0/Download', '/storage/emulated/0/Documents',
      '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Documents',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Documents', '/storage/emulated/0/Telegram/Telegram Documents',
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
    _loadFolderCoversInBackground(currentToken);
  }

  void _rebuildFoldersList(Map<String, List<String>> folderMap) {
    if (!mounted) return;
    final list = <EmbFolderGroup>[];
    folderMap.forEach((path, files) {
      if (files.isNotEmpty) {
        final name = path.split(Platform.pathSeparator).last;
        list.add(EmbFolderGroup(folderPath: path, folderName: name.isEmpty ? path : name, filePaths: files));
      }
    });
    setState(() { _folders..clear()..addAll(list); });
  }

  Future<void> _loadFolderCoversInBackground(int token) async {
    for (final folder in _folders) {
      if (!mounted || token != _scanToken) return;
      if (folder.coverBytes == null && folder.filePaths.isNotEmpty) {
        for (final p in folder.filePaths) {
          if (p.toLowerCase().endsWith('.emb')) {
            final info = await EmbParser.parseFile(p);
            if (info?.previewJpeg != null && mounted && token == _scanToken) {
              setState(() { folder.coverBytes = info!.previewJpeg; });
              break;
            }
          } else if (p.toLowerCase().endsWith('.dst')) {
            final info = await DstParser.parseFile(p);
            if (info?.previewJpeg != null && mounted && token == _scanToken) {
              setState(() { folder.coverBytes = info!.previewJpeg; });
              break;
            }
          }
        }
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  Future<void> _pickSingleOrMultipleFiles() async {
    _scanToken++;
    setState(() => _isScanning = false);
    try {
      await _ensureStoragePermission();
      final result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
      if (result == null || result.paths.isEmpty) return;
      
      final validPaths = result.paths.whereType<String>().where((p) {
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
        final p = validPaths.first;
        final lower = p.toLowerCase();
        EmbDesignInfo? info;
        if (lower.endsWith('.dst')) info = await DstParser.parseFile(p);
        else if (lower.endsWith('.emb')) info = await EmbParser.parseFile(p);
        else info = EmbDesignInfo(filePath: p, fileName: p.split(Platform.pathSeparator).last, stitches: 0, colorCount: 0, jumpsCount: 0, sequinsCount: 0, machineType: 'Other', colorSequence: []);
        
        if (info != null && mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => DesignDetailScreen(design: info!)));
      } else {
        final group = EmbFolderGroup(folderPath: firstParent, folderName: tr('ملفات مختارة', 'Selected Files'), filePaths: validPaths);
        if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => FolderDetailsScreen(folderGroup: group)));
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

      setState(() { _isScanning = true; _statusText = tr('جاري القراءة...', 'Reading...'); });

      final files = <String>[];
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
      final folderName = dirPath.split(Platform.pathSeparator).last;
      final newGroup = EmbFolderGroup(folderPath: dirPath, folderName: folderName.isEmpty ? dirPath : folderName, filePaths: files);
      setState(() { _folders.removeWhere((f) => f.folderPath == dirPath); _folders.insert(0, newGroup); });
      if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => FolderDetailsScreen(folderGroup: newGroup)));
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
            title: Row(
              children: [
                const Text('Tarik emb', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFD4AF37), letterSpacing: 0.6)),
                const SizedBox(width: 8),
                Expanded(child: Text(tr('| استوديو المجلدات', '| Folders Studio'), style: const TextStyle(fontSize: 14, color: Colors.white70), overflow: TextOverflow.ellipsis)),
              ],
            ),
            actions: [
              if (!widget.license['activated'])
                IconButton(
                  icon: const Icon(Icons.lock_open, color: Colors.greenAccent),
                  tooltip: tr('تفعيل النسخة', 'Activate App'),
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => ActivationScreen(deviceId: widget.license['id'], isExpired: false)));
                  },
                ),
              TextButton.icon(
                onPressed: () async { await _EmbGalleryAppState.toggleLanguage(); setState(() {}); },
                icon: const Icon(Icons.language, color: Color(0xFFD4AF37), size: 18),
                label: Text(isAr ? 'EN' : 'عربي', style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold)),
              ),
              IconButton(icon: const Icon(Icons.refresh, color: Color(0xFFD4AF37)), tooltip: tr('تحديث', 'Refresh'), onPressed: _startBackgroundScan),
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
                        style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12), backgroundColor: const Color(0xFF3E522B), foregroundColor: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickCustomFolder,
                        icon: const Icon(Icons.create_new_folder, color: Color(0xFFD4AF37)),
                        label: Text(tr('إضافة مجلد', 'Add Folder'), style: const TextStyle(color: Color(0xFFD4AF37))),
                        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12), side: const BorderSide(color: Color(0xFFD4AF37))),
                      ),
                    ),
                  ],
                ),
              ),
              if (_folders.isNotEmpty)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(color: const Color(0xFF18202E), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white10)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(children: [
                        const Icon(Icons.folder_special, size: 18, color: Color(0xFFD4AF37)),
                        const SizedBox(width: 6),
                        Text('${tr('المجلدات', 'Folders')}: ${_folders.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                      ]),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(color: const Color(0xFF3E522B), borderRadius: BorderRadius.circular(12)),
                        child: Text('${tr('الكل', 'Total')}: $_totalFilesCount', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
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
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 0.84),
                        itemCount: _folders.length,
                        itemBuilder: (context, index) {
                          final folder = _folders[index];
                          return GestureDetector(
                            onTap: () { Navigator.push(context, MaterialPageRoute(builder: (_) => FolderDetailsScreen(folderGroup: folder))); },
                            child: Container(
                              decoration: BoxDecoration(color: const Color(0xFF18202E), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white12)),
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Container(
                                          color: Colors.white, padding: const EdgeInsets.all(6),
                                          child: folder.coverBytes != null ? Image.memory(folder.coverBytes!, fit: BoxFit.contain, filterQuality: FilterQuality.high) : const Center(child: Icon(Icons.folder_rounded, size: 54, color: Color(0xFFD4AF37))),
                                        ),
                                        Positioned(
                                          top: 8, left: 8,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                            decoration: BoxDecoration(color: const Color(0xFF0E131D).withOpacity(0.88), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFD4AF37), width: 1)),
                                            child: Text('${folder.filePaths.length} ${tr('ملف', 'files')}', style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12)),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(Icons.folder, size: 16, color: Color(0xFFD4AF37)),
                                            const SizedBox(width: 6),
                                            Expanded(child: Directionality(textDirection: TextDirection.ltr, child: Text(folder.folderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white)))),
                                          ],
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

enum SortOption { nameAsc, stitchesDesc, stitchesAsc, colorsDesc }

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
  SortOption _sortOption = SortOption.nameAsc;

  @override
  void initState() {
    super.initState();
    _loadFolderDesignsInBackground();
  }

  Future<void> _loadFolderDesignsInBackground() async {
    int count = 0;
    for (final path in widget.folderGroup.filePaths) {
      if (!mounted) return;
      final lower = path.toLowerCase();
      EmbDesignInfo? info;
      if (lower.endsWith('.dst')) info = await DstParser.parseFile(path);
      else if (lower.endsWith('.emb')) info = await EmbParser.parseFile(path);
      else info = EmbDesignInfo(filePath: path, fileName: path.split(Platform.pathSeparator).last, stitches: 0, colorCount: 0, jumpsCount: 0, sequinsCount: 0, machineType: 'Other', colorSequence: []);
      
      if (info != null) {
        _designs.add(info);
        count++;
        if (count % 4 == 0 || count == widget.folderGroup.filePaths.length) _applyFilterAndSort();
      }
      await Future.delayed(const Duration(milliseconds: 5));
    }
    if (mounted) {
      setState(() => _isLoading = false);
      _applyFilterAndSort();
    }
  }

  void _applyFilterAndSort() {
    if (!mounted) return;
    final q = _searchQuery.trim().toLowerCase();
    final list = _designs.where((d) => q.isEmpty || d.fileName.toLowerCase().contains(q)).toList();
    switch (_sortOption) {
      case SortOption.nameAsc: list.sort((a, b) => a.fileName.compareTo(b.fileName)); break;
      case SortOption.stitchesDesc: list.sort((a, b) => b.stitches.compareTo(a.stitches)); break;
      case SortOption.stitchesAsc: list.sort((a, b) => a.stitches.compareTo(b.stitches)); break;
      case SortOption.colorsDesc: list.sort((a, b) => b.colorCount.compareTo(a.colorCount)); break;
    }
    setState(() { _filteredDesigns = list; });
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
            title: Row(
              children: [
                Expanded(child: Directionality(textDirection: TextDirection.ltr, child: Text(widget.folderGroup.folderName, style: const TextStyle(fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis))),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: const Color(0xFFD4AF37).withOpacity(0.2), borderRadius: BorderRadius.circular(10)),
                  child: Text('${widget.folderGroup.filePaths.length} ${tr('ملف', 'files')}', style: const TextStyle(fontSize: 12, color: Color(0xFFD4AF37), fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () async { await _EmbGalleryAppState.toggleLanguage(); setState(() {}); }, child: Text(isAr ? 'EN' : 'عربي', style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold))),
              PopupMenuButton<SortOption>(
                icon: const Icon(Icons.sort), tooltip: tr('ترتيب', 'Sort'), onSelected: (opt) { _sortOption = opt; _applyFilterAndSort(); },
                itemBuilder: (_) => [
                  PopupMenuItem(value: SortOption.nameAsc, child: Text(tr('الاسم (أ - ي)', 'Name (A - Z)'))),
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
                width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), color: const Color(0xFF18202E),
                child: Directionality(textDirection: TextDirection.ltr, child: Text('📁 ${widget.folderGroup.folderPath}', style: const TextStyle(fontSize: 11, color: Colors.white60), maxLines: 1, overflow: TextOverflow.ellipsis)),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: tr('بحث...', 'Search...'), prefixIcon: const Icon(Icons.search), filled: true, fillColor: const Color(0xFF18202E),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                  onChanged: (val) { _searchQuery = val; _applyFilterAndSort(); },
                ),
              ),
              if (_isLoading) const LinearProgressIndicator(color: Color(0xFFD4AF37)),
              Expanded(
                child: _filteredDesigns.isEmpty
                    ? Center(child: Text(_isLoading ? tr('جاري القراءة...', 'Loading...') : tr('لا يوجد تطابق', 'No match'), style: const TextStyle(color: Colors.white70)))
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 0.70),
                        itemCount: _filteredDesigns.length,
                        itemBuilder: (context, index) {
                          final item = _filteredDesigns[index];
                          return _DesignGridCard(
                            design: item,
                            formattedStitches: numFmt.format(item.stitches),
                            onTap: () { Navigator.push(context, MaterialPageRoute(builder: (_) => DesignDetailScreen(design: item))); },
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
        decoration: BoxDecoration(color: const Color(0xFF18202E), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white10)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: Colors.white, padding: const EdgeInsets.all(6),
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
                  Directionality(textDirection: TextDirection.ltr, child: Text(design.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
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
  final GlobalKey _shareCardKey = GlobalKey();
  bool _isSharing = false;

  void _openFullScreenViewer() {
    if (widget.design.previewJpeg == null) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => FullScreenDesignViewer(design: widget.design)));
  }

  Future<void> _shareDesignCard({bool includeEmbFile = false}) async {
    if (_isSharing) return;
    setState(() => _isSharing = true);
    try {
      final boundary = _shareCardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final tempDir = await getTemporaryDirectory();
      final outFile = File('${tempDir.path}/tarik_emb_${DateTime.now().millisecondsSinceEpoch}.png');
      await outFile.writeAsBytes(byteData.buffer.asUint8List());

      final filesToShare = <XFile>[XFile(outFile.path)];
      if (includeEmbFile && await File(widget.design.filePath).exists()) filesToShare.add(XFile(widget.design.filePath));

      final numFmt = intl.NumberFormat('#,###');
      final dimStr = formatDimensionsCm(widget.design.widthMm, widget.design.heightMm, includeMm: true);
      final dimLine = dimStr != null ? '\n${tr('المقاس', 'Size')}: $dimStr' : '';
      final seqText = widget.design.sequinsCount > 0 ? '\n${tr('عدد الترتر', 'Sequins')}: ${numFmt.format(widget.design.sequinsCount)}' : '';

      await Share.shareXFiles(filesToShare, text: '${tr('موديل', 'Design')}: ${widget.design.fileName}$dimLine\n${tr('عدد الغرز', 'Stitches')}: ${numFmt.format(widget.design.stitches)}\n${tr('عدد الألوان', 'Colors')}: ${widget.design.colorCount}\n${tr('عدد المراحل', 'Stops')}: ${widget.design.actualStopsCount}$seqText');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('تعذرت المشاركة', 'Share failed')}: $e')));
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

        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF0E131D),
            title: Directionality(textDirection: TextDirection.ltr, child: Text(d.fileName, style: const TextStyle(fontSize: 15))),
            actions: [
              TextButton(onPressed: () async { await _EmbGalleryAppState.toggleLanguage(); setState(() {}); }, child: Text(isAr ? 'EN' : 'عربي', style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold))),
              if (d.previewJpeg != null) IconButton(icon: const Icon(Icons.fullscreen, color: Color(0xFFD4AF37)), tooltip: tr('تكبير بملء الشاشة', 'Full Screen Zoom'), onPressed: _openFullScreenViewer),
              PopupMenuButton<String>(
                icon: _isSharing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.share),
                tooltip: tr('مشاركة', 'Share'),
                onSelected: (val) { if (val == 'image') _shareDesignCard(includeEmbFile: false); else if (val == 'both') _shareDesignCard(includeEmbFile: true); },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'image', child: Text(tr('مشاركة صورة المعاينة', 'Share Preview Image'))),
                  PopupMenuItem(value: 'both', child: Text(tr('مشاركة الصورة + الملف', 'Share Image + File'))),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              RepaintBoundary(
                key: _shareCardKey,
                child: Container(
                  decoration: BoxDecoration(color: const Color(0xFF18202E), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white12)),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      GestureDetector(
                        onTap: _openFullScreenViewer,
                        child: Stack(
                          children: [
                            Container(
                              height: 360, width: double.infinity, color: Colors.white,
                              child: d.previewJpeg != null
                                  ? InteractiveViewer(minScale: 0.8, maxScale: 8.0, child: Center(child: Image.memory(d.previewJpeg!, fit: BoxFit.contain, filterQuality: FilterQuality.high, isAntiAlias: true)))
                                  : Center(
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          const Icon(Icons.architecture, size: 80, color: Color(0xFF3E522B)),
                                          const SizedBox(height: 12),
                                          Text('$ext Format', style: TextStyle(color: Colors.grey.shade800, fontWeight: FontWeight.bold, fontSize: 22)),
                                          const SizedBox(height: 4),
                                          Text(tr('صيغة غير مدعومة للرسم بعد', 'Format rendering not supported yet'), style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                                        ],
                                      ),
                                    ),
                            ),
                            if (d.previewJpeg != null)
                              Positioned(
                                bottom: 10, left: 10,
                                child: Material(
                                  color: const Color(0xFF0E131D).withOpacity(0.88), borderRadius: BorderRadius.circular(20),
                                  child: InkWell(
                                    onTap: _openFullScreenViewer, borderRadius: BorderRadius.circular(20),
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
                            Directionality(textDirection: TextDirection.ltr, child: Text(d.fileName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
                              child: Row(
                                children: [
                                  const Icon(Icons.folder_open, size: 15, color: Color(0xFFD4AF37)),
                                  const SizedBox(width: 6),
                                  Expanded(child: Directionality(textDirection: TextDirection.ltr, child: SelectableText(d.filePath, style: const TextStyle(color: Colors.white70, fontSize: 11)))),
                                ],
                              ),
                            ),
                            if (fullDimText != null) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(color: const Color(0xFF3E522B).withOpacity(0.45), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.greenAccent.withOpacity(0.4))),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.straighten, size: 16, color: Colors.greenAccent),
                                    const SizedBox(width: 6),
                                    Flexible(child: Text('${tr('المقاس', 'Size')}: $fullDimText', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13))),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 16, runSpacing: 10, alignment: WrapAlignment.spaceAround,
                              children: [
                                _StatBadge(label: tr('الغرز', 'Stitches'), value: numFmt.format(d.stitches), color: const Color(0xFF56CCF2)),
                                if (shortCmText != null) _StatBadge(label: tr('المقاس (سم)', 'Size (cm)'), value: shortCmText, color: Colors.lightGreenAccent),
                                _StatBadge(label: tr('الألوان', 'Colors'), value: '${d.colorCount}', color: const Color(0xFFD4AF37)),
                                _StatBadge(label: tr('الماكينة', 'Machine'), value: d.machineType, color: Colors.purpleAccent),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
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
  double _currentScale = 1.0;

  @override
  void initState() {
    super.initState();
    _transformController.addListener(() {
      final scale = _transformController.value.getMaxScaleOnAxis();
      if ((scale - _currentScale).abs() > 0.05) setState(() => _currentScale = scale);
    });
  }

  void _handleDoubleTap() {
    if (_transformController.value != Matrix4.identity()) {
      _transformController.value = Matrix4.identity();
    } else if (_doubleTapDetails != null) {
      final position = _doubleTapDetails!.localPosition;
      _transformController.value = Matrix4.identity()..translate(-position.dx * 3, -position.dy * 3)..scale(4.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.design;
    final imageWidget = Image.memory(d.previewJpeg!, fit: BoxFit.contain, filterQuality: FilterQuality.high, isAntiAlias: true, gaplessPlayback: true);
    return Scaffold(
      backgroundColor: _canvasBg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D), foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Directionality(textDirection: TextDirection.ltr, child: Text(d.fileName, style: const TextStyle(fontSize: 14))),
          ],
        ),
        actions: [
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
                transformationController: _transformController, minScale: 0.5, maxScale: 12.0, boundaryMargin: const EdgeInsets.all(120),
                child: Center(child: _enhanceClarity ? ColorFiltered(colorFilter: const ColorFilter.matrix([1.28, -0.09, -0.09, 0, -14, -0.09, 1.28, -0.09, 0, -14, -0.09, -0.09, 1.28, 0, -14, 0, 0, 0, 1, 0]), child: imageWidget) : imageWidget),
              ),
            ),
          ),
          Positioned(
            bottom: 18, left: 14, right: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: const Color(0xFF0E131D).withOpacity(0.92), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white12)),
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
                  TextButton.icon(
                    onPressed: () => setState(() => _enhanceClarity = !_enhanceClarity),
                    style: TextButton.styleFrom(backgroundColor: _enhanceClarity ? const Color(0xFFD4AF37).withOpacity(0.22) : Colors.white10),
                    icon: Icon(Icons.auto_fix_high, size: 15, color: _enhanceClarity ? const Color(0xFFD4AF37) : Colors.white60),
                    label: Text(tr('وضوح عالٍ', 'HD Clarity'), style: TextStyle(color: _enhanceClarity ? const Color(0xFFD4AF37) : Colors.white60, fontSize: 12)),
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
        margin: const EdgeInsets.symmetric(horizontal: 3), width: 22, height: 22,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: isSelected ? const Color(0xFFD4AF37) : Colors.white38, width: isSelected ? 2.5 : 1)),
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
