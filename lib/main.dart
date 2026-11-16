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

final GlobalKey rootNavigatorKey = GlobalKey();
final ValueNotifier isArabicNotifier = ValueNotifier(true);

String tr(String ar, String en) => isArabicNotifier.value == true ? ar : en;
final validExtensions = ['.emb', '.dst', '.pes', '.pec', '.exp', '.ef', '.vp3', '.xxx', '.u01'];

String? formatDimensionsCm(double? widthMm, double? heightMm, {bool includeMm = false}) {
  if (widthMm == null || heightMm == null) return null;
  final wCm = (widthMm / 10.0).toStringAsFixed(1);
  final hCm = (heightMm / 10.0).toStringAsFixed(1);
  final unitCm = tr('سم', 'cm');
  if (!includeMm) return '$wCm × $hCm$unitCm';
  final wMm = widthMm.toStringAsFixed(0);
  final hMm = heightMm.toStringAsFixed(0);
  final unitMm = tr('مم', 'mm');
  return '$wCm × $hCm $unitCm  ($wMm × $hMm$unitMm)';
}

class LicenseManager {
  static Future checkLicense() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/tarik_license.txt');
      if (!await file.exists()) {
        final newId = (100000 + Random().nextInt(900000)).toString();
        final now = DateTime.now().millisecondsSinceEpoch;
        await file.writeAsString('$now\vert{}false\vert{}$newId');
        return {'valid': true, 'activated': false, 'id': newId, 'days': 7};
      }
      final data = await file.readAsString();
      final parts = data.split('|');
      if (parts.length != 3) return {'valid': true, 'activated': false, 'id': '123456', 'days': 7};

      final installTime = int.tryParse(parts[0]) ?? 0;
      final activated = parts[1] == 'true';
      final id = parts[2];

      if (activated) return {'valid': true, 'activated': true, 'id': id, 'days': 0};

      final now = DateTime.now().millisecondsSinceEpoch;
      final diff = now - installTime;
      final daysPassed = diff / (1000 * 60 * 60 * 24);
      final remaining = 7 - daysPassed.floor();

      if (remaining > 0) return {'valid': true, 'activated': false, 'id': id, 'days': remaining};
      return {'valid': true, 'activated': false, 'id': id, 'days': 0};
    } catch (e) {
      return {'valid': true, 'activated': false, 'id': '123456', 'days': 7};
    }
  }

  static Future activate(String deviceId, String enteredCode) async {
    try {
      final idNum = int.tryParse(deviceId) ?? 0;
      final expectedCode = (idNum * 7) + 2026;
      if (enteredCode.trim() == expectedCode.toString()) {
        final dir = await getApplicationSupportDirectory();
        final file = File('${dir.path}/tarik_license.txt');
        final data = await file.readAsString();
        final parts = data.split('|');
        await file.writeAsString('${parts[0]}\vert{}true\vert{}${parts[2]}');
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RootAppLoader());
}

class RootAppLoader extends StatelessWidget {
  const RootAppLoader({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: LicenseManager.checkLicense(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          final license = snapshot.data ?? {'valid': true, 'activated': false, 'id': '123456', 'days': 7};
          return EmbGalleryApp(license: license as Map);
        }
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: const Color(0xFF0E131D),
            body: Center(
              child: CircularProgressIndicator(color: const Color(0xFFD4AF37)),
            ),
          ),
        );
      },
    );
  }
}

class EmbGalleryApp extends StatefulWidget {
  final Map license;
  const EmbGalleryApp({super.key, required this.license});
  @override
  State createState() => _EmbGalleryAppState();
}

class _EmbGalleryAppState extends State<EmbGalleryApp> {
  static const MethodChannel _intentChannel = MethodChannel('tarik_emb/file_intent');

  @override
  void initState() {
    super.initState();
    _loadLanguagePreference();
    if (widget.license['valid'] == true) _setupIncomingFileHandler();
  }

  Future _loadLanguagePreference() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/app_lang.txt');
      if (await f.exists()) {
        final code = (await f.readAsString()).trim();
        isArabicNotifier.value = (code != 'en');
      }
    } catch (_) {}
  }

  static Future toggleLanguage() async {
    isArabicNotifier.value = !(isArabicNotifier.value == true);
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/app_lang.txt');
      await f.writeAsString(isArabicNotifier.value == true ? 'ar' : 'en');
    } catch (_) {}
  }

  Future _setupIncomingFileHandler() async {
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

  Future _openIncomingEmbFile(String path) async {
    final lower = path.toLowerCase();
    EmbDesignInfo? info;
    if (lower.endsWith('.dst')) {
      info = await DstParser.parseFile(path);
    } else if (lower.endsWith('.emb')) {
      info = await EmbParser.parseFile(path);
    } else {
      final name = path.split(Platform.pathSeparator).last;
      info = EmbDesignInfo(
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

    if (info == null) return;
    Future.delayed(const Duration(milliseconds: 250), () {
      final nav = rootNavigatorKey.currentState as NavigatorState?;
      nav?.push(
        MaterialPageRoute(builder: (_) => DesignDetailScreen(design: info!)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: isArabicNotifier,
      builder: (context, isAr, _) {
        return MaterialApp(
          navigatorKey: rootNavigatorKey as GlobalKey<NavigatorState>,
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
            textDirection: isAr == true ? TextDirection.rtl : TextDirection.ltr,
            child: child!,
          ),
          home: FoldersGalleryPage(license: widget.license),
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
  State createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final TextEditingController _codeController = TextEditingController();
  bool _isError = false;

  void _verify() async {
    final success = await LicenseManager.activate(widget.deviceId, _codeController.text);
    if (success == true) {
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
            builder: (_) => FoldersGalleryPage(license: {'valid': true, 'activated': true, 'id': widget.deviceId, 'days': 0}),
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
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E131D),
      appBar: AppBar(backgroundColor: const Color(0xFF0E131D), elevation: 0),
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
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
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
                    padding: const EdgeInsets.symmetric(horizontal:
