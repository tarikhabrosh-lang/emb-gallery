import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart' as intl;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'parsers/emb_parser.dart';

void main() {
  runApp(const EmbGalleryApp());
}

class EmbGalleryApp extends StatelessWidget {
  const EmbGalleryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'معرض التطريز EMB',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F4C81),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF12151C),
        cardColor: const Color(0xFF1B202B),
      ),
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
      home: const GalleryHomePage(),
    );
  }
}

enum SortOption { nameAsc, stitchesDesc, stitchesAsc, colorsDesc }

class GalleryHomePage extends StatefulWidget {
  const GalleryHomePage({super.key});

  @override
  State<GalleryHomePage> createState() => _GalleryHomePageState();
}

class _GalleryHomePageState extends State<GalleryHomePage> {
  final List<EmbDesignInfo> _allDesigns = [];
  List<EmbDesignInfo> _filteredDesigns = [];
  bool _isLoading = false;
  String _searchQuery = '';
  SortOption _sortOption = SortOption.nameAsc;
  String _statusText = 'اختر مجلداً أو ملفات EMB لعرضها كمعرض صور';

  Future<void> _requestStoragePermission() async {
    if (Platform.isAndroid) {
      await Permission.storage.request();
      await Permission.manageExternalStorage.request();
    }
  }

