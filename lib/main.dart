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
final validExtensions = ['.emb', '.dst', '.dhp', '.dha', '.dhe', '.pes', '.pec', '.exp', '.ef', '.vp3', '.xxx', '.u01'];

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
    return await DstParser.parseFile(path);
  } else if (lower.endsWith('.emb')) {
    return await EmbParser.parseFile(path);
  } else if (lower.endsWith('.dhp') || lower.endsWith('.dha') || lower.endsWith('.dhe')) {
    return await DahaoParser.parseFile(path);
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
    final dir = Directory('${supportDir.path}/design_cache_v2');
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
            await img
