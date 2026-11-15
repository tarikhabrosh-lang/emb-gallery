import 'dart:io';
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
import 'parsers/emb_parser.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

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
  static const MethodChannel _intentChannel =
      MethodChannel('tarik_emb/file_intent');

  @override
  void initState() {
    super.initState();
    _setupIncomingFileHandler();
  }

  Future<void> _setupIncomingFileHandler() async {
    _intentChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFileOpened' && call.arguments is String) {
        await _openIncomingEmbFile(call.arguments as String);
      }
    });

    try {
      final initialPath =
          await _intentChannel.invokeMethod<String>('getInitialFile');
      if (initialPath != null && initialPath.isNotEmpty) {
        await _openIncomingEmbFile(initialPath);
      }
    } catch (_) {}
  }

  Future<void> _openIncomingEmbFile(String path) async {
    final info = await EmbParser.parseFile(path);
    if (info == null) return;
    Future.delayed(const Duration(milliseconds: 250), () {
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => DesignDetailScreen(design: info),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
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
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
      home: const FoldersGalleryPage(),
    );
  }
}

class EmbFolderGroup {
  final String folderPath;
  final String folderName;
  final List<String> filePaths;
  Uint8List? coverBytes;

  EmbFolderGroup({
    required this.folderPath,
    required this.folderName,
    required this.filePaths,
    this.coverBytes,
  });
}

class FoldersGalleryPage extends StatefulWidget {
  const FoldersGalleryPage({super.key});

  @override
  State<FoldersGalleryPage> createState() => _FoldersGalleryPageState();
}

