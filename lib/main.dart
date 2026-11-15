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

  EmbFolderGroup({
    required this.folderPath,
    required this.folderName,
    required this.filePaths,
  });
}

class FoldersGalleryPage extends StatefulWidget {
  const FoldersGalleryPage({super.key});

  @override
  State<FoldersGalleryPage> createState() => _FoldersGalleryPageState();
}

class _FoldersGalleryPageState extends State<FoldersGalleryPage> {
  bool _isLoading = false;
  String _statusText = 'جاري البحث عن مجلدات التطريز في الجهاز...';
  final List<EmbFolderGroup> _folders = [];

  @override
  void initState() {
    super.initState();
    _scanDeviceForFolders();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showWelcomeDialog();
    });
  }

  void _showWelcomeDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
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
              'نظام استوديو المجلدات الذكي لملفات التطريز.',
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
            onPressed: () => Navigator.pop(context),
            child: const Text('موافق'),
          ),
        ],
      ),
    );
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

  Future<void> _scanDeviceForFolders() async {
    await _ensureStoragePermission();
    setState(() {
      _isLoading = true;
      _folders.clear();
      _statusText = 'جاري تصنيف الملفات في مجلدات تشبه الاستوديو...';
    });

    final Map<String, List<String>> folderMap = {};

    final candidateDirs = <String>[
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Documents',
      '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Documents',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Documents',
      '/storage/emulated/0/Telegram/Telegram Documents',
      '/storage/emulated/0/Bluetooth',
    ];

    for (final rootPath in candidateDirs) {
      final rootDir = Directory(rootPath);
      if (await rootDir.exists()) {
        try {
          await for (final entity
              in rootDir.list(recursive: true, followLinks: false)) {
            if (entity is File && entity.path.toLowerCase().endsWith('.emb')) {
              final parentDir = entity.parent.path;
              folderMap.putIfAbsent(parentDir, () => []).add(entity.path);
            }
          }
        } catch (_) {}
      }
    }

    final tempFolders = <EmbFolderGroup>[];
    folderMap.forEach((path, files) {
      final folderName = path.split(Platform.pathSeparator).last;
      tempFolders.add(EmbFolderGroup(
        folderPath: path,
        folderName: folderName.isEmpty ? path : folderName,
        filePaths: files,
      ));
    });

    setState(() {
      _isLoading = false;
      _folders.addAll(tempFolders);
      _statusText = _folders.isEmpty
          ? 'لا توجد مجلدات تحوي ملفات EMB. اختر مجلداً يدوياً من الأعلى.'
          : 'تم العثور على ${_folders.length} مجلدات';
    });
  }

  Future<void> _pickCustomFolder() async {
    try {
      await _ensureStoragePermission();
      final dirPath = await FilePicker.platform.getDirectoryPath();
      if (dirPath == null) return;

      final embPaths = <String>[];
      final dir = Directory(dirPath);
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.emb')) {
          embPaths.add(entity.path);
        }
      }

      if (embPaths.isEmpty) {
        _showSnack('لا توجد ملفات .emb في هذا المجلد');
        return;
      }

      final folderName = dirPath.split(Platform.pathSeparator).last;
      setState(() {
        _folders.insert(
          0,
          EmbFolderGroup(
            folderPath: dirPath,
            folderName: folderName.isEmpty ? dirPath : folderName,
            filePaths: embPaths,
          ),
        );
      });
    } catch (e) {
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
            tooltip: 'إعادة مسح المجلدات',
            onPressed: _isLoading ? null : _scanDeviceForFolders,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: ElevatedButton.icon(
              onPressed: _isLoading ? null : _pickCustomFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('إضافة وتصفح مجلد جديد'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: const Color(0xFF3E522B),
                foregroundColor: Colors.white,
              ),
            ),
          ),
          if (_isLoading)
            const LinearProgressIndicator(color: Color(0xFFD4AF37)),
          Expanded(
            child: _folders.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _statusText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 16, color: Colors.white70),
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
                      childAspectRatio: 1.1,
                    ),
                    itemCount: _folders.length,
                    itemBuilder: (context, index) {
                      final folder = _folders[index];
                      return GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => FolderDetailsScreen(
                                folderGroup: folder,
                              ),
                            ),
                          );
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF18202E),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white12),
                          ),
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.folder_rounded,
                                  size: 44, color: Color(0xFFD4AF37)),
                              const SizedBox(height: 12),
                              Text(
                                folder.folderName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${folder.filePaths.length} ملف تصميم',
                                style: const TextStyle(
                                  color: Color(0xFF56CCF2),
                                  fontSize: 12,
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

class FolderDetailsScreen extends StatefulWidget {
  final EmbFolderGroup folderGroup;

  const FolderDetailsScreen({super.key, required this.folderGroup});

  @override
  State<FolderDetailsScreen> createState() => _FolderDetailsScreenState();
}

class _FolderDetailsScreenState extends State<FolderDetailsScreen> {
  final List<EmbDesignInfo> _designs = [];
  bool _isLoading = true;
  String _searchQuery = '';
  List<EmbDesignInfo> _filteredDesigns = [];

  @override
  void initState() {
    super.initState();
    _loadFolderDesigns();
  }

  Future<void> _loadFolderDesigns() async {
    for (final path in widget.folderGroup.filePaths) {
      final info = await EmbParser.parseFile(path);
      if (info != null) {
        _designs.add(info);
        if (mounted) {
          setState(() {
            _filterList();
          });
        }
      }
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _filterList() {
    final q = _searchQuery.trim().toLowerCase();
    _filteredDesigns = _designs.where((d) {
      if (q.isEmpty) return true;
      return d.fileName.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final numFmt = intl.NumberFormat('#,###');

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: Text(widget.folderGroup.folderName,
            style: const TextStyle(fontSize: 16)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'بحث داخل المجلد...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: const Color(0xFF18202E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (val) {
                setState(() {
                  _searchQuery = val;
                  _filterList();
                });
              },
            ),
          ),
          if (_isLoading)
            const LinearProgressIndicator(color: Color(0xFFD4AF37)),
          Expanded(
            child: _filteredDesigns.isEmpty
                ? Center(
                    child: Text(
                      _isLoading ? 'جاري تحميل تصاميم المجلد...' : 'لا توجد نتائج',
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
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      design.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '$formattedStitches غرزة',
                        style: const TextStyle(
                            color: Color(0xFF56CCF2), fontSize: 12),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD4AF37).withOpacity(0.18),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${design.colorCount} لون',
                          style: const TextStyle(
                              color: Color(0xFFD4AF37), fontSize: 11),
                        ),
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
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenDesignViewer(design: widget.design),
      ),
    );
  }

  Future<void> _shareDesignCard({bool includeEmbFile = false}) async {
    if (_isSharing) return;
    setState(() => _isSharing = true);
    try {
      final boundary = _shareCardKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;

      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final tempDir = await getTemporaryDirectory();
      final outFile = File(
          '${tempDir.path}/tarik_emb_${DateTime.now().millisecondsSinceEpoch}.png');
      await outFile.writeAsBytes(byteData.buffer.asUint8List());

      final filesToShare = <XFile>[XFile(outFile.path)];
      if (includeEmbFile && await File(widget.design.filePath).exists()) {
        filesToShare.add(XFile(widget.design.filePath));
      }

      final numFmt = intl.NumberFormat('#,###');
      final seqText = widget.design.sequinsCount > 0
          ? '\nعدد الترتر: ${numFmt.format(widget.design.sequinsCount)}'
          : '';
      await Share.shareXFiles(
        filesToShare,
        text:
            'موديل: ${widget.design.fileName}\nعدد الغرز: ${numFmt.format(widget.design.stitches)}\nعدد الألوان: ${widget.design.colorCount}\nعدد المراحل: ${widget.design.actualStopsCount}$seqText',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذرت المشاركة: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  List<ThreadColorStep> _getUniqueThreadPalette(List<ThreadColorStep> seq) {
    final seen = <String>{};
    final unique = <ThreadColorStep>[];
    for (final s in seq) {
      final key = '${s.colorIndex}_${s.colorName}';
      if (seen.add(key)) {
        unique.add(s);
      }
    }
    return unique;
  }

  @override
  Widget build(BuildContext context) {
    final numFmt = intl.NumberFormat('#,###');
    final d = widget.design;
    final uniqueThreads = _getUniqueThreadPalette(d.colorSequence);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        title: Directionality(
          textDirection: TextDirection.ltr,
          child: Text(d.fileName, style: const TextStyle(fontSize: 16)),
        ),
        actions: [
          if (d.previewJpeg != null)
            IconButton(
              onPressed: _openFullScreenViewer,
              icon: const Icon(Icons.fullscreen, color: Color(0xFFD4AF37)),
              tooltip: 'تكبير بملء الشاشة',
            ),
          PopupMenuButton<String>(
            icon: _isSharing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.share),
            tooltip: 'مشاركة عبر واتساب',
            onSelected: (val) {
              if (val == 'image') {
                _shareDesignCard(includeEmbFile: false);
              } else if (val == 'both') {
                _shareDesignCard(includeEmbFile: true);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'image',
                child: Text('مشاركة صورة المعاينة للواتس'),
              ),
              PopupMenuItem(
                value: 'both',
                child: Text('مشاركة الصورة + ملف EMB معاً'),
              ),
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
                              : const Center(
                                  child: Icon(Icons.image_not_supported,
                                      size: 64, color: Colors.grey),
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
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.zoom_in,
                                          size: 18, color: Color(0xFFD4AF37)),
                                      SizedBox(width: 4),
                                      Text(
                                        'تكبير ملء الشاشة بوضوح',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold),
                                      ),
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
                          child: Text(
                            d.fileName,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                        if (d.widthMm != null && d.heightMm != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            'الأبعاد: ${d.widthMm!.toStringAsFixed(1)} ×${d.heightMm!.toStringAsFixed(1)} مم',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 16,
                          runSpacing: 10,
                          alignment: WrapAlignment.spaceAround,
                          children: [
                            _StatBadge(
                              label: 'الغرز',
                              value: numFmt.format(d.stitches),
                              color: const Color(0xFF56CCF2),
                            ),
                            _StatBadge(
                              label: 'الألوان',
                              value: '${d.colorCount}',
                              color: const Color(0xFFD4AF37),
                            ),
                            _StatBadge(
                              label: 'المراحل',
                              value: numFmt.format(d.actualStopsCount),
                              color: Colors.greenAccent,
                            ),
                            _StatBadge(
                              label: 'الترتر',
                              value: numFmt.format(d.sequinsCount),
                              color: Colors.pinkAccent,
                            ),
                            _StatBadge(
                              label: 'القفزات',
                              value: numFmt.format(d.jumpsCount),
                              color: Colors.orangeAccent,
                            ),
                            _StatBadge(
                              label: 'الماكينة',
                              value: d.machineType,
                              color: Colors.purpleAccent,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (uniqueThreads.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'بكرات الخيوط المطلوبة للماكينة',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: uniqueThreads.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, idx) {
                  final t = uniqueThreads[idx];
                  final threadColor = Color(t.colorValue);
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF18202E),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: threadColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white54, width: 1),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${t.colorName} (#${t.colorIndex})',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 18),
          if (d.colorSequence.isNotEmpty) ...[
            const Text(
              'تسلسل الخيوط ومراحل التشغيل',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF18202E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: d.colorSequence.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Colors.white10),
                itemBuilder: (context, idx) {
                  final step = d.colorSequence[idx];
                  final stepColor = Color(step.colorValue);
                  final bool isLight = stepColor.computeLuminance() > 0.55;
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 15,
                      backgroundColor: stepColor,
                      child: Text(
                        '${step.stopNumber}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: isLight ? Colors.black : Colors.white,
                        ),
                      ),
                    ),
                    title: Text(step.colorName),
                    subtitle: Text('إبرة رقم ${step.colorIndex}'),
                    trailing: Text(
                      '${numFmt.format(step.stitches)} غرزة',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
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
  final TransformationController _transformController =
      TransformationController();
  TapDownDetails? _doubleTapDetails;

  Color _canvasBg = Colors.white;
  bool _enhanceClarity = true;
  bool _showStitchView = false;
  double _currentScale = 1.0;

  @override
  void initState() {
    super.initState();
    _transformController.addListener(() {
      final scale = _transformController.value.getMaxScaleOnAxis();
      if ((scale - _currentScale).abs() > 0.05) {
        setState(() => _currentScale = scale);
      }
    });
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    if (_transformController.value != Matrix4.identity()) {
      _transformController.value = Matrix4.identity();
    } else if (_doubleTapDetails != null) {
      final position = _doubleTapDetails!.localPosition;
      const double targetScale = 4.0;
      _transformController.value = Matrix4.identity()
        ..translate(
            -position.dx * (targetScale - 1), -position.dy * (targetScale - 1))
        ..scale(targetScale);
    }
  }

  void _resetZoom() {
    _transformController.value = Matrix4.identity();
  }

  static const ColorFilter _clarityMatrix = ColorFilter.matrix(<double>[
    1.28, -0.09, -0.09, 0, -14,
    -0.09, 1.28, -0.09, 0, -14,
    -0.09, -0.09, 1.28, 0, -14,
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final d = widget.design;
    final Uint8List activeImage =
        (_showStitchView && d.stitchPreviewBytes != null)
            ? d.stitchPreviewBytes!
            : d.previewJpeg!;

    final media = MediaQuery.of(context);
    final targetCacheWidth =
        (media.size.width * media.devicePixelRatio * 4).round().clamp(1024, 4096);

    final imageWidget = Image.memory(
      activeImage,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      isAntiAlias: true,
      cacheWidth: d.previewWidth > 0 ? null : targetCacheWidth,
      gaplessPlayback: true,
    );

    return Scaffold(
      backgroundColor: _canvasBg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E131D),
        foregroundColor: Colors.white,
        title: Directionality(
          textDirection: TextDirection.ltr,
          child: Text(
            d.fileName,
            style: const TextStyle(fontSize: 15),
          ),
        ),
        actions: [
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${(_currentScale * 100).round()}%',
                style: const TextStyle(
                  color: Color(0xFFD4AF37),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: _resetZoom,
            icon: const Icon(Icons.fit_screen),
            tooltip: 'إعادة ضبط الحجم',
          ),
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
                          colorFilter: _clarityMatrix,
                          child: imageWidget,
                        )
                      : imageWidget,
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 18,
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
                      const Text(
                        'الخلفية:',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(width: 6),
                      _BgColorDot(
                        color: Colors.white,
                        isSelected: _canvasBg == Colors.white,
                        onTap: () => setState(() => _canvasBg = Colors.white),
                      ),
                      _BgColorDot(
                        color: const Color(0xFF0E131D),
                        isSelected: _canvasBg == const Color(0xFF0E131D),
                        
