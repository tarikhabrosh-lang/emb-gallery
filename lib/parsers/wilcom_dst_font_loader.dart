import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';

typedef _JsonMap = Map<String, dynamic>;

/// محرك قراءة وتقطيع ملفات الفونطات العربية الأصلية بصيغة Tajima DST (A1, a3, a4)
/// البنية الفعلية للملفات الثلاثة: 6 صفوف = 133 حرفاً (18 + 21 + 23 + 23 + 38 + 10)
class WilcomDstFontLoader {
  static final Map<String, String> _jsonCache = {};

  // الصف 1 (18 حرفاً — منفصل)
  static const List<String> _row1Keys = [
    'ا.isol', 'أ.isol', 'إ.isol', 'آ.isol',
    'ب.isol', 'ت.isol', 'ث.isol', 'ج.isol', 'ح.isol', 'خ.isol',
    'د.isol', 'ذ.isol', 'ر.isol', 'ز.isol', 'س.isol', 'ش.isol',
    'ص.isol', 'ض.isol',
  ];

  // الصف 2 (21 حرفاً — منفصل + ئ + ء + لام ألف)
  static const List<String> _row2Keys = [
    'ط.isol', 'ظ.isol', 'ع.isol', 'غ.isol', 'ف.isol', 'ق.isol',
    'ك.isol', 'ل.isol', 'م.isol', 'ن.isol', 'ه.isol', 'ة.isol',
    'و.isol', 'ؤ.isol', 'ي.isol', 'ى.isol', 'ئ.isol', 'ء.isol',
    'لا.isol', 'لأ.isol', 'لإ.isol',
  ];

  // الصف 3 (23 حرفاً — أول الكلمة)
  static const List<String> _row3Keys = [
    'ب.init', 'ت.init', 'ث.init', 'ج.init', 'ح.init', 'خ.init',
    'س.init', 'ش.init', 'ص.init', 'ض.init', 'ط.init', 'ظ.init',
    'ع.init', 'غ.init', 'ف.init', 'ق.init', 'ك.init', 'ل.init',
    'م.init', 'ن.init', 'ه.init', 'ي.init', 'ئ.init',
  ];

  // الصف 4 (23 حرفاً — وسط الكلمة)
  static const List<String> _row4Keys = [
    'ب.medi', 'ت.medi', 'ث.medi', 'ج.medi', 'ح.medi', 'خ.medi',
    'س.medi', 'ش.medi', 'ص.medi', 'ض.medi', 'ط.medi', 'ظ.medi',
    'ع.medi', 'غ.medi', 'ف.medi', 'ق.medi', 'ك.medi', 'ل.medi',
    'م.medi', 'ن.medi', 'ه.medi', 'ي.medi', 'ئ.medi',
  ];

  // الصف 5 (38 حرفاً — آخر الكلمة في A1 و a3 و a4)
  static const List<String> _row5Keys38 = [
    'ا.fina', 'أ.fina', 'إ.fina', 'آ.fina',
    'ب.fina', 'ت.fina', 'ث.fina', 'ج.fina', 'ح.fina', 'خ.fina',
    'د.fina', 'ذ.fina', 'ر.fina', 'ز.fina', 'س.fina', 'ش.fina',
    'ص.fina', 'ض.fina', 'ط.fina', 'ظ.fina', 'ع.fina', 'غ.fina',
    'ف.fina', 'ق.fina', 'ك.fina', 'ل.fina', 'م.fina', 'ن.fina',
    'ه.fina', 'ة.fina', 'و.fina', 'ؤ.fina', 'ي.fina', 'ى.fina',
    'ئ.fina', 'لا.fina', 'لأ.fina', 'لإ.fina',
  ];

  // احتياطي لأي ملف مستقبلي بـ 37 حرفاً في الصف 5
  static const List<String> _row5Keys37 = [
    'ا.fina', 'أ.fina', 'إ.fina', 'آ.fina',
    'ب.fina', 'ت.fina', 'ث.fina', 'ج.fina', 'ح.fina', 'خ.fina',
    'د.fina', 'ذ.fina', 'ر.fina', 'ز.fina', 'س.fina', 'ش.fina',
    'ص.fina', 'ض.fina', 'ط.fina', 'ظ.fina', 'ع.fina', 'غ.fina',
    'ف.fina', 'ق.fina', 'ك.fina', 'ل.fina', 'م.fina', 'ن.fina',
    'ه.fina', 'ة.fina', 'و.fina', 'ؤ.fina', 'ي.fina', 'ى.fina',
    'لا.fina', 'لأ.fina', 'لإ.fina',
  ];