class _FoldersGalleryPageState extends State<FoldersGalleryPage> {
  bool _isScanning = false;
  String _statusText = 'جاري فحص مجلدات التطريز في الخلفية...';
  final List<EmbFolderGroup> _folders = [];
  int _scanToken = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showWelcomeDialog();
      _startBackgroundScan();
    });
  }

  void _showWelcomeDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF18202E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFD4AF37), width: 1.5),
        ),
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: Color(0xFFD4AF37)),
            SizedBox(width: 8),
            Text(
              'أهلاً بك يا أبو وسيم',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'استوديو Tarik emb الذكي لعرض وتحليل ملفات التطريز.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            SizedBox(height: 16),
            Center(
              child: Text(
                'By Tarik Habrosh',
                style: TextStyle(
                  color: Color(0xFFD4AF37),
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3E522B),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('موافق'),
          ),
        ],
      ),
    );
  }

  Future<File> _getSavedFoldersFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/saved_emb_folders.txt');
  }

  Future<List<String>> _readSavedFolders() async {
    try {
      final f = await _getSavedFoldersFile();
      if (await f.exists()) {
        return (await f.readAsLines())
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _saveFolderToHistory(String folderPath) async {
    try {
      final current = await _readSavedFolders();
      if (!current.contains(folderPath)) {
        current.insert(0, folderPath);
        final f = await _getSavedFoldersFile();
        await f.writeAsString(current.join('\n'));
      }
    } catch (_) {}
  }

  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted ||
        await Permission.storage.isGranted) {
      return true;
    }
    final manageStatus = await Permission.manageExternalStorage.request();
    if (manageStatus.isGranted) return true;
    final storageStatus = await Permission.storage.request();
    return storageStatus.isGranted;
  }

  Future<void> _startBackgroundScan() async {
    final int currentToken = ++_scanToken;
    final hasPerm = await _ensureStoragePermission();
    if (!hasPerm) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _statusText = 'يرجى منح إذن الملفات أو اختيار مجلد يدوياً من الأعلى';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _isScanning = true;
      _folders.clear();
      _statusText = 'جاري البحث عن المجلدات في الخلفية...';
    });

    final savedDirs = await _readSavedFolders();
    final candidateDirs = <String>{
      ...savedDirs,
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Documents',
      '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Documents',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Documents',
      '/storage/emulated/0/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Documents',
      '/storage/emulated/0/Telegram/Telegram Documents',
    };

    final Map<String, List<String>> folderMap = {};

    for (final rootPath in candidateDirs) {
      if (currentToken != _scanToken) return;
      final rootDir = Directory(rootPath);
      if (await rootDir.exists()) {
        try {
          int count = 0;
          await for (final entity
              in rootDir.list(recursive: true, followLinks: false)) {
            if (currentToken != _scanToken) return;
            count++;
            if (count % 40 == 0) {
              await Future.delayed(const Duration(milliseconds: 1));
            }
            if (entity is File && entity.path.toLowerCase().endsWith('.emb')) {
              final parentDir = entity.parent.path;
              final list = folderMap.putIfAbsent(parentDir, () => []);
              if (!list.contains(entity.path)) {
                list.add(entity.path);
              }
            }
          }
        } catch (_) {}
      }
      _rebuildFoldersList(folderMap);
    }

    if (!mounted || currentToken != _scanToken) return;
    setState(() {
      _isScanning = false;
      _statusText = _folders.isEmpty
          ? 'لم يتم العثور على مجلدات تلقائياً. اضغط على "إضافة مجلد" بالأسفل.'
          : 'تم العثور على ${_folders.length} مجلدات';
    });

    _loadFolderCoversInBackground(currentToken);
  }

  void _rebuildFoldersList(Map<String, List<String>> folderMap) {
    if (!mounted) return;
    final list = <EmbFolderGroup>[];
    folderMap.forEach((path, files) {
      if (files.isNotEmpty) {
        final name = path.split(Platform.pathSeparator).last;
        list.add(EmbFolderGroup(
          folderPath: path,
          folderName: name.isEmpty ? path : name,
          filePaths: files,
        ));
      }
    });
    setState(() {
      _folders
        ..clear()
        ..addAll(list);
    });
  }

  Future<void> _loadFolderCoversInBackground(int token) async {
    for (final folder in _folders) {
      if (!mounted || token != _scanToken) return;
      if (folder.coverBytes == null && folder.filePaths.isNotEmpty) {
        final info = await EmbParser.parseFile(folder.filePaths.first);
        if (info?.previewJpeg != null && mounted && token == _scanToken) {
          setState(() {
            folder.coverBytes = info!.previewJpeg;
          });
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
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );
      if (result == null || result.paths.isEmpty) return;

      final embPaths = result.paths
          .whereType<String>()
          .where((p) => p.toLowerCase().endsWith('.emb'))
          .toList();

      if (embPaths.isEmpty) {
        _showSnack('يرجى اختيار ملف بصيغة .emb');
        return;
      }

      final firstParent = File(embPaths.first).parent.path;
      await _saveFolderToHistory(firstParent);

      if (embPaths.length == 1) {
        final info = await EmbParser.parseFile(embPaths.first);
        if (info != null && mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => DesignDetailScreen(design: info)),
          );
        }
      } else {
        final folderName = firstParent.split(Platform.pathSeparator).last;
        final group = EmbFolderGroup(
          folderPath: firstParent,
          folderName: folderName.isEmpty ? 'ملفات مختارة' : folderName,
          filePaths: embPaths,
        );
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => FolderDetailsScreen(folderGroup: group)),
          );
        }
      }
    } catch (e) {
      _showSnack('تعذر فتح الملف: $e');
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
        _statusText = 'جاري قراءة المجلد المختار...';
      });

      final embPaths = <String>[];
      final dir = Directory(dirPath);
      try {
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File && entity.path.toLowerCase().endsWith('.emb')) {
            embPaths.add(entity.path);
          }
        }
      } catch (_) {}

      setState(() => _isScanning = false);

      if (embPaths.isEmpty) {
        _showSnack('لا توجد ملفات .emb داخل هذا المجلد');
        return;
      }

      final folderName = dirPath.split(Platform.pathSeparator).last;
      final newGroup = EmbFolderGroup(
        folderPath: dirPath,
        folderName: folderName.isEmpty ? dirPath : folderName,
        filePaths: embPaths,
      );

      final firstInfo = await EmbParser.parseFile(embPaths.first);
      newGroup.coverBytes = firstInfo?.previewJpeg;

      setState(() {
        _folders.removeWhere((f) => f.folderPath == dirPath);
        _folders.insert(0, newGroup);
      });

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => FolderDetailsScreen(folderGroup: newGroup),
          ),
        );
      }
    } catch (e) {
      setState(() => _isScanning = false);
      _showSnack('تعذر فتح المجلد: $e');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: const Row(
          children: [
            Text(
              'Tarik emb',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xFFD4AF37),
                letterSpacing: 0.6,
              ),
            ),
            SizedBox(width: 8),
            Text(
              '| استوديو المجلدات',
              style: TextStyle(fontSize: 15, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFFD4AF37)),
            tooltip: 'تحديث المجلدات',
            onPressed: _startBackgroundScan,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _pickSingleOrMultipleFiles,
                    icon: const Icon(Icons.insert_drive_file),
                    label: const Text('فتح ملفات EMB'),
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
                    icon: const Icon(Icons.create_new_folder,
                        color: Color(0xFFD4AF
