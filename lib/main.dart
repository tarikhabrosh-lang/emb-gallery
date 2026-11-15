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

// نظام إدارة اللغات
class AppLocalizations {
  final Locale locale;
  AppLocalizations(this.locale);

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const _localizedValues = {
    'ar': {
      'app_title': 'Tarik emb',
      'studio': '| استوديو المجلدات',
      'open_files': 'فتح ملفات EMB',
      'add_folder': 'إضافة مجلد دائم',
      'folders': 'المجلدات',
      'total_files': 'إجمالي الملفات',
      'file_unit': 'ملف EMB',
      'search_folder': 'بحث داخل المجلد...',
      'search_model': 'بحث باسم الموديل...',
      'stitches': 'غرزة',
      'colors': 'لون',
      'threads': 'بكرات الخيوط المطلوبة للماكينة',
      'sequence': 'تسلسل الخيوط ومراحل التشغيل',
      'needle': 'إبرة رقم',
      'dimensions': 'الأبعاد',
      'share_image': 'مشاركة صورة المعاينة للواتس',
      'share_both': 'مشاركة الصورة + ملف EMB معاً',
      'full_screen': 'تكبير ملء الشاشة بوضوح',
      'background': 'الخلفية:',
      'high_clarity': 'وضوح عالٍ',
    },
    'en': {
      'app_title': 'Tarik emb',
      'studio': '| Folders Studio',
      'open_files': 'Open EMB Files',
      'add_folder': 'Add Persistent Folder',
      'folders': 'Folders',
      'total_files': 'Total Files',
      'file_unit': 'EMB files',
      'search_folder': 'Search in folder...',
      'search_model': 'Search model name...',
      'stitches': 'stitches',
      'colors': 'colors',
      'threads': 'Required Machine Thread Spools',
      'sequence': 'Thread Sequence & Operation Stops',
      'needle': 'Needle #',
      'dimensions': 'Dimensions',
      'share_image': 'Share Preview Image to WhatsApp',
      'share_both': 'Share Image + EMB File Together',
      'full_screen': 'High-Res Fullscreen Zoom',
      'background': 'Background:',
      'high_clarity': 'High Clarity',
    },
  };

  String translate(String key) {
    return _localizedValues[locale.languageCode]?[key] ?? key;
  }
}

class EmbGalleryApp extends StatefulWidget {
  const EmbGalleryApp({super.key});

  static void setLocale(BuildContext context, Locale newLocale) {
    _EmbGalleryAppState? state =
        context.findAncestorStateOfType<_EmbGalleryAppState>();
    state?.setLocale(newLocale);
  }

  @override
  State<EmbGalleryApp> createState() => _EmbGalleryAppState();
}

class _EmbGalleryAppState extends State<EmbGalleryApp> {
  Locale _locale = const Locale('ar'); // اللغة الافتراضية العربية
  static const MethodChannel _intentChannel =
      MethodChannel('tarik_emb/file_intent');

  void setLocale(Locale locale) {
    setState(() {
      _locale = locale;
    });
  }

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
      locale: _locale,
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
          textDirection:
              _locale.languageCode == 'ar' ? TextDirection.rtl : TextDirection.ltr,
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