  // الصف 6 (10 أرقام عربية)
  static const List<String> _row6Keys = [
    '٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩',
  ];

  // فهارس الحروف المستقرة على السطر لحساب خط السطر (Baseline) بدقة
  static const List<List<int>> _baselineAnchorIndices = [
    [0, 1, 3, 4, 5, 6, 10, 11],
    [0, 1, 4, 6, 10, 11, 18, 19],
    [0, 1, 2, 6, 7, 8, 9, 10, 11, 14, 15, 16, 17, 19],
    [0, 1, 2, 6, 7, 8, 9, 10, 11, 14, 15, 16, 17, 19],
    [0, 1, 3, 4, 5, 6, 10, 11, 18, 19, 22, 24, 28, 29],
    [1, 2, 3, 4, 5, 6, 7, 8, 9],
  ];

  /// تحميل ملف DST من الأصول وتحويله مع التخزين المؤقت
  static Future<String?> loadFontJson({
    required String fontId,
    required String nameEn,
    required List<String> assetCandidates,
    required bool row5HasFinalYehHamza,
    double joinOverlapRatio = 0.032,
  }) async {
    final cached = _jsonCache[fontId];
    if (cached != null) return cached;

    Uint8List? bytes;
    for (final path in assetCandidates) {
      try {
        final bd = await rootBundle.load(path);
        bytes = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
        if (bytes.length > 512) break;
      } catch (_) {}
    }
    if (bytes == null || bytes.length <= 512) return null;

    final jsonStr = parseDstBytesToFontJson(
      bytes: bytes,
      nameEn: nameEn,
      row5HasFinalYehHamza: row5HasFinalYehHamza,
      joinOverlapRatio: joinOverlapRatio,
    );
    if (jsonStr != null) {
      _jsonCache[fontId] = jsonStr;
    }
    return jsonStr;
  }

  /// تحويل بايتات ملف DST إلى JSON جاهز لمحرك الكتابة
  static String? parseDstBytesToFontJson({
    required Uint8List bytes,
    required String nameEn,
    required bool row5HasFinalYehHamza,
    double joinOverlapRatio = 0.032,
  }) {
    final runs = _extractDstRuns(bytes);
    if (runs.length < 40) return null;

    final rows = _clusterIntoRows(runs, 6);
    if (rows.length != 6) return null;

    final row5NaturalClusters = _mergeOverlappingClusters(rows[4]);
    final bool use38Row5 = row5HasFinalYehHamza || row5NaturalClusters.length >= 38;

    final List<List<String>> rowKeyLists = [
      _row1Keys,
      _row2Keys,
      _row3Keys,
      _row4Keys,
      use38Row5 ? _row5Keys38 : _row5Keys37,
      _row6Keys,
    ];

    final Map<String, _JsonMap> glyphsMap = {};
    double capH = 180.0;

    for (int rIdx = 0; rIdx < 6; rIdx++) {
      final expectedKeys = rowKeyLists[rIdx];
      final clusters = _clusterRowRightToLeft(rows[rIdx], expectedKeys.length);
      if (clusters.isEmpty) continue;

      final double rowBaselineY = _estimateRowBaseline(
        clusters,
        _baselineAnchorIndices[rIdx],
      );

      final int count = math.min(clusters.length, expectedKeys.length);
      for (int i = 0; i < count; i++) {
        final key = expectedKeys[i];
        final cl = clusters[i];

        if (rIdx == 0 && i == 0) {
          final h = (cl.maxY - cl.minY).abs();
          if (h > 40.0) capH = h;
        }

        glyphsMap[key] = _buildGlyphJson(cl, rowBaselineY);
      }
    }

    if (glyphsMap.isEmpty) return null;

    // إصلاح تلقائي لحرف (ئ.isol) إذا كانت خانته تحتوي على همزة صغيرة فقط (مثل A1.DST)
    if (glyphsMap.containsKey('ى.isol')) {
      final double yehW = (glyphsMap['ى.isol']!['w'] as num).toDouble();
      final double? hamzaYehW = glyphsMap['ئ.isol'] != null
          ? (glyphsMap['ئ.isol']!['w'] as num).toDouble()
          : null;
      if (hamzaYehW == null || hamzaYehW < yehW * 0.65) {
        glyphsMap['ئ.isol'] = _synthesizeFinalYehHamza(
          glyphsMap['ى.isol']!,
          glyphsMap['ء.isol'],
          capH,
        );
      }
    }

    // تركيب احتياطي لحرف (ئ.fina) إن غاب في أي ملف مستقبلي
    if (!glyphsMap.containsKey('ئ.fina') && glyphsMap.containsKey('ى.fina')) {
      glyphsMap['ئ.fina'] = _synthesizeFinalYehHamza(
        glyphsMap['ى.fina']!,
        glyphsMap['ء.isol'],
        capH,
      );
    }

    // بدائل آمنة للام ألف ممدودة والهمزة المتطرفة
    if (!glyphsMap.containsKey('لآ.isol') && glyphsMap.containsKey('لا.isol')) {
      glyphsMap['لآ.isol'] = glyphsMap['لأ.isol'] ?? glyphsMap['لا.isol']!;
    }
    if (!glyphsMap.containsKey('لآ.fina') && glyphsMap.containsKey('لا.fina')) {
      glyphsMap['لآ.fina'] = glyphsMap['لأ.fina'] ?? glyphsMap['لا.fina']!;
    }
    if (!glyphsMap.containsKey('ء.fina') && glyphsMap.containsKey('ء.isol')) {
      glyphsMap['ء.fina'] = glyphsMap['ء.isol']!;
    }

    // ربط الأرقام الإنجليزية 0-9 مباشرة بالأرقام العربية المطرزة ٠-٩
    const asciiDigits = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
    for (int d = 0; d < 10; d++) {
      final arDigit = glyphsMap[_row6Keys[d]];
      if (arDigit != null) {
        glyphsMap[asciiDigits[d]] = arDigit;
      }
    }

    final _JsonMap fontObj = {
      'nameEn': nameEn,
      'rtl': true,
      'nativeStitch': true,
      'capH': _r1(capH),
      'spaceW': _r1(capH * 0.58),
      'letterSp': _r1(capH * 0.08),
      'lineH': _r1(capH * 1.48),
      'joinOverlap': _r1(capH * joinOverlapRatio),
      'glyphs': glyphsMap,
    };

    return jsonEncode(fontObj);
  }

