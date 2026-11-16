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

import 'parsers/emb_parser.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final ValueNotifier<bool> isArabicNotifier = ValueNotifier<bool>(true);

String tr(String ar, String en) => isArabicNotifier.value ? ar : en;
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
    } catch (e) {
      return {'valid': true, 'activated': false, 'id': '123456', 'days': 7};
    }
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
  final license = await LicenseManager.checkLicense();
  runApp(EmbGalleryApp(license: license));
}

class EmbGalleryApp extends StatefulWidget {
  final Map license;
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
    if (widget.license['valid'] == true) _setupIncomingFileHandler();
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
      if (call.method == 'onFileOpened' && call.arguments is String) {
        await _openIncomingEmbFile(call.arguments as String);
      }
    });
    try {
      final initialPath = await _intentChannel.invokeMethod<String>('getInitialFile');
      if (initialPath != null && initialPath.isNotEmpty) {
        await _openIncomingEmbFile(initialPath);
      }
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
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => DesignDetailScreen(design: info!)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isArabicNotifier,
      builder: (context, isAr, _) {
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
          builder: (context, child) => Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: child!,
          