  Future<void> _pickMultipleFiles() async {
    try {
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
        _showSnack('لم يتم تحديد أي ملفات بصيغة .emb');
        return;
      }

      await _loadDesignsFromPaths(embPaths);
    } catch (e) {
      _showSnack('تعذر فتح الملفات: $e');
    }
  }

  Future<void> _pickFolder() async {
    try {
      await _requestStoragePermission();
      final dirPath = await FilePicker.platform.getDirectoryPath();
      if (dirPath == null) return;

      setState(() {
        _isLoading = true;
        _statusText = 'جاري فحص المجلد والبحث عن ملفات EMB...';
      });

      final dir = Directory(dirPath);
      final embPaths = <String>[];

      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.emb')) {
          embPaths.add(entity.path);
        }
      }

      if (embPaths.isEmpty) {
        setState(() {
          _isLoading = false;
          _statusText = 'لا توجد ملفات .emb داخل هذا المجلد';
        });
        return;
      }

      await _loadDesignsFromPaths(embPaths);
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnack('استخدم زر "اختيار ملفات" إذا كان المجلد محمياً من النظام');
    }
  }

  Future<void> _loadDesignsFromPaths(List<String> paths) async {
    setState(() {
      _isLoading = true;
      _allDesigns.clear();
      _filteredDesigns.clear();
      _statusText = 'جاري قراءة ${paths.length} تصميم...';
    });

    int loaded = 0;
    for (final path in paths) {
      final info = await EmbParser.parseFile(path);
      if (info != null) {
        _allDesigns.add(info);
        loaded++;
        if (loaded % 5 == 0 || loaded == paths.length) {
          _applyFilterAndSort();
        }
      }
    }

    setState(() {
      _isLoading = false;
      _statusText = _allDesigns.isEmpty
          ? 'تعذر قراءة الملفات المحددة'
          : 'تم تحميل ${_allDesigns.length} تصميم بنجاح';
    });
    _applyFilterAndSort();
  }

  void _applyFilterAndSort() {
    final query = _searchQuery.trim().toLowerCase();
    final list = _allDesigns.where((d) {
      if (query.isEmpty) return true;
      return d.fileName.toLowerCase().contains(query);
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

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final numFmt = intl.NumberFormat('#,###');

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'معرض التطريز EMB',
          style: TextStyle(fontWeight: FontWeight.bold),
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
              PopupMenuItem(value: SortOption.nameAsc, child: Text('الاسم (أ - ي)')),
              PopupMenuItem(value: SortOption.stitchesDesc, child: Text('الأكثر غرزاً')),
              PopupMenuItem(value: SortOption.stitchesAsc, child: Text('الأقل غرزاً')),
              PopupMenuItem(value: SortOption.colorsDesc, child: Text('الأكثر ألواناً')),
            ],
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
                    onPressed: _isLoading ? null : _pickMultipleFiles,
                    icon: const Icon(Icons.file_open),
                    label: const Text('اختيار ملفات EMB'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      backgroundColor: const Color(0xFF1D6FA5),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isLoading ? null : _pickFolder,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('فحص مجلد كامل'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_allDesigns.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'بحث باسم الموديل...',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: const Color(0xFF1B202B),
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
          if (_isLoading) const LinearProgressIndicator(),
          Expanded(
            child: _filteredDesigns.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.grid_view_rounded,
                            size: 64,
                            color: Colors.white.withOpacity(0.25),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _statusText,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 16, color: Colors.white70),
                          ),
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
          color: const Color(0xFF1B202B),
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
                      )
                    : const Center(
                        child: Icon(Icons.image_not_supported, color: Colors.grey, size: 40),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    design.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '$formattedStitches غرزة',
                        style: const TextStyle(color: Color(0xFF56CCF2), fontSize: 12),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${design.colorCount} لون',
                          style: const TextStyle(color: Colors.amber, fontSize: 11),
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

  Future<void> _shareDesignCard() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);
    try {
      final boundary =
          _shareCardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;

      final image = await boundary.toImage(pixelRatio: 2.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final tempDir = await getTemporaryDirectory();
      final outFile = File('${tempDir.path}/emb_preview_${DateTime.now().millisecondsSinceEpoch}.png');
      await outFile.writeAsBytes(byteData.buffer.asUint8List());

      final numFmt = intl.NumberFormat('#,###');
      await Share.shareXFiles(
        [XFile(outFile.path)],
        text:
            'موديل: ${widget.design.fileName}\nعدد الغرز: ${numFmt.format(widget.design.stitches)}\nعدد الألوان: ${widget.design.colorCount}',
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

  @override
  Widget build(BuildContext context) {
    final numFmt = intl.NumberFormat('#,###');
    final d = widget.design;

    return Scaffold(
      appBar: AppBar(
        title: Text(d.fileName, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            onPressed: _isSharing ? null : _shareDesignCard,
            icon: _isSharing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.share),
            tooltip: 'مشاركة للزبون / الماكينة',
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
                color: const Color(0xFF1B202B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Container(
                    height: 360,
                    width: double.infinity,
                    color: Colors.white,
                    child: d.previewJpeg != null
                        ? InteractiveViewer(
                            minScale: 0.8,
                            maxScale: 6.0,
                            child: Center(
                              child: Image.memory(d.previewJpeg!, fit: BoxFit.contain),
                            ),
                          )
                        : const Center(
                            child: Icon(Icons.image_not_supported, size: 64, color: Colors.grey),
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      children: [
                        Text(
                          d.fileName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _StatBadge(
                              label: 'الغرز',
                              value: numFmt.format(d.stitches),
                              color: const Color(0xFF56CCF2),
                            ),
                            _StatBadge(
                              label: 'الألوان',
                              value: '${d.colorCount}',
                              color: Colors.amber,
                            ),
                            _StatBadge(
                              label: 'التوقفات',
                              value: numFmt.format(d.stopsCount),
                              color: Colors.greenAccent,
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
          const SizedBox(height: 18),
          if (d.colorSequence.isNotEmpty) ...[
            const Text(
              'تسلسل الخيوط ومراحل التشغيل',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1B202B),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: d.colorSequence.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
                itemBuilder: (context, idx) {
                  final step = d.colorSequence[idx];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: const Color(0xFF1D6FA5),
                      child: Text(
                        '${step.stopNumber}',
                        style: const TextStyle(fontSize: 12, color: Colors.white),
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

class _StatBadge extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatBadge({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.white60),
        ),
      ],
    );
  }
}