  static List<_DstRun> _extractDstRuns(Uint8List bytes) {
    final List<_DstRun> runs = [];
    List<double> curPts = [];

    double cx = 0.0;
    double cy = 0.0;

    void flushRun() {
      if (curPts.length >= 4) {
        runs.add(_DstRun.fromPoints(curPts));
      }
      curPts = [];
    }

    int offset = 512;
    while (offset + 2 < bytes.length) {
      final int b0 = bytes[offset];
      final int b1 = bytes[offset + 1];
      final int b2 = bytes[offset + 2];
      offset += 3;

      if (b2 == 0xF3) break;

      int dx = 0;
      int dyDst = 0;

      if ((b0 & 0x01) != 0) dx += 1;
      if ((b0 & 0x02) != 0) dx -= 1;
      if ((b0 & 0x04) != 0) dx += 9;
      if ((b0 & 0x08) != 0) dx -= 9;
      if ((b0 & 0x80) != 0) dyDst += 1;
      if ((b0 & 0x40) != 0) dyDst -= 1;
      if ((b0 & 0x20) != 0) dyDst += 9;
      if ((b0 & 0x10) != 0) dyDst -= 9;

      if ((b1 & 0x01) != 0) dx += 3;
      if ((b1 & 0x02) != 0) dx -= 3;
      if ((b1 & 0x04) != 0) dx += 27;
      if ((b1 & 0x08) != 0) dx -= 27;
      if ((b1 & 0x80) != 0) dyDst += 3;
      if ((b1 & 0x40) != 0) dyDst -= 3;
      if ((b1 & 0x20) != 0) dyDst += 27;
      if ((b1 & 0x10) != 0) dyDst -= 27;

      if ((b2 & 0x04) != 0) dx += 81;
      if ((b2 & 0x08) != 0) dx -= 81;
      if ((b2 & 0x20) != 0) dyDst += 81;
      if ((b2 & 0x10) != 0) dyDst -= 81;

      final bool isJump = (b2 & 0x80) != 0;
      final bool isStop = (b2 & 0xC3) == 0xC3;

      cx += dx;
      cy -= dyDst;

      if (isJump || isStop) {
        flushRun();
      } else {
        curPts.add(cx);
        curPts.add(cy);
      }
    }
    flushRun();
    return runs;
  }

