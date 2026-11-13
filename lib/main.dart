import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'parsers/emb_parser.dart';

void main() {
  runApp(const TarikEmbApp());
}

class TarikEmbApp extends StatelessWidget {
  const TarikEmbApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tarik emb',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0E131D),
        primaryColor: const Color(0xFF3E522B),
        colorScheme: ColorScheme.dark(
          surface: const Color(0xFF18202E),
          primary: const Color(0xFF3E522B),
          secondary: const Color(0xFFD4AF37),
        ),
        fontFamily: 'sans-serif',
      ),
      home: const GalleryHomePage(),
    );
  }
}

class GalleryHomePage extends StatefulWidget {
  const GalleryHomePage({super.key});

  @override
  State<GalleryHomePage> createState() => _GalleryHomePageState();
}

class _GalleryHomePageState extends State<GalleryHomePage> {
  static const MethodChannel _platformChannel = MethodChannel('tarik_emb/file_intent');
  List<EmbDesignInfo> _designs = [];
  bool _isLoading = false;
  String _statusMessage = 'اختر مجلداً أو ملفات لعرض تصاميم التطريز';

  @override
  void initState() {
    super.initState();
    _initFileIntentListener();
  }

  void _initFileIntentListener() {
    _platformChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFileOpened') {
        final String? path = call.arguments;
        if (path != null) {
          await _openSingleFileDirectly(path);
        }
      }
    });

    _platformChannel.invokeMethod<String>('getInitialFile').then((path) {
      if (path != null) {
        _openSingleFileDirectly(path);
      }
    });
  }

  Future<void> _openSingleFileDirectly(String path) async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'جاري فتح الملف الوارد...';
    });
    final design = await EmbParser.parseFile(path);
    if (design != null) {
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DesignDetailScreen(design: design),
        ),
      );
    }
    setState(() {
      _isLoading = false;
      _statusMessage = 'تم التحميل بنجاح';
    });
  }

  Future<void> _pickDirectory() async {
    if (Platform.isAndroid) {
      var status = await Permission.storage.request();
      if (!status.isGranted) {
        await Permission.manageExternalStorage.request();
      }
    }

    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory == null) return;

    setState(() {
      _isLoading = true;
      _designs = [];
      _statusMessage = 'جاري مسح المجلد والبحث عن ملفات EMB...';
    });

    final dir = Directory(selectedDirectory);
    final List<EmbDesignInfo> loadedDesigns = [];

    try {
      await for (var entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final pathLower = entity.path.toLowerCase();
          if (pathLower.endsWith('.emb')) {
            final design = await EmbParser.parseFile(entity.path);
            if (design != null) {
              loadedDesigns.add(design);
            }
          }
        }
      }
    } catch (e) {
      _statusMessage = 'حدث خطأ أثناء قراءة المجلد';
    }

    setState(() {
      _designs = loadedDesigns;
      _isLoading = false;
      _statusMessage = loadedDesigns.isEmpty
          .toString()
          .contains('true')
              ? 'لم يتم العثور على ملفات EMB في هذا المجلد'
              : 'تم العثور على ${loadedDesigns.length} تصميماً بنجاح';
    });
  }

  Future<void> _pickIndividualFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['emb', 'EMB'],
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) return;

    setState(() {
      _isLoading = true;
      _statusMessage = 'جاري تحليل الملفات المحددة...';
    });

    final List<EmbDesignInfo> loadedDesigns = [];
    for (var file in result.files) {
      if (file.path != null) {
        final design = await EmbParser.parseFile(file.path!);
        if (design != null) {
          loadedDesigns.add(design);
        }
      }
    }

    setState(() {
      _designs.addAll(loadedDesigns);
      _isLoading = false;
      _statusMessage = 'تمت إضافة ${loadedDesigns.length} تصاميم بنجاح';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFD4AF37),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.gesture, color: Color(0xFF0E131D), size: 20),
            ),
            const SizedBox(width: 12),
            const Text('Tarik emb', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFD4AF37))),
          ],
        ),
        backgroundColor: const Color(0xFF18202E),
        elevation: 2,
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open, color: Color(0xFFD4AF37)),
            tooltip: 'فتح مجلد كامل',
            onPressed: _pickDirectory,
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Color(0xFFD4AF37)),
            tooltip: 'إضافة ملفات',
            onPressed: _pickIndividualFiles,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: const Color(0xFF18202E),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 16, color: Color(0xFFD4AF37)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusMessage,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
                if (_designs.isNotEmpty)
                  Text(
                    'العدد: ${_designs.length}',
                    style: const TextStyle(color: Color(0xFFD4AF37), fontWeight: FontWeight.bold),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFFD4AF37)),
                  )
                : _designs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.folder_off, size: 64, color: Colors.white24),
                            const SizedBox(height: 16),
                            const Text(
                              'لا توجد تصاميم معروضة حالياً',
                              style: TextStyle(color: Colors.white60, fontSize: 16),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'اختر مجلداً أو ملفات `.emb` للبدء',
                              style: TextStyle(color: Colors.white38, fontSize: 13),
                            ),
                            const SizedBox(height: 24),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF3E522B),
                                foregroundColor: Colors.white,
                              ),
                              onPressed: _pickDirectory,
                              icon: const Icon(Icons.folder_open),
                              label: const Text('اختيار مجلد التصاميم'),
                            ),
                          ],
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 0.82,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: _designs.length,
                        itemBuilder: (context, index) {
                          final design = _designs[index];
                          return Card(
                            color: const Color(0xFF18202E),
                            elevation: 3,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: const BorderSide(color: Colors.white10),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => DesignDetailScreen(design: design),
                                  ),
                                );
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: Container(
                                      color: Colors.white,
                                      child: design.previewJpeg != null
                                          ? Image.memory(
                                              design.previewJpeg!,
                                              fit: BoxFit.contain,
                                              filterQuality: FilterQuality.high,
                                            )
                                          : const Center(
                                              child: Icon(Icons.image_not_supported, color: Colors.grey),
                                            ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          design.fileName,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              '${design.stitches} غرزة',
                                              style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 11),
                                            ),
                                            Text(
                                              '${design.actualStopsCount} ألوان',
                                              style: const TextStyle(color: Colors.white60, fontSize: 11),
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
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class DesignDetailScreen extends StatelessWidget {
  final EmbDesignInfo design;
  const DesignDetailScreen({super.key, required this.design});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(design.fileName, style: const TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF18202E),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'مشاركة التصميم',
            onPressed: () async {
              if (design.previewJpeg != null) {
                final tempDir = Directory.systemTemp;
                final file = File('${tempDir.path}/${design.fileName}.jpg');
                await file.writeAsBytes(design.previewJpeg!);
                await Share.shareXFiles(
                  [XFile(file.path), XFile(design.filePath)],
                  text: 'تصميم: ${design.fileName}\nعدد الغرز: ${design.stitches}\nالألوان: ${design.actualStopsCount}\nمُصدّر عبر Tarik emb',
                );
              } else {
                await Share.share('تصميم: ${design.fileName} - عدد الغرز: ${design.stitches}');
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Preview Image Area with high clarity zoom trigger
            GestureDetector(
              onTap: () {
                if (design.previewJpeg != null) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FullScreenDesignViewer(
                        imageBytes: design.previewJpeg!,
                        title: design.fileName,
                      ),
                    ),
                  );
                }
              },
              child: Container(
                height: 320,
                color: Colors.white,
                child: Stack(
                  children: [
                    Center(
                      child: design.previewJpeg != null
                          ? Image.memory(
                              design.previewJpeg!,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                            )
                          : const Icon(Icons.image, size: 80, color: Colors.grey),
                    ),
                    Positioned(
                      bottom: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.zoom_in, color: Color(0xFFD4AF37), size: 16),
                            SizedBox(width: 4),
                            Text('اضغط للتكبير الفائق', style: TextStyle(color: Colors.white, fontSize: 11)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Info Cards
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'بيانات التصميم والماكينة',
                    style: TextStyle(color: Color(0xFFD4AF37), fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _buildInfoCard('إجمالي الغرز', '${design.stitches}', Icons.linear_scale),
                      const SizedBox(width: 12),
                      _buildInfoCard('عدد المراحل', '${design.actualStopsCount}', Icons.palette),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _buildInfoCard('القفزات', '${design.jumpsCount}', Icons.alt_route),
                      const SizedBox(width: 12),
                      _buildInfoCard('الأبعاد', design.widthMm != null && design.heightMm != null ? '${design.widthMm!.toStringAsFixed(1)} × ${design.heightMm!.toStringAsFixed(1)} مم' : 'غير متوفر', Icons.aspect_ratio),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'تسلسل الخيوط والألوان',
                    style: TextStyle(color: Color(0xFFD4AF37), fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  design.colorSequence.isEmpty
                      ? const Text('لا توجد تفاصيل ألوان إضافية مسجلة في هذا الملف', style: TextStyle(color: Colors.white60))
                      : ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: design.colorSequence.length,
                          itemBuilder: (context, index) {
                            final step = design.colorSequence[index];
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF18202E),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white10),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 24,
                                    height: 24,
                                    decoration: BoxDecoration(
                                      color: Color(step.colorValue),
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white, width: 1.5),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'المرحلة ${step.stopNumber}: ${step.colorName}',
                                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'عدد الغرز: ${step.stitches}',
                                          style: const TextStyle(color: Colors.white60, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(String title, String value, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF18202E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFFD4AF37), size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white60, fontSize: 11)),
                  const SizedBox(height: 4),
                  Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FullScreenDesignViewer extends StatefulWidget {
  final Uint8List imageBytes;
  final String title;

  const FullScreenDesignViewer({super.key, required this.imageBytes, required this.title});

  @override
  State<FullScreenDesignViewer> createState() => _FullScreenDesignViewerState();
}

class _FullScreenDesignViewerState extends State<FullScreenDesignViewer> {
  Color _backgroundColor = Colors.white;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: const Color(0xFF18202E),
        actions: [
          IconButton(
            icon: const Icon(Icons.color_lens),
            tooltip: 'تغيير لون الخلفية',
            onPressed: () {
              setState(() {
                if (_backgroundColor == Colors.white) {
                  _backgroundColor = const Color(0xFF0E131D);
                } else if (_backgroundColor == const Color(0xFF0E131D)) {
                  _backgroundColor = Colors.black;
                } else {
                  _backgroundColor = Colors.white;
                }
              });
            },
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 12.0,
          child: Image.memory(
            widget.imageBytes,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
        ),
      ),
    );
  }
}