  int get _totalFilesCount =>
      _folders.fold(0, (sum, folder) => sum + folder.filePaths.length);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showSignatureDialog();
      _startBackgroundScan();
    });
  }

  void _showSignatureDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF18202E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFD4AF37), width: 1.5),
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(height: 8),
            Text(
              'By Tarik Habrosh',
              style: TextStyle(
                color: Color(0xFFD4AF37),
                fontWeight: FontWeight.bold,
                fontSize: 18,
                letterSpacing: 1.2,
              ),
            ),
            SizedBox(height: 8),
          ],
        ),
        actions: [
          Center(
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3E522B),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              ),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('موافق'),
            ),
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
          ? 'لم يتم العثور على مجلدات تلقائياً. اضغط على "إضافة مجلد دائم" بالأعلى.'
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
        title: Row(
          children: [
            const Text(
              'Tarik emb',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xFFD4AF37),
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '| استوديو المجلدات',
              style: const TextStyle(fontSize: 15, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          // زر تبديل اللغة (عربي / إنجليزي)
          PopupMenuButton<String>(
            icon: const Icon(Icons.language, color: Color(0xFFD4AF37)),
            tooltip: 'Change Language / تغيير اللغة',
            onSelected: (langCode) {
              EmbGalleryApp.setLocale(context, Locale(langCode));
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'ar', child: Text('العربية (Arabic)')),
              PopupMenuItem(value: 'en', child: Text('English (الإنجليزية)')),
            ],
          ),
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
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
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
                        color: Color(0xFFD4AF37)),
                    label: const Text(
                      'إضافة مجلد دائم',
                      style: TextStyle(color: Color(0xFFD4AF37)),
                    ),
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
                      const Icon(Icons.folder_special,
                          size: 18, color: Color(0xFFD4AF37)),
                      const SizedBox(width: 6),
                      Text(
                        'المجلدات: ${_folders.length}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13),
                      ),
                    ],
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3E522B),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'إجمالي الملفات: $_totalFilesCount ملف EMB',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          if (_isScanning)
            const LinearProgressIndicator(color: Color(0xFFD4AF37)),
          Expanded(
            child: _folders.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.folder_copy_rounded,
                            size: 64,
                            color: Colors.white.withOpacity(0.25),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _statusText,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 15, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
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
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  FolderDetailsScreen(folderGroup: folder),
                            ),
                          );
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
                                          ? Image.memory(
                                              folder.coverBytes!,
                                              fit: BoxFit.contain,
                                              filterQuality: FilterQuality.high,
                                            )
                                          : const Center(
                                              child: Icon(
                                                Icons.folder_rounded,
                                                size: 54,
                                                color: Color(0xFFD4AF37),
                                              ),
                                            ),
                                    ),
                                    Positioned(
                                      top: 8,
                                      left: 8,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 9, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF0E131D)
                                              .withOpacity(0.88),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(
                                              color: const Color(0xFFD4AF37),
                                              width: 1),
                                        ),
                                        child: Text(
                                          '${folder.filePaths.length} ملف',
                                          style: const TextStyle(
                                            color: Color(0xFFD4AF37),
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                          ),
                                        ),
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
                                        const Icon(Icons.folder,
                                            size: 16,
                                            color: Color(0xFFD4AF37)),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Directionality(
                                            textDirection: TextDirection.ltr,
                                            child: Text(
                                              folder.folderName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'عدد الملفات: ${folder.filePaths.length}',
                                      style: const TextStyle(
                                        color: Color(0xFF56CCF2),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
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
      final info = await EmbParser.parseFile(path);
      if (info != null) {
        _designs.add(info);
        count++;
        if (count % 4 == 0 || count == widget.folderGroup.filePaths.length) {
          _applyFilterAndSort();
        }
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
    final list = _designs.where((d) {
      if (q.isEmpty) return true;
      return d.fileName.toLowerCase().contains(q);
    }).toList();

    switch (_sortOption) {
      case SortOption.nameAsc:
        list.sort((a, b) => a.fileName.compareTo(b.fileName));
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

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: Row(
          children: [
            Expanded(
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  widget.folderGroup.folderName,
                  style: const TextStyle(fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFD4AF37).withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${widget.folderGroup.filePaths.length} ملف',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFD4AF37),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<SortOption>(
            icon: const Icon(Icons.sort),
            tooltip: 'ترتيب التصاميم',
            onSelected: (opt) {
              _sortOption = opt;
              _applyFilterAndSort();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: SortOption.nameAsc, child: Text('الاسم (أ - ي)')),
              PopupMenuItem(
                  value: SortOption.stitchesDesc, child: Text('الأكثر غرزاً')),
              PopupMenuItem(
                  value: SortOption.stitchesAsc, child: Text('الأقل غرزاً')),
              PopupMenuItem(
                  value: SortOption.colorsDesc, child: Text('الأكثر ألواناً')),
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
                hintText:
                    'بحث داخل ${widget.folderGroup.filePaths.length} ملف...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: const Color(0xFF18202E),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (val) {
                _searchQuery = val;
                _applyFilterAndSort();
              },
            ),
          ),
          if (_isLoading)
            const LinearProgressIndicator(color: Color(0xFFD4AF37)),
          Expanded(
            child: _filteredDesigns.isEmpty
                ? Center(
                    child: Text(
                      _isLoading
                          ? 'جاري قراءة تصاميم المجلد...'
                          : 'لا توجد تصاميم مطابقة',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 0.74,
                    ),
                    itemCount: _filteredDesigns.length,
                    itemBuilder: (context, index) {
                      final item = _filteredDesigns[index];
                      return _DesignGridCard(
                        design: item,
                        formattedStitches: numFmt.format(item.stitches),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DesignDetailScreen(design: item),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _DesignGridCard extends StatelessWidget {
  final EmbDesignInfo design;
  final String formattedStitches;
  final VoidCallback onTap;

  const _DesignGridCard({
    required this.design,
    required this.formattedStitches,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
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
                child: design.previewJpeg != null
                    ? Image.memory(
                        design.previewJpeg!,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                      )
                    : const Center(
                        child: Icon(Icons.image_not_supported,
                            color: Colors.grey, size: 40),
                      ),
              ),
            ),
            