  static List<List<_DstRun>> _clusterIntoRows(List<_DstRun> runs, int numRows) {
    if (runs.isEmpty) return const [];

    final heights = runs.map((r) => r.height).toList()..sort();
    final double medH = heights[heights.length ~/ 2];
    final majorRuns = runs
        .where((r) => r.height >= medH * 0.45 || r.pts.length >= 40)
        .toList();
    final baseList = majorRuns.length >= numRows * 2 ? majorRuns : List<_DstRun>.from(runs);
    baseList.sort((a, b) => a.centerY.compareTo(b.centerY));

    final List<({int splitIdx, double gap})> gaps = [];
    for (int i = 0; i < baseList.length - 1; i++) {
      final double g = baseList[i + 1].centerY - baseList[i].centerY;
      gaps.add((splitIdx: i + 1, gap: g));
    }
    gaps.sort((a, b) => b.gap.compareTo(a.gap));
    final splitIndices = gaps
        .take(numRows - 1)
        .map((e) => e.splitIdx)
        .toList()
      ..sort();

    final List<({double minY, double maxY, double centerY})> rowBands = [];
    int start = 0;
    for (int s = 0; s <= splitIndices.length; s++) {
      final int end = s < splitIndices.length ? splitIndices[s] : baseList.length;
      final slice = baseList.sublist(start, end);
      double rMinY = double.infinity;
      double rMaxY = -double.infinity;
      double sumCy = 0.0;
      for (final r in slice) {
        if (r.minY < rMinY) rMinY = r.minY;
        if (r.maxY > rMaxY) rMaxY = r.maxY;
        sumCy += r.centerY;
      }
      rowBands.add((
        minY: rMinY,
        maxY: rMaxY,
        centerY: sumCy / math.max(1, slice.length),
      ));
      start = end;
    }

    final List<List<_DstRun>> result = List.generate(numRows, (_) => []);
    for (final run in runs) {
      int bestRow = 0;
      double bestScore = double.infinity;
      for (int r = 0; r < rowBands.length; r++) {
        final b = rowBands[r];
        double distToBand = 0.0;
        if (run.centerY < b.minY) {
          distToBand = b.minY - run.centerY;
        } else if (run.centerY > b.maxY) {
          distToBand = run.centerY - b.maxY;
        }
        final double score = distToBand * 4.0 + (run.centerY - b.centerY).abs();
        if (score < bestScore) {
          bestScore = score;
          bestRow = r;
        }
      }
      result[bestRow].add(run);
    }

    return result;
  }

  static List<_GlyphCluster> _mergeOverlappingClusters(List<_DstRun> rowRuns) {
    final List<_GlyphCluster> clusters = rowRuns
        .map((r) => _GlyphCluster([r]))
        .toList();

    bool merged = true;
    while (merged) {
      merged = false;
      clusters.sort((a, b) => a.minX.compareTo(b.minX));
      for (int i = 0; i < clusters.length - 1; i++) {
        if (clusters[i + 1].minX <= clusters[i].maxX + 1.5) {
          clusters[i].absorb(clusters[i + 1]);
          clusters.removeAt(i + 1);
          merged = true;
          break;
        }
      }
    }
    return clusters;
  }

  static List<_GlyphCluster> _clusterRowRightToLeft(
    List<_DstRun> rowRuns,
    int expectedCount,
  ) {
    if (rowRuns.isEmpty) return const [];

    final List<_GlyphCluster> clusters = _mergeOverlappingClusters(rowRuns);

    if (clusters.length > expectedCount) {
      final avgH = clusters.fold<double>(0.0, (s, c) => s + c.height) / clusters.length;
      while (clusters.length > expectedCount) {
        clusters.sort((a, b) => a.minX.compareTo(b.minX));
        int bestIdx = 0;
        double bestCost = double.infinity;
        for (int i = 0; i < clusters.length - 1; i++) {
          final cA = clusters[i];
          final cB = clusters[i + 1];
          final double gap = math.max(0.0, cB.minX - cA.maxX);
          final bool tinyA = cA.height < avgH * 0.48 && cA.width < avgH * 0.65;
          final bool tinyB = cB.height < avgH * 0.48 && cB.width < avgH * 0.65;
          final double weight = (tinyA || tinyB) ? 0.35 : 1.0;
          final double cost = gap * weight;
          if (cost < bestCost) {
            bestCost = cost;
            bestIdx = i;
          }
        }
        clusters[bestIdx].absorb(clusters[bestIdx + 1]);
        clusters.removeAt(bestIdx + 1);
      }
    }

    clusters.sort((a, b) => b.centerX.compareTo(a.centerX));
    return clusters;
  }

  static double _estimateRowBaseline(
    List<_GlyphCluster> clusters,
    List<int> anchorIndices,
  ) {
    final List<double> ys = [];
    for (final idx in anchorIndices) {
      if (idx >= 0 && idx < clusters.length) {
        ys.add(clusters[idx].maxY);
      }
    }
    if (ys.isEmpty) {
      for (final c in clusters) {
        ys.add(c.maxY);
      }
    }
    ys.sort();
    return ys[ys.length ~/ 2];
  }

  static _JsonMap _buildGlyphJson(
    _GlyphCluster cluster,
    double rowBaselineY,
  ) {
    final double ox = cluster.minX;
    final double w = math.max(8.0, cluster.maxX - cluster.minX);
    final List<_JsonMap> elements = [];

    for (final run in cluster.runs) {
      final List<double> normPts = List<double>.filled(run.pts.length, 0.0);
      for (int i = 0; i < run.pts.length; i += 2) {
        normPts[i] = _r1(run.pts[i] - ox);
        normPts[i + 1] = _r1(run.pts[i + 1] - rowBaselineY);
      }
      elements.add({'t': 'd', 'p': normPts});
    }

    return {
      'w': _r1(w),
      'a': _r1(w),
      'e': elements,
    };
  }

  static _JsonMap _synthesizeFinalYehHamza(
    _JsonMap baseYeh,
    _JsonMap? hamzaGlyph,
    double capH,
  ) {
    final double baseW = (baseYeh['w'] as num).toDouble();
    final List<dynamic> baseEls = baseYeh['e'] as List<dynamic>;
    final List<_JsonMap> outEls = [];
    for (final el in baseEls) {
      outEls.add(_JsonMap.from(el as Map));
    }

    if (hamzaGlyph != null) {
      final double hW = (hamzaGlyph['w'] as num).toDouble();
      final List<dynamic> hEls = hamzaGlyph['e'] as List<dynamic>;
      double hMinY = double.infinity, hMaxY = -double.infinity;
      for (final el in hEls) {
        final pts = el['p'] as List<dynamic>;
        for (int i = 1; i < pts.length; i += 2) {
          final y = (pts[i] as num).toDouble();
          if (y < hMinY) hMinY = y;
          if (y > hMaxY) hMaxY = y;
        }
      }
      if (hMinY.isFinite) {
        final double shiftX = (baseW - hW) * 0.52;
        final double targetBottomY = -capH * 0.38;
        final double shiftY = targetBottomY - hMaxY;
        for (final el in hEls) {
          final pts = el['p'] as List<dynamic>;
          final List<double> shifted = List<double>.filled(pts.length, 0.0);
          for (int i = 0; i < pts.length; i += 2) {
            shifted[i] = _r1((pts[i] as num).toDouble() + shiftX);
            shifted[i + 1] = _r1((pts[i + 1] as num).toDouble() + shiftY);
          }
          outEls.add({'t': 'd', 'p': shifted});
        }
      }
    }

    return {
      'w': _r1(baseW),
      'a': _r1(baseW),
      'e': outEls,
    };
  }

  static double _r1(double v) => (v * 10.0).roundToDouble() / 10.0;
}

class _DstRun {
  final List<double> pts;
  final double minX, maxX, minY, maxY;

  const _DstRun({
    required this.pts,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  factory _DstRun.fromPoints(List<double> pts) {
    double mnX = double.infinity, mxX = -double.infinity;
    double mnY = double.infinity, mxY = -double.infinity;
    for (int i = 0; i < pts.length; i += 2) {
      final x = pts[i];
      final y = pts[i + 1];
      if (x < mnX) mnX = x;
      if (x > mxX) mxX = x;
      if (y < mnY) mnY = y;
      if (y > mxY) mxY = y;
    }
    return _DstRun(pts: pts, minX: mnX, maxX: mxX, minY: mnY, maxY: mxY);
  }

  double get width => maxX - minX;
  double get height => maxY - minY;
  double get centerY => (minY + maxY) * 0.5;
}

class _GlyphCluster {
  final List<_DstRun> runs;
  double minX, maxX, minY, maxY;

  _GlyphCluster(List<_DstRun> initial)
      : runs = List<_DstRun>.from(initial),
        minX = initial.first.minX,
        maxX = initial.first.maxX,
        minY = initial.first.minY,
        maxY = initial.first.maxY;

  void absorb(_GlyphCluster other) {
    runs.addAll(other.runs);
    if (other.minX < minX) minX = other.minX;
    if (other.maxX > maxX) maxX = other.maxX;
    if (other.minY < minY) minY = other.minY;
    if (other.maxY > maxY) maxY = other.maxY;
  }

  double get width => maxX - minX;
  double get height => maxY - minY;
  double get centerX => (minX + maxX) * 0.5;
}
