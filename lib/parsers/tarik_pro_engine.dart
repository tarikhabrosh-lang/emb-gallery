import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'emb_parser.dart';
import 'wilcom_dst_font_loader.dart';

/// كتالوج الفونطات الموحّد:
/// - يقرأ الفونطات العربية الجديدة (A1, A3, A4) مباشرةً من ملفات .DST الأصلية في assets/emb_fonts/
/// - يحافظ على فونط A2 (رسم أبو وسيم) وفونطات E1..E4 المدمجة في emb_parser.dart بنسبة 100% دون تعديلها
class TarikProFontCatalog {
  static List<EmbFontMeta>? _cachedIndex;
  static final Map<String, String> _rawFontCache = {};

  static const EmbFontMeta _metaA1 = EmbFontMeta(
    id: 'wilcom_a1',
    nameAr: 'A1',
    nameEn: 'A1',
    rtl: true,
    capH: 260.0,
    spaceW: 150.0,
    letterSp: 21.0,
    lineH: 385.0,
    minScale: 0.40,
    maxScale: 2.8,
    glyphCount: 133,
    file: 'dst_asset://A1.DST',
  );

  static const EmbFontMeta _metaA3 = EmbFontMeta(
    id: 'wilcom_a3',
    nameAr: 'A3',
    nameEn: 'A3',
    rtl: true,
    capH: 260.0,
    spaceW: 150.0,
    letterSp: 21.0,
    lineH: 385.0,
    minScale: 0.40,
    maxScale: 2.8,
    glyphCount: 133,
    file: 'dst_asset://a3.DST',
  );

  static const EmbFontMeta _metaA4 = EmbFontMeta(
    id: 'wilcom_a4',
    nameAr: 'A4',
    nameEn: 'A4',
    rtl: true,
    capH: 260.0,
    spaceW: 150.0,
    letterSp: 21.0,
    lineH: 385.0,
    minScale: 0.40,
    maxScale: 2.8,
    glyphCount: 133,
    file: 'dst_asset://a4.DST',
  );

  static Future<List<EmbFontMeta>> loadIndex() async {
    if (_cachedIndex != null) return _cachedIndex!;

    final List<EmbFontMeta> base = await InkStitchFontCatalog.loadIndex();
    final List<EmbFontMeta> merged = [];
    final Set<String> seenIds = {};
    final Set<String> seenCodes = {};

    void addUnique(EmbFontMeta f) {
      final code = f.nameEn.trim().toUpperCase();
      if (seenIds.contains(f.id) || (code.isNotEmpty && seenCodes.contains(code))) {
        return;
      }
      merged.add(f);
      seenIds.add(f.id);
      if (code.isNotEmpty) seenCodes.add(code);
    }

    // 1) A1 من ملف A1.DST
    addUnique(_metaA1);

    // 2) A2 الأصلي المحفوظ من emb_parser.dart أولاً
    for (final f in base) {
      if (f.nameEn.trim().toUpperCase() == 'A2' || f.id == 'wilcom_a2') {
        addUnique(f);
      }
    }

    // 3) A3 و A4 من ملفي a3.DST و a4.DST
    addUnique(_metaA3);
    addUnique(_metaA4);

    // 4) بقية الفونطات (E1..E4 وأي خطوط إضافية)
    for (final f in base) {
      addUnique(f);
    }

    _cachedIndex = merged;
    return _cachedIndex!;
  }

  static Future<String?> loadRawFontJson(EmbFontMeta meta) async {
    final cached = _rawFontCache[meta.id];
    if (cached != null) return cached;

    String? raw;
    if (meta.id == 'wilcom_a1') {
      raw = await WilcomDstFontLoader.loadFontJson(
        fontId: 'wilcom_a1',
        nameEn: 'A1',
        assetCandidates: const [
          'assets/emb_fonts/A1.DST',
          'assets/emb_fonts/a1.dst',
          'assets/emb_fonts/A1.dst',
          'assets/emb_fonts/a1.DST',
        ],
        row5HasFinalYehHamza: true,
        joinOverlapRatio: 0.032,
      );
    } else if (meta.id == 'wilcom_a3') {
      raw = await WilcomDstFontLoader.loadFontJson(
        fontId: 'wilcom_a3',
        nameEn: 'A3',
        assetCandidates: const [
          'assets/emb_fonts/a3.DST',
          'assets/emb_fonts/A3.DST',
          'assets/emb_fonts/a3.dst',
          'assets/emb_fonts/A3.dst',
        ],
        row5HasFinalYehHamza: true,
        joinOverlapRatio: 0.028,
      );
    } else if (meta.id == 'wilcom_a4') {
      raw = await WilcomDstFontLoader.loadFontJson(
        fontId: 'wilcom_a4',
        nameEn: 'A4',
        assetCandidates: const [
          'assets/emb_fonts/a4.DST',
          'assets/emb_fonts/A4.DST',
          'assets/emb_fonts/a4.dst',
          'assets/emb_fonts/A4.dst',
        ],
        row5HasFinalYehHamza: true,
        joinOverlapRatio: 0.032,
      );
    } else {
      raw = await InkStitchFontCatalog.loadRawFontJson(meta);
    }

    if (raw != null && raw.isNotEmpty) {
      _rawFontCache[meta.id] = raw;
    }
    return raw;
  }
}

class _ProFloat32Buf {
  Float32List _buf;
  int length = 0;
  _ProFloat32Buf([int initialCapacity = 4096]) : _buf = Float32List(initialCapacity);

  void add(double v) {
    if (length == _buf.length) {
      final next = Float32List(_buf.length * 2);
      next.setRange(0, length, _buf);
      _buf = next;
    }
    _buf[length++] = v;
  }

  Float32List finish() => Float32List.sublistView(_buf, 0, length);
}

class _ProUint8Buf {
  Uint8List _buf;
  int length = 0;
  _ProUint8Buf([int initialCapacity = 4096]) : _buf = Uint8List(initialCapacity);

  void add(int v) {
    if (length == _buf.length) {
      final next = Uint8List(_buf.length * 2);
      next.setRange(0, length, _buf);
      _buf = next;
    }
    _buf[length++] = v;
  }

  Uint8List finish() => Uint8List.sublistView(_buf, 0, length);
}

class _ProShapedToken {
  final String shaped;
  final String dotForm;
  final String base;
  final bool connectsLeft;
  final bool connectsRight;
  final bool isSpace;

  const _ProShapedToken({
    required this.shaped,
    this.dotForm = '',
    required this.base,
    this.connectsLeft = false,
    this.connectsRight = false,
    this.isSpace = false,
  });
}

/// مشكّل الحروف العربية السياقي (يدعم أول/وسط/آخر/منفصل + لام ألف + الأرقام العربية والإنجليزية)
class ProArabicShaper {
  static const Map<int, List<String>> _forms = {
    0x0621: ['\uFE80', '\uFE80', '', ''], // ء
    0x0622: ['\uFE81', '\uFE82', '', ''], // آ
    0x0623: ['\uFE83', '\uFE84', '', ''], // أ
    0x0624: ['\uFE85', '\uFE86', '', ''], // ؤ
    0x0625: ['\uFE87', '\uFE88', '', ''], // إ
    0x0626: ['\uFE89', '\uFE8A', '\uFE8B', '\uFE8C'], // ئ
    0x0627: ['\uFE8D', '\uFE8E', '', ''], // ا
    0x0628: ['\uFE8F', '\uFE90', '\uFE91', '\uFE92'], // ب
    0x0629: ['\uFE93', '\uFE94', '', ''], // ة
    0x062A: ['\uFE95', '\uFE96', '\uFE97', '\uFE98'], // ت
    0x062B: ['\uFE99', '\uFE9A', '\uFE9B', '\uFE9C'], // ث
    0x062C: ['\uFE9D', '\uFE9E', '\uFE9F', '\uFEA0'], // ج
    0x062D: ['\uFEA1', '\uFEA2', '\uFEA3', '\uFEA4'], // ح
    0x062E: ['\uFEA5', '\uFEA6', '\uFEA7', '\uFEA8'], // خ
    0x062F: ['\uFEA9', '\uFEAA', '', ''], // د
    0x0630: ['\uFEAB', '\uFEAC', '', ''], // ذ
    0x0631: ['\uFEAD', '\uFEAE', '', ''], // ر
    0x0632: ['\uFEAF', '\uFEB0', '', ''], // ز
    0x0633: ['\uFEB1', '\uFEB2', '\uFEB3', '\uFEB4'], // س
    0x0634: ['\uFEB5', '\uFEB6', '\uFEB7', '\uFEB8'], // ش
    0x0635: ['\uFEB9', '\uFEBA', '\uFEBB', '\uFEBC'], // ص
    0x0636: ['\uFEBD', '\uFEBE', '\uFEBF', '\uFEC0'], // ض
    0x0637: ['\uFEC1', '\uFEC2', '\uFEC3', '\uFEC4'], // ط
    0x0638: ['\uFEC5', '\uFEC6', '\uFEC7', '\uFEC8'], // ظ
    0x0639: ['\uFEC9', '\uFECA', '\uFECB', '\uFECC'], // ع
    0x063A: ['\uFECD', '\uFECE', '\uFECF', '\uFED0'], // غ
    0x0640: ['\u0640', '\u0640', '\u0640', '\u0640'], // ـ
    0x0641: ['\uFED1', '\uFED2', '\uFED3', '\uFED4'], // ف
    0x0642: ['\uFED5', '\uFED6', '\uFED7', '\uFED8'], // ق
    0x0643: ['\uFED9', '\uFEDA', '\uFEDB', '\uFEDC'], // ك
    0x0644: ['\uFEDD', '\uFEDE', '\uFEDF', '\uFEE0'], // ل
    0x0645: ['\uFEE1', '\uFEE2', '\uFEE3', '\uFEE4'], // م
    0x0646: ['\uFEE5', '\uFEE6', '\uFEE7', '\uFEE8'], // ن
    0x0647: ['\uFEE9', '\uFEEA', '\uFEEB', '\uFEEC'], // ه
    0x0648: ['\uFEED', '\uFEEE', '', ''], // و
    0x0649: ['\uFEEF', '\uFEF0', '', ''], // ى
    0x064A: ['\uFEF1', '\uFEF2', '\uFEF3', '\uFEF4'], // ي
  };

  static const Map<int, List<String>> _lamAlef = {
    0x0622: ['\uFEF5', '\uFEF6'], // لآ
    0x0623: ['\uFEF7', '\uFEF8'], // لأ
    0x0625: ['\uFEF9', '\uFEFA'], // لإ
    0x0627: ['\uFEFB', '\uFEFC'], // لا
  };

  static int _normalizeCp(int cp) {
    if (cp == 0x06CC) return 0x064A; // ی -> ي
    if (cp == 0x06A9) return 0x0643; // ک -> ك
    return cp;
  }

  static bool _isTashkeel(int cp) => (cp >= 0x064B && cp <= 0x065F) || cp == 0x0670;
  static bool _isArabicLetter(int cp) => _forms.containsKey(cp);
  static bool _canConnectLeft(int cp) {
    final f = _forms[cp];
    return f != null && f[2].isNotEmpty;
  }

  static bool _canConnectRight(int cp) => _forms.containsKey(cp) && cp != 0x0621;

  static bool containsArabic(String s) {
    for (int i = 0; i < s.length; i++) {
      final cp = s.codeUnitAt(i);
      if ((cp >= 0x0600 && cp <= 0x06FF) || (cp >= 0xFE70 && cp <= 0xFEFF)) return true;
    }
    return false;
  }

  static List<_ProShapedToken> shapeLine(String line, {required bool isRtl}) {
    final List<int> cps = line.runes
        .where((cp) => !_isTashkeel(cp))
        .map(_normalizeCp)
        .toList();
    final List<_ProShapedToken> out = [];

    int i = 0;
    while (i < cps.length) {
      final int cp = cps[i];
      if (cp == 0x20 || cp == 0x09) {
        out.add(const _ProShapedToken(shaped: ' ', base: ' ', isSpace: true));
        i++;
        continue;
      }

      if (!_isArabicLetter(cp)) {
        final s = String.fromCharCode(cp);
        out.add(_ProShapedToken(shaped: s, base: s));
        i++;
        continue;
      }

      final bool prevConn = i > 0 && _canConnectLeft(cps[i - 1]);

      if (cp == 0x0644 && i + 1 < cps.length && _lamAlef.containsKey(cps[i + 1])) {
        final lig = _lamAlef[cps[i + 1]]!;
        final String shaped = prevConn ? lig[1] : lig[0];
        final String baseLig = 'ل${String.fromCharCode(cps[i + 1])}';
        final String dotLig = '$baseLig.${prevConn ? 'fina' : 'isol'}';
        out.add(_ProShapedToken(
          shaped: shaped,
          dotForm: dotLig,
          base: baseLig,
          connectsLeft: false,
          connectsRight: prevConn,
        ));
        i += 2;
        continue;
      }

      final bool nextConn = i + 1 < cps.length && _canConnectRight(cps[i + 1]);
      final bool leftConn = _canConnectLeft(cp) && nextConn;
      final bool rightConn = _canConnectRight(cp) && prevConn;
      final forms = _forms[cp]!;
      final String baseChar = String.fromCharCode(cp);

      String shaped;
      String suffix;
      if (rightConn && leftConn) {
        shaped = forms[3];
        suffix = 'medi';
      } else if (leftConn) {
        shaped = forms[2];
        suffix = 'init';
      } else if (rightConn) {
        shaped = forms[1];
        suffix = 'fina';
      } else {
        shaped = forms[0];
        suffix = 'isol';
      }
      out.add(_ProShapedToken(
        shaped: shaped,
        dotForm: '$baseChar.$suffix',
        base: baseChar,
        connectsLeft: leftConn,
        connectsRight: rightConn,
      ));
      i++;
    }

    if (isRtl) {
      int k = 0;
      while (k < out.length) {
        final cp = out[k].base.isNotEmpty ? out[k].base.codeUnitAt(0) : 0;
        final bool isLtrRun = (cp >= 0x30 && cp <= 0x39) ||
            (cp >= 0x0660 && cp <= 0x0669) ||
            (cp >= 0x41 && cp <= 0x5A) ||
            (cp >= 0x61 && cp <= 0x7A);
        if (!isLtrRun) {
          k++;
          continue;
        }
        int end = k + 1;
        while (end < out.length) {
          final ecp = out[end].base.isNotEmpty ? out[end].base.codeUnitAt(0) : 0;
          final bool ok = (ecp >= 0x30 && ecp <= 0x39) ||
              (ecp >= 0x0660 && ecp <= 0x0669) ||
              (ecp >= 0x41 && ecp <= 0x5A) ||
              (ecp >= 0x61 && ecp <= 0x7A) ||
              ecp == 0x2E ||
              ecp == 0x2D;
          if (!ok) break;
          end++;
        }
        if (end - k > 1) {
          final sub = out.sublist(k, end).reversed.toList();
          out.replaceRange(k, end, sub);
        }
        k = end;
      }
    }

    return out;
  }
}

/// محرك الكتابة المطوّر (جيل Pro v5):
/// - تقويس دائري حقيقي (Wilcom Arc / Circle / Wave) تدور معه الحروف بانسيابية
/// - تعريض وتضييق فستون حقيقي متماسك بدون تفتّت
/// - تقسيم تلقائي مضمون بعد التكبير النهائي (Post-Scale Auto-Split > 8 مم) مع تدرّج تاتامي ناعم
class TarikProFontEngine {
  static Future<VectorDesignData?> generate({
    required EmbFontMeta meta,
    required String text,
    double letterHeightCm = 2.5,
    double? targetWidthCm,
    double? targetHeightCm,
    double densityMm = 0.45,
    double extraSpacingMm = 0.0,
    double satinWidthOffsetMm = 0.0,
    bool autoSplit8Mm = true,
    String pathMode = 'linear',
    double pathParam = 0.35,
    double rotationDeg = 0.0,
    int underlayMode = 1,
    int colorArgb = 0xFFFF1744,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final rawJson = await TarikProFontCatalog.loadRawFontJson(meta);
    if (rawJson == null || rawJson.isEmpty) return null;

    return await Isolate.run(() {
      VectorDesignData? raw = _generateSync(
        rawJson: rawJson,
        text: trimmed,
        letterHeightCm: letterHeightCm,
        densityMm: densityMm,
        extraSpacingMm: extraSpacingMm,
        satinWidthOffsetMm: satinWidthOffsetMm,
        autoSplit8Mm: false, // نقسّم بدقة بعد ضبط المقاس النهائي!
        pathMode: pathMode,
        pathParam: pathParam,
        underlayMode: underlayMode,
        colorArgb: colorArgb,
      );
      if (raw == null) return null;

      double sx = 1.0, sy = 1.0;
      if (targetWidthCm != null || targetHeightCm != null) {
        final double curW = (raw.widthMm ?? 0.0) / 10.0;
        final double curH = (raw.heightMm ?? 0.0) / 10.0;
        if (curW > 0.1 && curH > 0.1) {
          sx = targetWidthCm != null
              ? (targetWidthCm / curW).clamp(0.20, 5.0)
              : (targetHeightCm! / curH).clamp(0.20, 5.0);
          sy = targetHeightCm != null
              ? (targetHeightCm / curH).clamp(0.20, 5.0)
              : sx;
        }
      }

      // إذا كبّر المستخدم المقاس بدرجة كبيرة، نُعيد التوليد مباشرةً بالارتفاع الحقيقي حتى تكون الكثافة وتعريض الفستون بالمليمتر الحقيقي!
      if ((sx - 1.0).abs() > 0.12 && targetHeightCm == null) {
        final double adjustedHeightCm = (letterHeightCm * sx).clamp(0.6, 20.0);
        final VectorDesignData? scaledRaw = _generateSync(
          rawJson: rawJson,
          text: trimmed,
          letterHeightCm: adjustedHeightCm,
          densityMm: densityMm,
          extraSpacingMm: extraSpacingMm,
          satinWidthOffsetMm: satinWidthOffsetMm,
          autoSplit8Mm: false,
          pathMode: pathMode,
          pathParam: pathParam,
          underlayMode: underlayMode,
          colorArgb: colorArgb,
        );
        if (scaledRaw != null) {
          raw = scaledRaw;
          final double curW2 = (raw.widthMm ?? 0.0) / 10.0;
          if (targetWidthCm != null && curW2 > 0.1) {
            sx = (targetWidthCm / curW2).clamp(0.5, 2.0);
            sy = sx;
          } else {
            sx = 1.0;
            sy = 1.0;
          }
        }
      }

      final bool isWilcomNative = raw.machineType.contains('Wilcom');
      final double dFactor = isWilcomNative
          ? (0.45 / densityMm.clamp(0.25, 1.0)).clamp(0.55, 1.85)
          : 1.0;
      final bool hasRot = rotationDeg.abs() > 0.05;

      VectorDesignData out = raw;
      if ((sx - 1.0).abs() > 0.015 ||
          (sy - 1.0).abs() > 0.015 ||
          hasRot) {
        out = VectorDesignEditor.transform(
          out,
          scaleX: sx,
          scaleY: sy,
          rotationDeg: rotationDeg,
          densityFactor: 1.0, // نطبّق كثافة الفستون النظيفة بدالة مخصصة تحافظ على أزواج الزكزاك
        );
      }

      // تعديل كثافة الفستون بدون تفتيت الغرز
      if ((dFactor - 1.0).abs() > 0.05) {
        out = _adjustSatinDensityClean(out, dFactor);
      }

      // تقسيم تلقائي مضمون للغرز العريضة > 8 مم بعد الوصول للمقاس النهائي (Wilcom Auto-Split)
      if (autoSplit8Mm) {
        out = _applyPostScaleAutoSplit(out, maxStitchMm: 8.0);
      }

      return out;
    });
  }

  /// تقسيم تلقائي احترافي بعد التكبير النهائي: أي غرزة فستون أطول من 8 مم تُقسّم بتدرّج حريري متناوب بدون فراغات أو تفتّت
  static VectorDesignData _applyPostScaleAutoSplit(
    VectorDesignData src, {
    double maxStitchMm = 8.0,
  }) {
    final int n = src.stX.length;
    if (n < 2) return src;
    final double maxUnits = maxStitchMm.clamp(4.5, 11.0) * 10.0;

    final stX = _ProFloat32Buf(n + 512);
    final stY = _ProFloat32Buf(n + 512);
    final stMove = _ProUint8Buf(n + 512);
    final stColor = _ProUint8Buf(n + 512);

    int rowCounter = 0;
    for (int i = 0; i < n; i++) {
      final double px = src.stX[i];
      final double py = src.stY[i];
      final int mv = src.stMove[i];
      final int col = src.stColor[i];

      if (i > 0 && mv == 0 && col == src.stColor[i - 1]) {
        final double prevX = src.stX[i - 1];
        final double prevY = src.stY[i - 1];
        final double dx = px - prevX;
        final double dy = py - prevY;
        final double len = math.sqrt(dx * dx + dy * dy);

        // نقسم فقط الغرز الفستونية الحقيقية (> 8 مم وحتى 60 مم) — أما القفزات الضخمة فلا نلمسها
        if (len > maxUnits && len < 600.0) {
          final int parts = (len / (maxUnits * 0.56)).ceil().clamp(2, 10);
          // إزاحة متدرجة عبر 4 صفوف لتفادي ظهور خط شق مستقيم في وسط الحرف (Tatami Stagger)
          const offsets = [0.0, 0.18, -0.14, 0.08];
          final double stagger = offsets[rowCounter & 3];
          for (int k = 1; k < parts; k++) {
            final double rawT = (k / parts) + (stagger / parts);
            final double t = rawT.clamp(0.12, 0.88);
            stX.add(prevX + dx * t);
            stY.add(prevY + dy * t);
            stMove.add(0);
            stColor.add(col);
          }
          rowCounter++;
        }
      }

      stX.add(px);
      stY.add(py);
      stMove.add(mv);
      stColor.add(col);
    }

    return VectorDesignData(
      stX: stX.finish(),
      stY: stY.finish(),
      stMove: stMove.finish(),
      stColor: stColor.finish(),
      stDev: src.stDev,
      seqX: src.seqX,
      seqY: src.seqY,
      seqCode: src.seqCode,
      beadX: src.beadX,
      beadY: src.beadY,
      beadCode: src.beadCode,
      paletteArgb: src.paletteArgb,
      stitches: stX.length,
      colorCount: src.colorCount,
      stopsCount: src.stopsCount,
      jumpsCount: src.jumpsCount,
      sequinsCount: src.sequinsCount,
      beadsCount: src.beadsCount,
      trimsCount: src.trimsCount,
      minX: src.minX,
      maxX: src.maxX,
      minY: src.minY,
      maxY: src.maxY,
      hasBounds: src.hasBounds,
      machineType: src.machineType,
    );
  }

  /// تعديل كثافة الفستون على أزواج الغرز (بدون كسر الزكزاك أو تفتيت الحروف)
  static VectorDesignData _adjustSatinDensityClean(VectorDesignData src, double factor) {
    final int n = src.stX.length;
    if (n < 6 || (factor - 1.0).abs() <= 0.05) return src;

    final stX = _ProFloat32Buf((n * factor).ceil() + 64);
    final stY = _ProFloat32Buf((n * factor).ceil() + 64);
    final stMove = _ProUint8Buf((n * factor).ceil() + 64);
    final stColor = _ProUint8Buf((n * factor).ceil() + 64);

    if (factor > 1.0) {
      // تكثيف نظيف: إدراج صف زكزاك وسطي بين كل زوجين متتاليين من نفس العمود
      double acc = 0.0;
      final double extraProb = (factor - 1.0).clamp(0.0, 1.0);
      for (int i = 0; i < n; i++) {
        stX.add(src.stX[i]);
        stY.add(src.stY[i]);
        stMove.add(src.stMove[i]);
        stColor.add(src.stColor[i]);

        if (i >= 2 &&
            i + 1 < n &&
            src.stMove[i] == 0 &&
            src.stMove[i + 1] == 0 &&
            src.stMove[i - 1] == 0 &&
            src.stColor[i] == src.stColor[i + 1]) {
          // نتحقق أنها حركة فستون (متجه i-1->i عكس متجه i->i+1)
          final double v1x = src.stX[i] - src.stX[i - 1];
          final double v1y = src.stY[i] - src.stY[i - 1];
          final double v2x = src.stX[i + 1] - src.stX[i];
          final double v2y = src.stY[i + 1] - src.stY[i];
          final double l1 = math.sqrt(v1x * v1x + v1y * v1y);
          final double l2 = math.sqrt(v2x * v2x + v2y * v2y);
          if (l1 > 6.0 && l2 > 6.0 && (v1x * v2x + v1y * v2y) / (l1 * l2) < -0.4) {
            acc += extraProb;
            if (acc >= 1.0) {
              acc -= 1.0;
              // نقطة متوسطة على الضلع الأول ثم على الضلع المقابل
              final double m1x = (src.stX[i - 1] + src.stX[i + 1]) * 0.5;
              final double m1y = (src.stY[i - 1] + src.stY[i + 1]) * 0.5;
              final double m2x = (src.stX[i] + (i + 2 < n && src.stMove[i + 2] == 0 ? src.stX[i + 2] : src.stX[i])) * 0.5;
              final double m2y = (src.stY[i] + (i + 2 < n && src.stMove[i + 2] == 0 ? src.stY[i + 2] : src.stY[i])) * 0.5;
              stX.add(m1x);
              stY.add(m1y);
              stMove.add(0);
              stColor.add(src.stColor[i]);
              stX.add(m2x);
              stY.add(m2y);
              stMove.add(0);
              stColor.add(src.stColor[i]);
            }
          }
        }
      }
    } else {
      // تخفيف نظيف: حذف أزواج كاملة فقط من قلب الفستون للحفاظ على التماسك
      double keepAcc = 0.0;
      int i = 0;
      while (i < n) {
        final bool isBoundary = i == 0 ||
            i >= n - 2 ||
            src.stMove[i] != 0 ||
            src.stMove[i + 1] != 0 ||
            src.stMove[i + 2] != 0 ||
            src.stColor[i] != src.stColor[i + 1];
        if (isBoundary) {
          stX.add(src.stX[i]);
          stY.add(src.stY[i]);
          stMove.add(src.stMove[i]);
          stColor.add(src.stColor[i]);
          i++;
          continue;
        }
        keepAcc += factor;
        if (keepAcc >= 1.0) {
          keepAcc -= 1.0;
          stX.add(src.stX[i]);
          stY.add(src.stY[i]);
          stMove.add(src.stMove[i]);
          stColor.add(src.stColor[i]);
          stX.add(src.stX[i + 1]);
          stY.add(src.stY[i + 1]);
          stMove.add(src.stMove[i + 1]);
          stColor.add(src.stColor[i + 1]);
        }
        i += 2;
      }
    }

    return VectorDesignData(
      stX: stX.finish(),
      stY: stY.finish(),
      stMove: stMove.finish(),
      stColor: stColor.finish(),
      stDev: src.stDev,
      seqX: src.seqX,
      seqY: src.seqY,
      seqCode: src.seqCode,
      beadX: src.beadX,
      beadY: src.beadY,
      beadCode: src.beadCode,
      paletteArgb: src.paletteArgb,
      stitches: stX.length,
      colorCount: src.colorCount,
      stopsCount: src.stopsCount,
      jumpsCount: src.jumpsCount,
      sequinsCount: src.sequinsCount,
      beadsCount: src.beadsCount,
      trimsCount: src.trimsCount,
      minX: src.minX,
      maxX: src.maxX,
      minY: src.minY,
      maxY: src.maxY,
      hasBounds: src.hasBounds,
      machineType: src.machineType,
    );
  }

  static VectorDesignData? _generateSync({
    required String rawJson,
    required String text,
    required double letterHeightCm,
    required double densityMm,
    required double extraSpacingMm,
    required double satinWidthOffsetMm,
    required bool autoSplit8Mm,
    required String pathMode,
    required double pathParam,
    required int underlayMode,
    required int colorArgb,
  }) {
    final Map<String, dynamic> font = jsonDecode(rawJson);
    final Map<String, dynamic> glyphs =
        (font['glyphs'] as Map<String, dynamic>?) ?? const {};
    if (glyphs.isEmpty) return null;

    final bool fontRtl = font['rtl'] == true;
    final bool textHasAr = ProArabicShaper.containsArabic(text);
    final bool isRtl = fontRtl && (textHasAr || RegExp(r'[0-9\u0660-\u0669]').hasMatch(text));

    final double capH = ((font['capH'] as num?)?.toDouble() ?? 150.0).clamp(20.0, 2000.0);
    final double targetCapUnits = (letterHeightCm * 100.0).clamp(40.0, 2200.0);
    final double scale = targetCapUnits / capH;

    final double spaceW = ((font['spaceW'] as num?)?.toDouble() ?? (capH * 0.60)) * scale;
    final double baseLetterSp = ((font['letterSp'] as num?)?.toDouble() ?? (capH * 0.09)) * scale;
    final double extraSpUnits = extraSpacingMm * 10.0;
    final double lineH = ((font['lineH'] as num?)?.toDouble() ?? (capH * 1.45)) * scale;
    final double densityUnits = (densityMm * 10.0).clamp(2.5, 10.0);
    final double rawJoinOv = (font['joinOverlap'] as num?)?.toDouble() ?? (capH * 0.03);
    final double arabicJoinOverlap = (rawJoinOv * scale).clamp(0.0, 32.0);
    final double satinOffsetUnits = satinWidthOffsetMm.clamp(-0.6, 1.5) * 5.0; // لكل طرف

    Map<String, dynamic>? lookupGlyph(_ProShapedToken tok) {
      if (tok.dotForm.isNotEmpty && glyphs.containsKey(tok.dotForm)) {
        return glyphs[tok.dotForm] as Map<String, dynamic>;
      }
      if (glyphs.containsKey(tok.shaped)) return glyphs[tok.shaped] as Map<String, dynamic>;
      if (glyphs.containsKey('${tok.base}.isol')) return glyphs['${tok.base}.isol'] as Map<String, dynamic>;
      if (glyphs.containsKey(tok.base)) return glyphs[tok.base] as Map<String, dynamic>;
      final up = tok.base.toUpperCase();
      if (glyphs.containsKey(up)) return glyphs[up] as Map<String, dynamic>;
      final lo = tok.base.toLowerCase();
      if (glyphs.containsKey(lo)) return glyphs[lo] as Map<String, dynamic>;
      return null;
    }

    final stX = _ProFloat32Buf(8192);
    final stY = _ProFloat32Buf(8192);
    final stMove = _ProUint8Buf(8192);
    final stColor = _ProUint8Buf(8192);

    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int jumpCount = 0;
    double curNeedleX = 0.0, curNeedleY = 0.0;
    bool hasNeedle = false;

    double activeLineWidth = math.max(300.0, targetCapUnits * 2.5);

    (double, double) warpPath(double ux, double uy) {
      if (pathMode == 'arc' && pathParam.abs() > 0.015) {
        final double halfSpan = math.max(180.0, activeLineWidth * 0.5);
        final double halfSweep = pathParam.clamp(-1.0, 1.0) * (math.pi * 0.62);
        final double radius = math.max(targetCapUnits * 0.9, halfSpan / halfSweep.abs());
        final double theta = ux / radius;
        if (halfSweep > 0) {
          final double r = math.max(20.0, radius - uy);
          return (r * math.sin(theta), radius - r * math.cos(theta));
        } else {
          final double r = math.max(20.0, radius + uy);
          return (r * math.sin(theta), -radius + r * math.cos(theta));
        }
      } else if (pathMode == 'circle') {
        final double minR = math.max(targetCapUnits * 1.15, activeLineWidth / (2.0 * math.pi * 0.88));
        final double radius = (minR * (1.35 - pathParam.clamp(-0.6, 0.85) * 0.55)).clamp(180.0, 2600.0);
        final double theta = ux / radius;
        final double r = math.max(20.0, radius - uy);
        return (r * math.sin(theta), radius - r * math.cos(theta));
      } else if (pathMode == 'wave' && pathParam.abs() > 0.01) {
        final double amp = pathParam.clamp(-1.0, 1.0) * targetCapUnits * 0.52;
        final double freq = (2.0 * math.pi) / math.max(350.0, activeLineWidth * 0.95);
        final double wy = amp * math.sin(ux * freq);
        final double slope = amp * freq * math.cos(ux * freq);
        final double invLen = 1.0 / math.sqrt(1.0 + slope * slope);
        final double nx = -slope * invLen;
        final double ny = invLen;
        return (ux + nx * uy, wy + ny * uy);
      }
      return (ux, uy);
    }

    void addPt(double rawUx, double rawUy, bool isMove) {
      final pt = warpPath(rawUx, rawUy);
      final double ux = pt.$1;
      final double uy = pt.$2;
      bool actualMove = isMove;
      if (isMove && hasNeedle) {
        final double d = math.sqrt(
          (ux - curNeedleX) * (ux - curNeedleX) + (uy - curNeedleY) * (uy - curNeedleY),
        );
        if (d < 26.0) {
          actualMove = false;
        }
      }
      stX.add(ux);
      stY.add(uy);
      stMove.add(actualMove ? 1 : 0);
      stColor.add(0);
      if (actualMove) jumpCount++;
      curNeedleX = ux;
      curNeedleY = uy;
      hasNeedle = true;
      if (!hasBounds) {
        minX = maxX = ux;
        minY = maxY = uy;
        hasBounds = true;
      } else {
        if (ux < minX) minX = ux;
        if (ux > maxX) maxX = ux;
        if (uy < minY) minY = uy;
        if (uy > maxY) maxY = uy;
      }
    }

    final List<String> lines = text.split('\n');
    for (int lineIdx = 0; lineIdx < lines.length; lineIdx++) {
      final lineStr = lines[lineIdx].trim();
      if (lineStr.isEmpty) continue;

      final tokens = ProArabicShaper.shapeLine(lineStr, isRtl: isRtl);
      final List<(Map<String, dynamic>?, _ProShapedToken, double)> placed = [];

      double totalW = 0.0;
      for (int tIdx = 0; tIdx < tokens.length; tIdx++) {
        final tok = tokens[tIdx];
        if (tok.isSpace) {
          placed.add((null, tok, spaceW));
          totalW += spaceW;
          continue;
        }
        final g = lookupGlyph(tok);
        if (g == null) continue;
        final double gw = ((g['w'] as num?)?.toDouble() ?? 50.0) * scale;
        final double? metaAdv = g['a'] is num ? (g['a'] as num).toDouble() * scale : null;
        double adv = metaAdv ?? gw;
        if (tIdx + 1 < tokens.length && !tokens[tIdx + 1].isSpace) {
          final nextTok = tokens[tIdx + 1];
          if (isRtl && tok.connectsLeft && nextTok.connectsRight) {
            adv = math.max(gw * 0.35, (metaAdv ?? gw) - arabicJoinOverlap + (extraSpUnits * 0.35));
          } else {
            adv = math.max(gw * 0.35, (metaAdv ?? (gw + baseLetterSp)) + extraSpUnits);
          }
        }
        placed.add((g, tok, adv));
        totalW += adv;
      }

      if (placed.isEmpty) continue;
      activeLineWidth = math.max(250.0, totalW);

      final double baselineY = lineIdx * lineH;
      double cursorX = isRtl ? (totalW * 0.5) : (-totalW * 0.5);

      for (int pIdx = 0; pIdx < placed.length; pIdx++) {
        final item = placed[pIdx];
        final g = item.$1;
        final adv = item.$3;
        if (g == null) {
          cursorX += isRtl ? -adv : adv;
          continue;
        }
        final double gw = ((g['w'] as num?)?.toDouble() ?? 50.0) * scale;
        final double ox = isRtl ? (cursorX - gw) : cursorX;
        final double oy = baselineY;

        final List<dynamic> elements = (g['e'] as List<dynamic>?) ?? const [];
        for (int eIdx = 0; eIdx < elements.length; eIdx++) {
          final el = elements[eIdx] as Map<String, dynamic>;
          final String type = (el['t'] ?? '').toString();

          (double, double)? nextAnchor;
          if (eIdx + 1 < elements.length) {
            final nel = elements[eIdx + 1] as Map<String, dynamic>;
            nextAnchor = _elementFirstPt(nel, ox, oy, scale);
          }

          if (type == 's') {
            _emitSatinColumn(
              el: el,
              ox: ox,
              oy: oy,
              scale: scale,
              densityUnits: densityUnits,
              satinOffsetUnits: satinOffsetUnits,
              autoSplit8Mm: autoSplit8Mm,
              underlayMode: underlayMode,
              curNeedleX: curNeedleX,
              curNeedleY: curNeedleY,
              hasNeedle: hasNeedle,
              nextAnchor: nextAnchor,
              addPt: addPt,
            );
          } else if (type == 'r') {
            _emitRunningPath(
              el: el,
              ox: ox,
              oy: oy,
              scale: scale,
              addPt: addPt,
            );
          } else if (type == 'f') {
            _emitFillPolygon(
              el: el,
              ox: ox,
              oy: oy,
              scale: scale,
              densityUnits: densityUnits,
              addPt: addPt,
            );
          } else if (type == 'd') {
            _emitDigitizedRun(
              el: el,
              ox: ox,
              oy: oy,
              scale: scale,
              satinOffsetUnits: satinOffsetUnits,
              autoSplit8Mm: autoSplit8Mm,
              addPt: addPt,
            );
          }
        }

        cursorX += isRtl ? -adv : adv;
      }
    }

    if (stX.length < 2) return null;

    final bool isWilcomNative = font['nativeStitch'] == true;
    final String fontName = (font['nameEn'] ?? 'Wilcom Satin').toString();
    return VectorDesignData(
      stX: stX.finish(),
      stY: stY.finish(),
      stMove: stMove.finish(),
      stColor: stColor.finish(),
      seqX: Float32List(0),
      seqY: Float32List(0),
      seqCode: Uint8List(0),
      beadX: Float32List(0),
      beadY: Float32List(0),
      beadCode: Uint8List(0),
      paletteArgb: Int32List.fromList([colorArgb]),
      stitches: stX.length,
      colorCount: 1,
      stopsCount: 0,
      jumpsCount: jumpCount,
      sequinsCount: 0,
      beadsCount: 0,
      trimsCount: 0,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      hasBounds: hasBounds,
      machineType: isWilcomNative ? '$fontName (Wilcom)' : '$fontName (Satin)',
    );
  }

  static (double, double)? _elementFirstPt(
    Map<String, dynamic> el,
    double ox,
    double oy,
    double scale,
  ) {
    final List<dynamic>? arr = (el['r1'] ?? el['p']) as List<dynamic>?;
    if (arr == null || arr.length < 2) return null;
    return (
      ox + (arr[0] as num).toDouble() * scale,
      oy + (arr[1] as num).toDouble() * scale,
    );
  }

  static (List<double>, List<double>, double) _buildScaledPoly(
    List<dynamic> flat,
    double ox,
    double oy,
    double scale,
  ) {
    final int n = flat.length ~/ 2;
    final pts = List<double>.filled(n * 2, 0.0);
    final cum = List<double>.filled(n, 0.0);
    double acc = 0.0;
    for (int i = 0; i < n; i++) {
      final double x = ox + (flat[i * 2] as num).toDouble() * scale;
      final double y = oy + (flat[i * 2 + 1] as num).toDouble() * scale;
      pts[i * 2] = x;
      pts[i * 2 + 1] = y;
      if (i > 0) {
        final dx = x - pts[(i - 1) * 2];
        final dy = y - pts[(i - 1) * 2 + 1];
        acc += math.sqrt(dx * dx + dy * dy);
      }
      cum[i] = acc;
    }
    return (pts, cum, acc);
  }

  static (double, double) _samplePoly(
    List<double> pts,
    List<double> cum,
    double total,
    double u,
  ) {
    final int n = cum.length;
    if (n == 0) return (0.0, 0.0);
    if (n == 1 || total <= 1e-6 || u <= 0.0) return (pts[0], pts[1]);
    if (u >= 1.0) return (pts[(n - 1) * 2], pts[(n - 1) * 2 + 1]);
    final double target = u * total;
    int lo = 0, hi = n - 1;
    while (lo + 1 < hi) {
      final int mid = (lo + hi) >> 1;
      if (cum[mid] <= target) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final double segLen = cum[hi] - cum[lo];
    final double t = segLen > 1e-6 ? ((target - cum[lo]) / segLen) : 0.0;
    return (
      pts[lo * 2] + (pts[hi * 2] - pts[lo * 2]) * t,
      pts[lo * 2 + 1] + (pts[hi * 2 + 1] - pts[lo * 2 + 1]) * t,
    );
  }

  static void _emitSatinColumn({
    required Map<String, dynamic> el,
    required double ox,
    required double oy,
    required double scale,
    required double densityUnits,
    required double satinOffsetUnits,
    required bool autoSplit8Mm,
    required int underlayMode,
    required double curNeedleX,
    required double curNeedleY,
    required bool hasNeedle,
    required (double, double)? nextAnchor,
    required void Function(double, double, bool) addPt,
  }) {
    final List<dynamic>? rawR1 = el['r1'] as List<dynamic>?;
    final List<dynamic>? rawR2 = el['r2'] as List<dynamic>?;
    if (rawR1 == null || rawR2 == null || rawR1.length < 4 || rawR2.length < 4) return;

    final b1 = _buildScaledPoly(rawR1, ox, oy, scale);
    final b2 = _buildScaledPoly(rawR2, ox, oy, scale);
    final p1 = b1.$1, c1 = b1.$2, len1 = b1.$3;
    final p2 = b2.$1, c2 = b2.$2, len2 = b2.$3;
    final double maxLen = math.max(len1, len2);
    if (maxLen < 1.0) return;

    final List<(double, double)> anchors = [(0.0, 0.0)];
    final List<dynamic>? rawRungs = el['g'] as List<dynamic>?;
    if (rawRungs != null) {
      for (final rg in rawRungs) {
        if (rg is List && rg.length >= 2) {
          final double u1 = (rg[0] as num).toDouble().clamp(0.01, 0.99);
          final double u2 = (rg[1] as num).toDouble().clamp(0.01, 0.99);
          if (u1 > anchors.last.$1 + 0.005 && u2 > anchors.last.$2 + 0.005) {
            anchors.add((u1, u2));
          }
        }
      }
    }
    anchors.add((1.0, 1.0));

    final s0a = _samplePoly(p1, c1, len1, 0.0);
    final s0b = _samplePoly(p2, c2, len2, 0.0);
    final s1a = _samplePoly(p1, c1, len1, 1.0);
    final s1b = _samplePoly(p2, c2, len2, 1.0);
    final double mid0x = (s0a.$1 + s0b.$1) * 0.5, mid0y = (s0a.$2 + s0b.$2) * 0.5;
    final double mid1x = (s1a.$1 + s1b.$1) * 0.5, mid1y = (s1a.$2 + s1b.$2) * 0.5;

    bool satinForward = true;
    if (nextAnchor != null) {
      final d0 = (mid0x - nextAnchor.$1) * (mid0x - nextAnchor.$1) +
          (mid0y - nextAnchor.$2) * (mid0y - nextAnchor.$2);
      final d1 = (mid1x - nextAnchor.$1) * (mid1x - nextAnchor.$1) +
          (mid1y - nextAnchor.$2) * (mid1y - nextAnchor.$2);
      satinForward = d1 <= d0;
    } else if (hasNeedle && underlayMode == 0) {
      final d0 = (mid0x - curNeedleX) * (mid0x - curNeedleX) +
          (mid0y - curNeedleY) * (mid0y - curNeedleY);
      final d1 = (mid1x - curNeedleX) * (mid1x - curNeedleX) +
          (mid1y - curNeedleY) * (mid1y - curNeedleY);
      satinForward = d0 <= d1;
    }

    ((double, double), (double, double)) pairAt(double tGlobal) {
      final int segCount = anchors.length - 1;
      final double scaledT = tGlobal.clamp(0.0, 1.0) * segCount;
      final int idx = scaledT.floor().clamp(0, segCount - 1);
      final double localT = scaledT - idx;
      final a = anchors[idx];
      final b = anchors[idx + 1];
      final u1 = a.$1 + (b.$1 - a.$1) * localT;
      final u2 = a.$2 + (b.$2 - a.$2) * localT;
      return (_samplePoly(p1, c1, len1, u1), _samplePoly(p2, c2, len2, u2));
    }

    bool firstStitchOfCol = true;
    final int fontUnderlay = (el['u'] as num?)?.toInt() ?? 1;
    final bool doCenterWalk = underlayMode >= 1 && fontUnderlay != 0 && maxLen >= 18.0;

    if (doCenterWalk) {
      final int uSteps = math.max(2, (maxLen / 22.0).ceil());
      final double tStart = satinForward ? 0.94 : 0.06;
      final double tEnd = satinForward ? 0.04 : 0.96;
      for (int k = 0; k <= uSteps; k++) {
        final double t = tStart + (tEnd - tStart) * (k / uSteps);
        final pr = pairAt(t);
        addPt((pr.$1.$1 + pr.$2.$1) * 0.5, (pr.$1.$2 + pr.$2.$2) * 0.5, firstStitchOfCol);
        firstStitchOfCol = false;
      }
    }

    final List<(double, double)> orderedAnchors =
        satinForward ? anchors : anchors.reversed.toList();
    double? prevAx, prevAy, prevBx, prevBy;
    int stitchRow = 0;
    final double splitThreshold = autoSplit8Mm ? 80.0 : 120.0;

    for (int sIdx = 0; sIdx < orderedAnchors.length - 1; sIdx++) {
      final double u1a = orderedAnchors[sIdx].$1;
      final double u2a = orderedAnchors[sIdx].$2;
      final double u1b = orderedAnchors[sIdx + 1].$1;
      final double u2b = orderedAnchors[sIdx + 1].$2;

      final double segMax = math.max((u1b - u1a).abs() * len1, (u2b - u2a).abs() * len2);
      if (segMax < 0.3) continue;

      final int steps = math.max(2, (segMax / densityUnits).ceil());
      final int startK = sIdx == 0 ? 0 : 1;

      for (int k = startK; k <= steps; k++) {
        final double frac = k / steps;
        final aRaw = _samplePoly(p1, c1, len1, u1a + (u1b - u1a) * frac);
        final bRaw = _samplePoly(p2, c2, len2, u2a + (u2b - u2a) * frac);

        double ax = aRaw.$1, ay = aRaw.$2;
        double bx = bRaw.$1, by = bRaw.$2;

        final double dx = bx - ax;
        final double dy = by - ay;
        final double width = math.sqrt(dx * dx + dy * dy);
        if (width > 3.0) {
          final double basePc = width > 14.0 ? 1.2 : 0.7;
          final double minAllowedOffset = -(width * 0.38);
          final double pc = (basePc + satinOffsetUnits).clamp(minAllowedOffset, 15.0);
          final double ux = dx / width;
          final double uy = dy / width;
          ax -= ux * pc;
          ay -= uy * pc;
          bx += ux * pc;
          by += uy * pc;
        }

        final double newWidth = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
        double emitAx = ax, emitAy = ay, emitBx = bx, emitBy = by;

        if (prevAx != null && prevAy != null && prevBx != null && prevBy != null && (stitchRow & 1) == 1) {
          final double dA = math.sqrt((ax - prevAx) * (ax - prevAx) + (ay - prevAy) * (ay - prevAy));
          final double dB = math.sqrt((bx - prevBx) * (bx - prevBx) + (by - prevBy) * (by - prevBy));
          if (dA < 3.4 && dB > 4.2 && newWidth > 10.0) {
            emitAx = ax + (bx - ax) * 0.28;
            emitAy = ay + (by - ay) * 0.28;
          } else if (dB < 3.4 && dA > 4.2 && newWidth > 10.0) {
            emitBx = bx + (ax - bx) * 0.28;
            emitBy = by + (ay - by) * 0.28;
          }
        }

        if (autoSplit8Mm && newWidth > splitThreshold) {
          final int parts = (newWidth / 45.0).ceil().clamp(2, 6);
          final double phase = (stitchRow % 3 == 0) ? 0.0 : ((stitchRow % 3 == 1) ? 0.14 : -0.14);
          addPt(emitAx, emitAy, firstStitchOfCol);
          firstStitchOfCol = false;
          for (int p = 1; p < parts; p++) {
            final double t = ((p / parts) + phase).clamp(0.15, 0.85);
            addPt(emitAx + (emitBx - emitAx) * t, emitAy + (emitBy - emitAy) * t, false);
          }
          addPt(emitBx, emitBy, false);
        } else {
          addPt(emitAx, emitAy, firstStitchOfCol);
          firstStitchOfCol = false;
          addPt(emitBx, emitBy, false);
        }

        prevAx = ax;
        prevAy = ay;
        prevBx = bx;
        prevBy = by;
        stitchRow++;
      }
    }
  }

  /// توليد غرز الفونطات الأصلية من ويلكم (.DST) مع تعريض فستون حقيقي عبر منصف زاوية الزكزاك
  static void _emitDigitizedRun({
    required Map<String, dynamic> el,
    required double ox,
    required double oy,
    required double scale,
    required double satinOffsetUnits,
    required bool autoSplit8Mm,
    required void Function(double, double, bool) addPt,
  }) {
    final List<dynamic>? rawP = el['p'] as List<dynamic>?;
    if (rawP == null || rawP.length < 4) return;
    final int n = rawP.length ~/ 2;

    final xs = List<double>.filled(n, 0.0);
    final ys = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      xs[i] = ox + (rawP[i * 2] as num).toDouble() * scale;
      ys[i] = oy + (rawP[i * 2 + 1] as num).toDouble() * scale;
    }

    final outX = List<double>.from(xs);
    final outY = List<double>.from(ys);
    if (satinOffsetUnits.abs() > 0.08 && n >= 3) {
      for (int i = 1; i < n - 1; i++) {
        final double v1x = xs[i] - xs[i - 1];
        final double v1y = ys[i] - ys[i - 1];
        final double v2x = xs[i + 1] - xs[i];
        final double v2y = ys[i + 1] - ys[i];
        final double l1 = math.sqrt(v1x * v1x + v1y * v1y);
        final double l2 = math.sqrt(v2x * v2x + v2y * v2y);
        if (l1 < 6.0 || l2 < 6.0) continue;

        final double u1x = v1x / l1, u1y = v1y / l1;
        final double u2x = v2x / l2, u2y = v2y / l2;
        final double cosT = u1x * u2x + u1y * u2y;

        if (cosT < -0.35) {
          double bx = u1x - u2x;
          double by = u1y - u2y;
          final double bLen = math.sqrt(bx * bx + by * by);
          if (bLen > 1e-4) {
            bx /= bLen;
            by /= bLen;
            final double minW = math.min(l1, l2);
            final double safeShift = satinOffsetUnits.clamp(-(minW * 0.28), minW * 0.45);
            outX[i] = xs[i] + bx * safeShift;
            outY[i] = ys[i] + by * safeShift;
          }
        }
      }
    }

    double prevX = 0.0, prevY = 0.0;
    bool hasP = false;
    for (int i = 0; i < n; i++) {
      final double px = outX[i];
      final double py = outY[i];

      if (hasP && autoSplit8Mm) {
        final double dx = px - prevX;
        final double dy = py - prevY;
        final double segLen = math.sqrt(dx * dx + dy * dy);
        if (segLen > 80.0 && segLen < 600.0) {
          final int parts = (segLen / 45.0).ceil().clamp(2, 10);
          final double stagger = (i % 3 == 0) ? 0.0 : ((i % 3 == 1) ? 0.09 : -0.09);
          for (int k = 1; k < parts; k++) {
            final double t = ((k / parts) + stagger).clamp(0.12, 0.88);
            addPt(prevX + dx * t, prevY + dy * t, false);
          }
        }
      }

      addPt(px, py, i == 0);
      prevX = px;
      prevY = py;
      hasP = true;
    }
  }

  static void _emitRunningPath({
    required Map<String, dynamic> el,
    required double ox,
    required double oy,
    required double scale,
    required void Function(double, double, bool) addPt,
  }) {
    final List<dynamic>? rawP = el['p'] as List<dynamic>?;
    if (rawP == null || rawP.length < 4) return;
    final int n = rawP.length ~/ 2;
    const double stepUnits = 22.0;

    double px = ox + (rawP[0] as num).toDouble() * scale;
    double py = oy + (rawP[1] as num).toDouble() * scale;
    addPt(px, py, true);

    for (int i = 1; i < n; i++) {
      final double nx = ox + (rawP[i * 2] as num).toDouble() * scale;
      final double ny = oy + (rawP[i * 2 + 1] as num).toDouble() * scale;
      final double dx = nx - px;
      final double dy = ny - py;
      final double seg = math.sqrt(dx * dx + dy * dy);
      if (seg > stepUnits) {
        final int steps = (seg / stepUnits).ceil();
        for (int s = 1; s < steps; s++) {
          final double t = s / steps;
          addPt(px + dx * t, py + dy * t, false);
        }
      }
      if (seg > 1.0 || i == n - 1) {
        addPt(nx, ny, false);
      }
      px = nx;
      py = ny;
    }
  }

  static void _emitFillPolygon({
    required Map<String, dynamic> el,
    required double ox,
    required double oy,
    required double scale,
    required double densityUnits,
    required void Function(double, double, bool) addPt,
  }) {
    final List<dynamic>? rawP = el['p'] as List<dynamic>?;
    if (rawP == null || rawP.length < 6) return;
    final int n = rawP.length ~/ 2;
    final xs = List<double>.filled(n, 0.0);
    final ys = List<double>.filled(n, 0.0);
    double minY = double.infinity, maxY = -double.infinity;
    for (int i = 0; i < n; i++) {
      xs[i] = ox + (rawP[i * 2] as num).toDouble() * scale;
      ys[i] = oy + (rawP[i * 2 + 1] as num).toDouble() * scale;
      if (ys[i] < minY) minY = ys[i];
      if (ys[i] > maxY) maxY = ys[i];
    }
    if (maxY - minY < 2.0) return;

    bool forward = true;
    bool first = true;
    const double stitchStep = 32.0;

    for (double y = minY + densityUnits * 0.5; y <= maxY; y += densityUnits) {
      final List<double> hits = [];
      for (int i = 0; i < n; i++) {
        final int j = (i + 1) % n;
        final double y0 = ys[i], y1 = ys[j];
        if ((y0 <= y && y1 > y) || (y1 <= y && y0 > y)) {
          hits.add(xs[i] + (y - y0) * (xs[j] - xs[i]) / (y1 - y0));
        }
      }
      if (hits.length < 2) continue;
      hits.sort();
      for (int h = 0; h + 1 < hits.length; h += 2) {
        final double xA = forward ? hits[h] : hits[h + 1];
        final double xB = forward ? hits[h + 1] : hits[h];
        addPt(xA, y, first);
        first = false;
        final double span = (xB - xA).abs();
        if (span > stitchStep) {
          final int steps = (span / stitchStep).floor();
          for (int s = 1; s < steps; s++) {
            addPt(xA + (xB - xA) * (s / steps), y, false);
          }
        }
        addPt(xB, y, false);
      }
      forward = !forward;
    }
  }
}

/// محرك العرض ثلاثي الأبعاد الحقيقي (Wilcom TrueView 3D Pro):
/// - يُلغي القفزات والخيوط الطويلة (> 12 مم) نهائياً في وضع 3D حتى لا تظهر أي خيوط عابرة مشوِّهة
/// - يحسب سمك الخيط بالقياس الفيزيائي الحقيقي (~0.38 مم متناسباً مع مقاس التصميم) بدلاً من السمك الضخم الثابت
/// - يرسم الخيط بطبقات حريرية دقيقة + ترتر وخرز حقيقيين
class TarikPro3DRenderer {
  static Future<Uint8List?> renderHighResPreview(
    String filePath, {
    double maxCanvas = 2200.0,
    bool is3D = false,
    bool transparentBg = true,
  }) async {
    try {
      final VectorDesignData? vec = filePath.toLowerCase().endsWith('.tbf')
          ? await TarikProTbfParser.loadVector(filePath)
          : await VectorDesignLoader.load(filePath);
      if (vec == null || vec.stX.length < 2) return null;
      return await renderVectorToPng(
        vec,
        maxCanvas: maxCanvas,
        is3D: is3D,
        transparentBg: transparentBg,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> renderVectorToPng(
    VectorDesignData data, {
    double maxCanvas = 2200.0,
    bool is3D = false,
    bool transparentBg = true,
  }) async {
    if (!data.hasBounds || data.stX.length < 2) return null;
    final double rawW = data.maxX - data.minX;
    final double rawH = data.maxY - data.minY;
    if (!rawW.isFinite || !rawH.isFinite || rawW <= 0 || rawH <= 0) return null;

    final double pad = maxCanvas >= 1800.0 ? 36.0 : 24.0;
    final double scale = (maxCanvas - pad * 2) / math.max(rawW, rawH);
    final int imgW = math.max(64, (rawW * scale + pad * 2).ceil());
    final int imgH = math.max(64, (rawH * scale + pad * 2).ceil());

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()));
    if (!transparentBg) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()),
        Paint()..color = Colors.white,
      );
    }

    final int palLen = math.max(1, data.paletteArgb.length);
    final double minX = data.minX;
    final double minY = data.minY;

    // السمك الفيزيائي الحقيقي للخيط (~0.38 مم = 3.8 وحدة من 0.1 مم) متناسب مع مقياس التصميم الفعلي!
    final double physThreadW = (scale * 3.8).clamp(0.95, 4.2);
    final double flatStrokeW = (scale * 1.4).clamp(0.45, 0.85);

    // الحد الأقصى لطول الغرزة الحقيقية قبل اعتبارها قفزة وإلغائها في العرض ثلاثي الأبعاد (12.0 مم = 120 وحدة)
    const double maxRealStitchUnits3D = 120.0;
    const double maxRealStitchUnits2D = 145.0;
    final double maxSegSq = is3D
        ? (maxRealStitchUnits3D * maxRealStitchUnits3D)
        : (maxRealStitchUnits2D * maxRealStitchUnits2D);

    final Float32List stX = data.stX;
    final Float32List stY = data.stY;
    final Uint8List stMove = data.stMove;
    final Uint8List stColor = data.stColor;
    final int nSt = stX.length;

    Path currentPath = Path();
    int activeColorIdx = -1;
    bool hasMove = false;
    double prevRawX = 0.0, prevRawY = 0.0;

    void flushPath() {
      if (!hasMove || activeColorIdx < 0) return;
      final Color baseColor = Color(data.paletteArgb[activeColorIdx % palLen]);
      if (is3D) {
        final double tw = physThreadW;
        final double shOff = (tw * 0.32).clamp(0.28, 1.3);
        final double hiOff = (tw * 0.18).clamp(0.18, 0.75);

        // 1) ظل ناعم محكم تحت الخيط بدون تضخيم مشوّه
        canvas.save();
        canvas.translate(shOff, shOff);
        canvas.drawPath(
          currentPath,
          Paint()
            ..color = Colors.black.withOpacity(0.26)
            ..style = PaintingStyle.stroke
            ..strokeWidth = tw * 1.08
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true,
        );
        canvas.restore();

        // 2) حافة داكنة دقيقة للعمق (Wilcom TrueView Edge)
        canvas.drawPath(
          currentPath,
          Paint()
            ..color = Color.lerp(baseColor, Colors.black, 0.28) ?? baseColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = tw
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true,
        );

        // 3) جسم الخيط اللوني
        canvas.drawPath(
          currentPath,
          Paint()
            ..color = baseColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = tw * 0.76
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true,
        );

        // 4) لمعة الحرير العلوية الدقيقة
        canvas.save();
        canvas.translate(-hiOff, -hiOff);
        canvas.drawPath(
          currentPath,
          Paint()
            ..color = (Color.lerp(baseColor, Colors.white, 0.58) ?? Colors.white).withOpacity(0.75)
            ..style = PaintingStyle.stroke
            ..strokeWidth = (tw * 0.24).clamp(0.25, 1.1)
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true,
        );
        canvas.restore();
      } else {
        canvas.drawPath(
          currentPath,
          Paint()
            ..color = baseColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = flatStrokeW
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true,
        );
      }
      currentPath = Path();
      hasMove = false;
    }

    for (int i = 0; i < nSt; i++) {
      final int cIdx = stColor[i];
      if (cIdx != activeColorIdx) {
        flushPath();
        activeColorIdx = cIdx;
      }
      final double rx = stX[i];
      final double ry = stY[i];
      final double sx = (rx - minX) * scale + pad;
      final double sy = (ry - minY) * scale + pad;

      bool treatAsJump = stMove[i] != 0 || !hasMove;
      if (!treatAsJump) {
        final double dx = rx - prevRawX;
        final double dy = ry - prevRawY;
        // إلغاء أي قفزة أو انتقال طويل (> 12 مم في 3D) حتى لا يُرسم كخيط عريض عابر للتصميم
        if (dx * dx + dy * dy > maxSegSq) {
          treatAsJump = true;
        }
      }

      if (treatAsJump) {
        currentPath.moveTo(sx, sy);
        hasMove = true;
      } else {
        currentPath.lineTo(sx, sy);
      }
      prevRawX = rx;
      prevRawY = ry;
    }
    flushPath();

    // رسم الترتر (Sequins)
    if (data.seqX.isNotEmpty) {
      final List<Path> seqPaths = List.generate(4, (_) => Path());
      final List<bool> hasSeq = [false, false, false, false];
      const seqRadiiUnits = [15.0, 22.0, 28.0, 35.0];
      const seqColors = [
        Color(0xFFE53935),
        Color(0xFFFB8C00),
        Color(0xFF1E88E5),
        Color(0xFF8E24AA),
      ];
      final List<double> seqRadiiPx = [
        (seqRadiiUnits[0] * scale).clamp(2.0, 18.0),
        (seqRadiiUnits[1] * scale).clamp(2.0, 18.0),
        (seqRadiiUnits[2] * scale).clamp(2.0, 18.0),
        (seqRadiiUnits[3] * scale).clamp(2.0, 18.0),
      ];
      for (int i = 0; i < data.seqX.length; i++) {
        final int code = data.seqCode[i];
        int b = 0;
        if (code == 2 || code == 6) {
          b = 1;
        } else if (code == 3 || code == 16) {
          b = 2;
        } else if (code == 4 || code == 8 || code == 32) {
          b = 3;
        }
        final double sx = (data.seqX[i] - minX) * scale + pad;
        final double sy = (data.seqY[i] - minY) * scale + pad;
        seqPaths[b].addOval(Rect.fromCircle(center: Offset(sx, sy), radius: seqRadiiPx[b]));
        hasSeq[b] = true;
      }
      for (int b = 0; b < 4; b++) {
        if (!hasSeq[b]) continue;
        canvas.drawPath(
          seqPaths[b],
          Paint()
            ..color = seqColors[b]
            ..style = PaintingStyle.stroke
            ..strokeWidth = (seqRadiiPx[b] * 0.25).clamp(0.65, 2.2)
            ..isAntiAlias = true,
        );
      }
    }

    // رسم الخرز (Beads)
    if (data.beadX.isNotEmpty) {
      final List<_ProFloat32Buf> beadPts = [
        _ProFloat32Buf(1024),
        _ProFloat32Buf(512),
        _ProFloat32Buf(512),
      ];
      final _ProFloat32Buf hiPts = _ProFloat32Buf(math.min(data.beadX.length * 2, 65536));
      final double r = (12.0 * scale).clamp(1.5, 8.0);
      final double hiOff = r * 0.25;
      for (int i = 0; i < data.beadX.length; i++) {
        final int c = data.beadCode[i];
        final int b = (c == 2) ? 1 : (c == 3 ? 2 : 0);
        final double sx = (data.beadX[i] - minX) * scale + pad;
        final double sy = (data.beadY[i] - minY) * scale + pad;
        beadPts[b].add(sx);
        beadPts[b].add(sy);
        hiPts.add(sx - hiOff);
        hiPts.add(sy - hiOff);
      }
      const beadColors = [
        Color(0xFFD4A017),
        Color(0xFF00ACC1),
        Color(0xFF8E24AA),
      ];
      for (int b = 0; b < 3; b++) {
        if (beadPts[b].length == 0) continue;
        canvas.drawRawPoints(
          ui.PointMode.points,
          beadPts[b].finish(),
          Paint()
            ..color = beadColors[b]
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = r * 2.0
            ..isAntiAlias = true,
        );
      }
      if (hiPts.length > 0 && r >= 2.0) {
        canvas.drawRawPoints(
          ui.PointMode.points,
          hiPts.finish(),
          Paint()
            ..color = const Color(0xBFFFFFFF)
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = r * 0.64
            ..isAntiAlias = true,
        );
      }
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(imgW, imgH);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    picture.dispose();
    return byteData?.buffer.asUint8List();
  }
}

/// عنصر تصميم متكامل (يحمل الغرز + إحصاء الخرز والترتر بداخله)
class ProDesignObject {
  final int id;
  final int colorIndex;
  final List<(int, int)> ranges;
  final double minX, maxX, minY, maxY;
  final int stitchCount;
  final int sequinsCount;
  final int beadsCount;

  const ProDesignObject({
    required this.id,
    required this.colorIndex,
    required this.ranges,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.stitchCount,
    this.sequinsCount = 0,
    this.beadsCount = 0,
  });

  double get centerX => (minX + maxX) * 0.5;
  double get centerY => (minY + maxY) * 0.5;
  double get widthMm => (maxX - minX) / 10.0;
  double get heightMm => (maxY - minY) / 10.0;
}

/// تحويلات العنصر الفردي (تحريك + تكبير + تدوير + قلب + تغيير اللون + إدراج مقص Trim)
class ProObjectTransform {
  final int sourceObjectId;
  double dx;
  double dy;
  double scaleX;
  double scaleY;
  double rotationDeg;
  bool flipH;
  bool flipV;
  bool deleted;
  int? colorIndexOverride;
  bool insertTrimAfter;

  ProObjectTransform({
    required this.sourceObjectId,
    this.dx = 0.0,
    this.dy = 0.0,
    this.scaleX = 1.0,
    this.scaleY = 1.0,
    this.rotationDeg = 0.0,
    this.flipH = false,
    this.flipV = false,
    this.deleted = false,
    this.colorIndexOverride,
    this.insertTrimAfter = false,
  });

  ProObjectTransform copyWith({
    double? dx,
    double? dy,
    double? scaleX,
    double? scaleY,
    double? rotationDeg,
    bool? flipH,
    bool? flipV,
    bool? deleted,
    int? colorIndexOverride,
    bool clearColorOverride = false,
    bool? insertTrimAfter,
  }) {
    return ProObjectTransform(
      sourceObjectId: sourceObjectId,
      dx: dx ?? this.dx,
      dy: dy ?? this.dy,
      scaleX: scaleX ?? this.scaleX,
      scaleY: scaleY ?? this.scaleY,
      rotationDeg: rotationDeg ?? this.rotationDeg,
      flipH: flipH ?? this.flipH,
      flipV: flipV ?? this.flipV,
      deleted: deleted ?? this.deleted,
      colorIndexOverride: clearColorOverride ? null : (colorIndexOverride ?? this.colorIndexOverride),
      insertTrimAfter: insertTrimAfter ?? this.insertTrimAfter,
    );
  }

  (double, double, double, double) transformedBounds(ProDesignObject obj) {
    final double cx = obj.centerX;
    final double cy = obj.centerY;
    final double rad = rotationDeg * math.pi / 180.0;
    final double ca = math.cos(rad);
    final double sa = math.sin(rad);

    final corners = [
      (obj.minX, obj.minY),
      (obj.maxX, obj.minY),
      (obj.maxX, obj.maxY),
      (obj.minX, obj.maxY),
    ];

    double bMinX = double.infinity, bMaxX = -double.infinity;
    double bMinY = double.infinity, bMaxY = -double.infinity;
    for (final c in corners) {
      final double lx = (c.$1 - cx) * scaleX * (flipH ? -1.0 : 1.0);
      final double ly = (c.$2 - cy) * scaleY * (flipV ? -1.0 : 1.0);
      final double rx = lx * ca - ly * sa + cx + dx;
      final double ry = lx * sa + ly * ca + cy + dy;
      if (rx < bMinX) bMinX = rx;
      if (rx > bMaxX) bMaxX = rx;
      if (ry < bMinY) bMinY = ry;
      if (ry > bMaxY) bMaxY = ry;
    }
    return (bMinX, bMaxX, bMinY, bMaxY);
  }
}

/// محرر العناصر المطوّر (ويلكم Pro):
/// - لا يفتّت الحروف العريضة أو أعمدة الفستون عند التقسيم
/// - يحافظ على أوامر الخرز والترتر 100% (في stDev + seqX/Y + beadX/Y) مع التدوير والتكبير والتكرار والحذف
/// - يدعم تغيير اللون وإضافة لون جديد وتفعيل/إلغاء المقص (✂️ Trim) لكل عنصر
class TarikProObjectEditor {
  static List<ProDesignObject> segment(VectorDesignData data) {
    final int n = data.stX.length;
    if (n < 2) return const [];
    final Uint8List? devArr = data.stDev;

    final List<({int color, int start, int end, double minX, double maxX, double minY, double maxY, int seq, int bead})> runs = [];
    int rStart = 0;
    int rColor = data.stColor[0];
    double rMinX = data.stX[0], rMaxX = data.stX[0];
    double rMinY = data.stY[0], rMaxY = data.stY[0];
    int rSeq = 0, rBead = 0;

    void countDev(int idx) {
      if (devArr != null && idx < devArr.length) {
        final int dt = devArr[idx] & 0x0F;
        if (dt >= 1 && dt <= 4) {
          rSeq++;
        } else if (dt >= 5 && dt <= 7) {
          rBead++;
        }
      }
    }

    countDev(0);

    void closeRun(int endIdx) {
      if (endIdx - rStart >= 2) {
        runs.add((
          color: rColor,
          start: rStart,
          end: endIdx,
          minX: rMinX,
          maxX: rMaxX,
          minY: rMinY,
          maxY: rMaxY,
          seq: rSeq,
          bead: rBead,
        ));
      }
    }

    for (int i = 1; i < n; i++) {
      final double x = data.stX[i], y = data.stY[i];
      final int c = data.stColor[i];
      final bool isJump = data.stMove[i] != 0 || c != rColor;
      final double dx = x - data.stX[i - 1];
      final double dy = y - data.stY[i - 1];
      final double dPrev = math.sqrt(dx * dx + dy * dy);

      if (isJump || dPrev > 115.0) {
        closeRun(i);
        rStart = i;
        rColor = c;
        rMinX = rMaxX = x;
        rMinY = rMaxY = y;
        rSeq = 0;
        rBead = 0;
        countDev(i);
      } else {
        if (x < rMinX) rMinX = x;
        if (x > rMaxX) rMaxX = x;
        if (y < rMinY) rMinY = y;
        if (y > rMaxY) rMaxY = y;
        countDev(i);
      }
    }
    closeRun(n);

    if (runs.isEmpty) return const [];

    const double mergePad = 32.0;
    final List<ProDesignObject> objects = [];

    int curColor = runs[0].color;
    List<(int, int)> curRanges = [(runs[0].start, runs[0].end)];
    double cMinX = runs[0].minX, cMaxX = runs[0].maxX;
    double cMinY = runs[0].minY, cMaxY = runs[0].maxY;
    int cStitches = runs[0].end - runs[0].start;
    int cSeq = runs[0].seq;
    int cBead = runs[0].bead;

    void flushObj() {
      objects.add(ProDesignObject(
        id: objects.length,
        colorIndex: curColor,
        ranges: List.from(curRanges),
        minX: cMinX,
        maxX: cMaxX,
        minY: cMinY,
        maxY: cMaxY,
        stitchCount: cStitches,
        sequinsCount: cSeq,
        beadsCount: cBead,
      ));
    }

    for (int i = 1; i < runs.length; i++) {
      final r = runs[i];
      final bool sameColor = r.color == curColor;
      final bool overlaps = r.minX <= cMaxX + mergePad &&
          r.maxX >= cMinX - mergePad &&
          r.minY <= cMaxY + mergePad &&
          r.maxY >= cMinY - mergePad;

      if (sameColor && overlaps) {
        curRanges.add((r.start, r.end));
        if (r.minX < cMinX) cMinX = r.minX;
        if (r.maxX > cMaxX) cMaxX = r.maxX;
        if (r.minY < cMinY) cMinY = r.minY;
        if (r.maxY > cMaxY) cMaxY = r.maxY;
        cStitches += (r.end - r.start);
        cSeq += r.seq;
        cBead += r.bead;
      } else {
        flushObj();
        curColor = r.color;
        curRanges = [(r.start, r.end)];
        cMinX = r.minX;
        cMaxX = r.maxX;
        cMinY = r.minY;
        cMaxY = r.maxY;
        cStitches = r.end - r.start;
        cSeq = r.seq;
        cBead = r.bead;
      }
    }
    flushObj();

    return objects;
  }

  static int? hitTest(
    List<ProDesignObject> objects,
    List<ProObjectTransform> transforms,
    double designX,
    double designY, {
    double padUnits = 25.0,
  }) {
    int? bestIdx;
    double bestArea = double.infinity;

    for (int tIdx = 0; tIdx < transforms.length; tIdx++) {
      final tf = transforms[tIdx];
      if (tf.deleted) continue;
      if (tf.sourceObjectId < 0 || tf.sourceObjectId >= objects.length) continue;
      final obj = objects[tf.sourceObjectId];
      final b = tf.transformedBounds(obj);
      if (designX >= b.$1 - padUnits &&
          designX <= b.$2 + padUnits &&
          designY >= b.$3 - padUnits &&
          designY <= b.$4 + padUnits) {
        final double area = math.max(1.0, (b.$2 - b.$1) * (b.$4 - b.$3));
        if (area < bestArea) {
          bestArea = area;
          bestIdx = tIdx;
        }
      }
    }
    return bestIdx;
  }

  static VectorDesignData apply(
    VectorDesignData src,
    List<ProDesignObject> objects,
    List<ProObjectTransform> transforms, {
    List<int>? customPaletteArgb,
  }) {
    final bool hasSrcDev = src.stDev != null && src.stDev!.length == src.stX.length;
    final stX = _ProFloat32Buf(math.max(256, src.stX.length));
    final stY = _ProFloat32Buf(math.max(256, src.stX.length));
    final stMove = _ProUint8Buf(math.max(256, src.stX.length));
    final stColor = _ProUint8Buf(math.max(256, src.stX.length));
    final stDev = hasSrcDev ? _ProUint8Buf(math.max(256, src.stX.length)) : null;

    final seqX = _ProFloat32Buf(math.max(32, src.seqX.length));
    final seqY = _ProFloat32Buf(math.max(32, src.seqX.length));
    final seqCode = _ProUint8Buf(math.max(32, src.seqCode.length));

    final beadX = _ProFloat32Buf(math.max(32, src.beadX.length));
    final beadY = _ProFloat32Buf(math.max(32, src.beadX.length));
    final beadCode = _ProUint8Buf(math.max(32, src.beadCode.length));

    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    final Set<int> usedColors = {};
    int jumpsCount = 0;
    int trimsCount = src.trimsCount;
    bool prevRequestedTrim = false;

    for (final tf in transforms) {
      if (tf.deleted) continue;
      if (tf.sourceObjectId < 0 || tf.sourceObjectId >= objects.length) continue;
      final obj = objects[tf.sourceObjectId];
      final double cx = obj.centerX;
      final double cy = obj.centerY;
      final double rad = tf.rotationDeg * math.pi / 180.0;
      final double ca = math.cos(rad);
      final double sa = math.sin(rad);

      bool firstOfObj = true;
      for (final rng in obj.ranges) {
        final int s = rng.$1.clamp(0, src.stX.length);
        final int e = rng.$2.clamp(s, src.stX.length);
        for (int i = s; i < e; i++) {
          final double lx = (src.stX[i] - cx) * tf.scaleX * (tf.flipH ? -1.0 : 1.0);
          final double ly = (src.stY[i] - cy) * tf.scaleY * (tf.flipV ? -1.0 : 1.0);
          final double rx = lx * ca - ly * sa + cx + tf.dx;
          final double ry = lx * sa + ly * ca + cy + tf.dy;

          final int mv = prevRequestedTrim ? 3 : ((firstOfObj || i == s) ? 1 : src.stMove[i]);
          final int c = tf.colorIndexOverride ?? src.stColor[i];

          stX.add(rx);
          stY.add(ry);
          stMove.add(mv);
          stColor.add(c);
          if (mv != 0) jumpsCount++;
          usedColors.add(c);
          firstOfObj = false;
          prevRequestedTrim = false;

          if (hasSrcDev && stDev != null) {
            final int dv = src.stDev![i];
            stDev.add(dv);
            final int dt = dv & 0x0F;
            if (dt >= 1 && dt <= 4) {
              seqX.add(rx);
              seqY.add(ry);
              seqCode.add(dt);
            } else if (dt >= 5 && dt <= 7) {
              beadX.add(rx);
              beadY.add(ry);
              beadCode.add(dt - 4);
            }
          }

          if (!hasBounds) {
            minX = maxX = rx;
            minY = maxY = ry;
            hasBounds = true;
          } else {
            if (rx < minX) minX = rx;
            if (rx > maxX) maxX = rx;
            if (ry < minY) minY = ry;
            if (ry > maxY) maxY = ry;
          }
        }
      }

      if (tf.insertTrimAfter) {
        trimsCount++;
        prevRequestedTrim = true;
      }
    }

    if (!hasSrcDev && (src.seqX.isNotEmpty || src.beadX.isNotEmpty)) {
      int findOwnerObj(double x, double y) {
        int best = 0;
        double bestDist = double.infinity;
        for (int o = 0; o < objects.length; o++) {
          final obj = objects[o];
          if (x >= obj.minX - 15.0 && x <= obj.maxX + 15.0 && y >= obj.minY - 15.0 && y <= obj.maxY + 15.0) {
            return o;
          }
          final double d = (x - obj.centerX) * (x - obj.centerX) + (y - obj.centerY) * (y - obj.centerY);
          if (d < bestDist) {
            bestDist = d;
            best = o;
          }
        }
        return best;
      }

      void mapDecorations(
        Float32List inX,
        Float32List inY,
        Uint8List inCode,
        _ProFloat32Buf outX,
        _ProFloat32Buf outY,
        _ProUint8Buf outCode,
      ) {
        for (int i = 0; i < inX.length; i++) {
          final int owner = findOwnerObj(inX[i], inY[i]);
          final obj = objects[owner];
          for (final tf in transforms) {
            if (tf.deleted || tf.sourceObjectId != owner) continue;
            final double rad = tf.rotationDeg * math.pi / 180.0;
            final double ca = math.cos(rad);
            final double sa = math.sin(rad);
            final double lx = (inX[i] - obj.centerX) * tf.scaleX * (tf.flipH ? -1.0 : 1.0);
            final double ly = (inY[i] - obj.centerY) * tf.scaleY * (tf.flipV ? -1.0 : 1.0);
            outX.add(lx * ca - ly * sa + obj.centerX + tf.dx);
            outY.add(lx * sa + ly * ca + obj.centerY + tf.dy);
            outCode.add(inCode[i]);
          }
        }
      }

      mapDecorations(src.seqX, src.seqY, src.seqCode, seqX, seqY, seqCode);
      mapDecorations(src.beadX, src.beadY, src.beadCode, beadX, beadY, beadCode);
    }

    final Int32List outPalette = customPaletteArgb != null && customPaletteArgb.isNotEmpty
        ? Int32List.fromList(customPaletteArgb)
        : src.paletteArgb;

    return VectorDesignData(
      stX: stX.finish(),
      stY: stY.finish(),
      stMove: stMove.finish(),
      stColor: stColor.finish(),
      stDev: stDev?.finish(),
      seqX: seqX.finish(),
      seqY: seqY.finish(),
      seqCode: seqCode.finish(),
      beadX: beadX.finish(),
      beadY: beadY.finish(),
      beadCode: beadCode.finish(),
      paletteArgb: outPalette,
      stitches: stX.length,
      colorCount: math.max(1, usedColors.length),
      stopsCount: usedColors.length > 1 ? usedColors.length - 1 : 0,
      jumpsCount: jumpsCount,
      sequinsCount: seqX.length,
      beadsCount: beadX.length,
      trimsCount: trimsCount,
      minX: hasBounds ? minX : 0,
      maxX: hasBounds ? maxX : 0,
      minY: hasBounds ? minY : 0,
      maxY: hasBounds ? maxY : 0,
      hasBounds: hasBounds,
      machineType: src.machineType,
    );
  }
}


// ============================================================================
// TARIK EMB PRO v6 — INDUSTRIAL CORE & STUDIO FOUNDATION (NO DEAD ENDS)
// - معايير Wilcom / Tajima / pyembroidery الهندسية
// - نماذج المستند والعناصر المشتركة لجميع المراحل (معالجة + رسم ويلكم/داهاو + .temb)
// - مصدّر DST صناعي حقيقي (مقص 3 قفزات متعادلة + غرز قفل تلقائية Tie-In / Tie-Off)
// - قارئ TBF مصحّح (يفصل المقص 0x86 والترتر 0x87 عن تغيير اللون 0x40)
// - طبيب الفيلم (Film Doctor) لفحص وتنظيف الغرز القصيرة والطويلة والوقفات المكررة
// ============================================================================

/// الثوابت الهندسية العالمية للماكينات الصناعية (وحدة واحدة = 0.1 مم)
class EmbMachineSpecs {
  static const double unitsPerMm = 10.0;
  static const double unitsPerCm = 100.0;
  static const double maxDstStepUnits = 121.0; // 12.1 مم (تشفير تاجيما الثلاثي المتوازن)
  static const double defaultAutoSplitMm = 7.5; // حد التقسيم التلقائي الموصى به (7-8 مم)
  static const double defaultShortStitchMm = 0.35; // فلتر الغرز القصيرة لمنع تكدس الإبرة
  static const double defaultLockStitchMm = 0.70; // طول غرزة القفل للقماش العادي
  static const double leatherLockStitchMm = 1.00; // طول غرزة القفل للجلد واللباد
  static const double defaultTrimThresholdMm = 2.0; // حد القص التلقائي
  static const int defaultTajimaTrimJumps = 3; // إعداد المصنع (Jump Convert = 3)
  static const double defaultSatinDensityMm = 0.40;
  static const double defaultTatamiLengthMm = 4.0;
  static const double defaultRunLengthMm = 2.5;
}

/// أعلام الغرزة الفردية (متوافقة مع معالجة الغرز + الرسم + تصدير DST/TBF/DHP)
class EmbStitchFlags {
  static const int normal = 0; // غرزة عادية
  static const int jump = 1; // قفزة/انتقال
  static const int trim = 3; // مقص حقيقي (3 قفزات تاجيما + قفل)
  static const int lockStitch = 4; // غرزة قفل Tie-In / Tie-Off محمية من الفلتر
}

/// غرزة مفردة قابلة للمعالجة الكاملة (أساس المرحلة 1: صفحة معالجة الأفلام)
class EmbEditableStitch {
  double x; // بوحدة 0.1 مم
  double y; // بوحدة 0.1 مم (للأسفل موجب على الشاشة)
  int moveFlag; // 0=عادي, 1=جمب, 2=جمب صامت, 3=مقص حقيقي
  int colorIndex;
  int devCode; // أكواد الترتر (1..4) والخرز (5..7)
  bool isLockStitch;

  EmbEditableStitch({
    required this.x,
    required this.y,
    this.moveFlag = 0,
    this.colorIndex = 0,
    this.devCode = 0,
    this.isLockStitch = false,
  });

  EmbEditableStitch clone() => EmbEditableStitch(
        x: x,
        y: y,
        moveFlag: moveFlag,
        colorIndex: colorIndex,
        devCode: devCode,
        isLockStitch: isLockStitch,
      );

  Map<String, dynamic> toJson() => {
        'x': (x * 10).round() / 10.0,
        'y': (y * 10).round() / 10.0,
        if (moveFlag != 0) 'm': moveFlag,
        if (colorIndex != 0) 'c': colorIndex,
        if (devCode != 0) 'd': devCode,
        if (isLockStitch) 'l': 1,
      };

  factory EmbEditableStitch.fromJson(Map<String, dynamic> j) => EmbEditableStitch(
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        moveFlag: (j['m'] as num?)?.toInt() ?? 0,
        colorIndex: (j['c'] as num?)?.toInt() ?? 0,
        devCode: (j['d'] as num?)?.toInt() ?? 0,
        isLockStitch: (j['l'] as num?)?.toInt() == 1,
      );
}

/// عقدة رسم متجهية (أساس المرحلة 2 و3: رسم ويلكم وداهاو — نقرة يسار زاوية / نقرة يمين منحنى)
class EmbStudioNode {
  double x;
  double y;
  bool isCurve; // false = زاوية حادة ■ (Left Click), true = منحنى ناعم ● (Right Click)

  EmbStudioNode({required this.x, required this.y, this.isCurve = false});

  EmbStudioNode clone() => EmbStudioNode(x: x, y: y, isCurve: isCurve);

  Map<String, dynamic> toJson() => {
        'x': (x * 10).round() / 10.0,
        'y': (y * 10).round() / 10.0,
        if (isCurve) 'c': 1,
      };

  factory EmbStudioNode.fromJson(Map<String, dynamic> j) => EmbStudioNode(
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        isCurve: (j['c'] as num?)?.toInt() == 1,
      );
}

/// نوع عنصر الرسم في الاستوديو (قابل للتوسع في المرحلتين 2 و3 دون كسر بنية المستند)
enum EmbStudioObjectType {
  rawStitches,
  run,
  tripleRun,
  manual,
  satinInputA,
  satinInputC,
  tatamiFill,
  sequinRun,
  beadRun,
}

/// عنصر رسم متجهي مع خصائصه الكاملة (Wilcom/Dahao Object)
class EmbStudioObject {
  final String id;
  EmbStudioObjectType type;
  int colorIndex;
  List<EmbStudioNode> nodes;
  List<EmbStudioNode> railB; // للـ Input A فقط
  List<List<EmbStudioNode>> holes; // فتحات التاتامي الداخلية
  double stitchLengthMm;
  double densityMm;
  double widthMm; // للـ Input C
  double pullCompMm;
  double angleDeg;
  int underlayMode; // 0=بدون, 1=Center, 2=Edge, 3=Zigzag, 4=Tatami 90
  int deviceCode; // للترتر أو الخرز
  bool autoTrimAfter;
  bool visible;
  bool locked;

  EmbStudioObject({
    required this.id,
    required this.type,
    this.colorIndex = 0,
    List<EmbStudioNode>? nodes,
    List<EmbStudioNode>? railB,
    List<List<EmbStudioNode>>? holes,
    this.stitchLengthMm = EmbMachineSpecs.defaultRunLengthMm,
    this.densityMm = EmbMachineSpecs.defaultSatinDensityMm,
    this.widthMm = 3.0,
    this.pullCompMm = 0.20,
    this.angleDeg = 0.0,
    this.underlayMode = 1,
    this.deviceCode = 0,
    this.autoTrimAfter = true,
    this.visible = true,
    this.locked = false,
  })  : nodes = nodes ?? [],
        railB = railB ?? [],
        holes = holes ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'colorIndex': colorIndex,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        if (railB.isNotEmpty) 'railB': railB.map((n) => n.toJson()).toList(),
        if (holes.isNotEmpty)
          'holes': holes.map((h) => h.map((n) => n.toJson()).toList()).toList(),
        'stitchLengthMm': stitchLengthMm,
        'densityMm': densityMm,
        'widthMm': widthMm,
        'pullCompMm': pullCompMm,
        'angleDeg': angleDeg,
        'underlayMode': underlayMode,
        'deviceCode': deviceCode,
        'autoTrimAfter': autoTrimAfter,
        'visible': visible,
        'locked': locked,
      };

  factory EmbStudioObject.fromJson(Map<String, dynamic> j) => EmbStudioObject(
        id: (j['id'] ?? '').toString(),
        type: EmbStudioObjectType.values.firstWhere(
          (e) => e.name == j['type'],
          orElse: () => EmbStudioObjectType.run,
        ),
        colorIndex: (j['colorIndex'] as num?)?.toInt() ?? 0,
        nodes: ((j['nodes'] as List?) ?? const [])
            .map((e) => EmbStudioNode.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        railB: ((j['railB'] as List?) ?? const [])
            .map((e) => EmbStudioNode.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        holes: ((j['holes'] as List?) ?? const [])
            .map((h) => (h as List)
                .map((e) => EmbStudioNode.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList())
            .toList(),
        stitchLengthMm: (j['stitchLengthMm'] as num?)?.toDouble() ?? EmbMachineSpecs.defaultRunLengthMm,
        densityMm: (j['densityMm'] as num?)?.toDouble() ?? EmbMachineSpecs.defaultSatinDensityMm,
        widthMm: (j['widthMm'] as num?)?.toDouble() ?? 3.0,
        pullCompMm: (j['pullCompMm'] as num?)?.toDouble() ?? 0.20,
        angleDeg: (j['angleDeg'] as num?)?.toDouble() ?? 0.0,
        underlayMode: (j['underlayMode'] as num?)?.toInt() ?? 1,
        deviceCode: (j['deviceCode'] as num?)?.toInt() ?? 0,
        autoTrimAfter: j['autoTrimAfter'] != false,
        visible: j['visible'] != false,
        locked: j['locked'] == true,
      );
}

/// المستند الموحّد للاستوديو (.temb) — يربط بين معالجة الغرز وأدوات الرسم والتصدير للمكينة
class EmbStudioDocument {
  String name;
  String machineType;
  List<int> paletteArgb;
  List<EmbEditableStitch> stitches;
  List<EmbStudioObject> objects;
  int trimJumpCount;
  bool autoLockStitches;
  double lockStitchLengthMm;

  EmbStudioDocument({
    this.name = 'tarik_studio',
    this.machineType = 'Tajima (DST)',
    required this.paletteArgb,
    required this.stitches,
    List<EmbStudioObject>? objects,
    this.trimJumpCount = EmbMachineSpecs.defaultTajimaTrimJumps,
    this.autoLockStitches = true,
    this.lockStitchLengthMm = EmbMachineSpecs.defaultLockStitchMm,
  }) : objects = objects ?? [];

  factory EmbStudioDocument.fromVector(VectorDesignData v, {String name = 'tarik_studio'}) {
    final int n = v.stX.length;
    final Uint8List? dev = v.stDev;
    final List<EmbEditableStitch> list = List.generate(n, (i) {
      return EmbEditableStitch(
        x: v.stX[i],
        y: v.stY[i],
        moveFlag: v.stMove[i],
        colorIndex: v.stColor[i],
        devCode: (dev != null && i < dev.length) ? dev[i] : 0,
      );
    });
    return EmbStudioDocument(
      name: name,
      machineType: v.machineType,
      paletteArgb: v.paletteArgb.isNotEmpty
          ? v.paletteArgb.toList()
          : [0xFF007BFF, 0xFFFF1744, 0xFF00C853, 0xFFFFB300],
      stitches: list,
    );
  }

  EmbStudioDocument clone() => EmbStudioDocument(
        name: name,
        machineType: machineType,
        paletteArgb: List<int>.from(paletteArgb),
        stitches: stitches.map((s) => s.clone()).toList(),
        objects: objects,
        trimJumpCount: trimJumpCount,
        autoLockStitches: autoLockStitches,
        lockStitchLengthMm: lockStitchLengthMm,
      );

  VectorDesignData toVectorDesignData() {
    final int n = stitches.length;
    final stX = Float32List(n);
    final stY = Float32List(n);
    final stMove = Uint8List(n);
    final stColor = Uint8List(n);
    final stDev = Uint8List(n);
    bool hasAnyDev = false;

    final seqX = _ProFloat32Buf(64);
    final seqY = _ProFloat32Buf(64);
    final seqCode = _ProUint8Buf(64);
    final beadX = _ProFloat32Buf(64);
    final beadY = _ProFloat32Buf(64);
    final beadCode = _ProUint8Buf(64);

    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int jumpsCount = 0;
    int trimsCount = 0;
    int stopsCount = 0;
    int prevColor = -1;
    final Set<int> usedColors = {};

    for (int i = 0; i < n; i++) {
      final s = stitches[i];
      stX[i] = s.x;
      stY[i] = s.y;
      stMove[i] = s.moveFlag;
      stColor[i] = s.colorIndex.clamp(0, 255);
      stDev[i] = s.devCode.clamp(0, 255);

      if (s.moveFlag == EmbStitchFlags.trim) {
        trimsCount++;
        jumpsCount++;
      } else if (s.moveFlag != 0) {
        jumpsCount++;
      }
      if (prevColor >= 0 && stColor[i] != prevColor) {
        stopsCount++;
      }
      prevColor = stColor[i];
      usedColors.add(stColor[i]);

      if (s.devCode != 0) {
        hasAnyDev = true;
        final int dt = s.devCode & 0x0F;
        if (dt >= 1 && dt <= 4) {
          seqX.add(s.x);
          seqY.add(s.y);
          seqCode.add(dt);
        } else if (dt >= 5 && dt <= 7) {
          beadX.add(s.x);
          beadY.add(s.y);
          beadCode.add(dt - 4);
        }
      }

      if (!hasBounds) {
        minX = maxX = s.x;
        minY = maxY = s.y;
        hasBounds = true;
      } else {
        if (s.x < minX) minX = s.x;
        if (s.x > maxX) maxX = s.x;
        if (s.y < minY) minY = s.y;
        if (s.y > maxY) maxY = s.y;
      }
    }

    return VectorDesignData(
      stX: stX,
      stY: stY,
      stMove: stMove,
      stColor: stColor,
      stDev: hasAnyDev ? stDev : null,
      seqX: seqX.finish(),
      seqY: seqY.finish(),
      seqCode: seqCode.finish(),
      beadX: beadX.finish(),
      beadY: beadY.finish(),
      beadCode: beadCode.finish(),
      paletteArgb: Int32List.fromList(
        paletteArgb.isNotEmpty ? paletteArgb : const [0xFF007BFF],
      ),
      stitches: n,
      colorCount: math.max(1, stopsCount + 1),
      stopsCount: stopsCount,
      jumpsCount: jumpsCount,
      sequinsCount: seqX.length,
      beadsCount: beadX.length,
      trimsCount: trimsCount,
      minX: hasBounds ? minX : 0.0,
      maxX: hasBounds ? maxX : 0.0,
      minY: hasBounds ? minY : 0.0,
      maxY: hasBounds ? maxY : 0.0,
      hasBounds: hasBounds,
      machineType: machineType,
    );
  }

  String toProjectJson() => jsonEncode({
        'version': 1,
        'app': 'TarikEMB',
        'name': name,
        'machineType': machineType,
        'trimJumpCount': trimJumpCount,
        'autoLockStitches': autoLockStitches,
        'lockStitchLengthMm': lockStitchLengthMm,
        'paletteArgb': paletteArgb,
        'objects': objects.map((o) => o.toJson()).toList(),
        'stitches': stitches.map((s) => s.toJson()).toList(),
      });

  factory EmbStudioDocument.fromProjectJson(String raw) {
    final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
    return EmbStudioDocument(
      name: (j['name'] ?? 'tarik_studio').toString(),
      machineType: (j['machineType'] ?? 'Tajima (DST)').toString(),
      trimJumpCount: (j['trimJumpCount'] as num?)?.toInt() ?? EmbMachineSpecs.defaultTajimaTrimJumps,
      autoLockStitches: j['autoLockStitches'] != false,
      lockStitchLengthMm: (j['lockStitchLengthMm'] as num?)?.toDouble() ?? EmbMachineSpecs.defaultLockStitchMm,
      paletteArgb: ((j['paletteArgb'] as List?) ?? const [0xFF007BFF])
          .map((e) => (e as num).toInt())
          .toList(),
      objects: ((j['objects'] as List?) ?? const [])
          .map((e) => EmbStudioObject.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      stitches: ((j['stitches'] as List?) ?? const [])
          .map((e) => EmbEditableStitch.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

/// مصدّر تاجيما الصناعي الحقيقي (.DST):
/// - يكتب أمر المقص الحقيقي كـ 3 قفزات متعادلة (+2,+2 ثم -4,-4 ثم +2,+2) وفق Jump Convert = 3
/// - يضيف غرز قفل تلقائية (Tie-Off قبل المقص و Tie-In بعد القفزة) بطول 0.7 مم لمنع انفكاك الخيط
/// - يقسّم أي حركة تتجاوز ±121 وحدة (12.1 مم) بالتشفير الثلاثي المتوازن القياسي
/// - يحافظ على أوامر الترتر الأربعة في stDev بنسبة 100%
class TarikProDstEncoder {
  static void _writeTriplet(BytesBuilder out, int dx, int dy, bool isJump, bool isStop) {
    int b0 = 0, b1 = 0, b2 = 0x03;
    int x = dx.clamp(-121, 121);
    int y = dy.clamp(-121, 121);

    if (x >= 41) { b2 |= 0x04; x -= 81; }
    if (x <= -41) { b2 |= 0x08; x += 81; }
    if (x >= 14) { b1 |= 0x04; x -= 27; }
    if (x <= -14) { b1 |= 0x08; x += 27; }
    if (x >= 5) { b0 |= 0x04; x -= 9; }
    if (x <= -5) { b0 |= 0x08; x += 9; }
    if (x >= 2) { b1 |= 0x01; x -= 3; }
    if (x <= -2) { b1 |= 0x02; x += 3; }
    if (x >= 1) { b0 |= 0x01; x -= 1; }
    if (x <= -1) { b0 |= 0x02; x += 1; }

    if (y >= 41) { b2 |= 0x20; y -= 81; }
    if (y <= -41) { b2 |= 0x10; y += 81; }
    if (y >= 14) { b1 |= 0x20; y -= 27; }
    if (y <= -14) { b1 |= 0x10; y += 27; }
    if (y >= 5) { b0 |= 0x20; y -= 9; }
    if (y <= -5) { b0 |= 0x10; y += 9; }
    if (y >= 2) { b1 |= 0x80; y -= 3; }
    if (y <= -2) { b1 |= 0x40; y += 3; }
    if (y >= 1) { b0 |= 0x80; y -= 1; }
    if (y <= -1) { b0 |= 0x40; y += 1; }

    if (isStop) {
      b2 |= 0xC0;
    } else if (isJump) {
      b2 |= 0x80;
    }

    out.add([b0, b1, b2]);
  }

  static Uint8List encode(
    VectorDesignData vec,
    String rawBaseName, {
    int trimJumps = EmbMachineSpecs.defaultTajimaTrimJumps,
    bool autoLockOnTrim = true,
    double lockLenMm = EmbMachineSpecs.defaultLockStitchMm,
  }) {
    final String baseName = rawBaseName.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    final String label = (baseName.isEmpty ? 'TARIK_EMB' : baseName).padRight(16).substring(0, 16);

    final body = BytesBuilder(copy: false);
    final Float32List stX = vec.stX;
    final Float32List stY = vec.stY;
    final Uint8List stMove = vec.stMove;
    final Uint8List stColor = vec.stColor;
    final Uint8List? stDev = vec.stDev;
    final int n = stX.length;
    if (n == 0) return Uint8List(0);

    int curX = 0, curY = 0;
    int minX = 0, maxX = 0, minY = 0, maxY = 0;
    int totalRecords = 0;
    int colorChanges = 0;
    int activeColor = stColor[0];
    bool inSeqMode = false;
    final int lockStep = (lockLenMm.clamp(0.5, 1.2) * 10.0).round();

    void trackBounds() {
      if (curX < minX) minX = curX;
      if (curX > maxX) maxX = curX;
      if (curY < minY) minY = curY;
      if (curY > maxY) maxY = curY;
    }

    void emitSeqToggle() {
      body.add(const [0x00, 0x00, 0x43]);
      totalRecords++;
      inSeqMode = !inSeqMode;
    }

    void emitDelta(int dx, int dy, bool isJump, bool isStop) {
      int remX = dx;
      int remY = dy;
      while (remX.abs() > 121 || remY.abs() > 121) {
        final int stepX = remX.clamp(-121, 121);
        final int stepY = remY.clamp(-121, 121);
        _writeTriplet(body, stepX, stepY, true, false);
        curX += stepX;
        curY += stepY;
        trackBounds();
        totalRecords++;
        remX -= stepX;
        remY -= stepY;
      }
      _writeTriplet(body, remX, remY, isJump, isStop);
      curX += remX;
      curY += remY;
      trackBounds();
      totalRecords++;
    }

    /// إدراج غرز قفل (Tie-Off / Tie-In) بمحصّلة صفر (للأمام ثم للخلف بنفس النقطة)
    void emitLockPair(int dirX, int dirY) {
      final int lx = dirX.clamp(-lockStep, lockStep);
      final int ly = dirY.clamp(-lockStep, lockStep);
      if (lx == 0 && ly == 0) {
        emitDelta(lockStep, 0, false, false);
        emitDelta(-lockStep, 0, false, false);
      } else {
        emitDelta(lx, ly, false, false);
        emitDelta(-lx, -ly, false, false);
      }
    }

    /// إدراج مقص تاجيما الحقيقي (Jump Convert = trimJumps، محصلته 0 تماماً)
    void emitTajimaTrim() {
      if (inSeqMode) emitSeqToggle();
      final int count = trimJumps.clamp(2, 5);
      if (count == 2) {
        emitDelta(2, 2, true, false);
        emitDelta(-2, -2, true, false);
      } else if (count == 3) {
        emitDelta(2, 2, true, false);
        emitDelta(-4, -4, true, false);
        emitDelta(2, 2, true, false);
      } else if (count == 4) {
        emitDelta(2, 0, true, false);
        emitDelta(-4, 0, true, false);
        emitDelta(4, 0, true, false);
        emitDelta(-2, 0, true, false);
      } else {
        emitDelta(2, 2, true, false);
        emitDelta(-4, -4, true, false);
        emitDelta(4, 4, true, false);
        emitDelta(-4, -4, true, false);
        emitDelta(2, 2, true, false);
      }
    }

    for (int i = 0; i < n; i++) {
      final int tx = stX[i].round();
      final int ty = (-stY[i]).round();
      final int c = stColor[i];
      final int dev = (stDev != null && i < stDev.length) ? stDev[i] : 0;
      final int dtype = dev & 0x0F;
      final bool devOn = (dev & 0x10) != 0;
      final bool devOff = (dev & 0x20) != 0;
      final int mv = stMove[i];

      if (i > 0 && c != activeColor) {
        if (autoLockOnTrim && !inSeqMode) emitLockPair(lockStep, 0);
        if (inSeqMode) emitSeqToggle();
        emitDelta(0, 0, false, true);
        colorChanges++;
        activeColor = c;
      }

      final int dx = tx - curX;
      final int dy = ty - curY;

      if (dtype >= 1 && dtype <= 4) {
        if (!inSeqMode) emitSeqToggle();
        emitDelta(dx, dy, true, false);
        final int extraJumps = dtype == 1 ? 0 : (dtype == 2 ? 1 : (dtype == 3 ? 3 : 7));
        for (int k = 0; k < extraJumps; k++) {
          emitDelta(0, 0, true, false);
        }
      } else if (mv == EmbStitchFlags.trim) {
        // مقص حقيقي مع قفل الخيط قبل وبعد القطع (معيار ويلكم وتاجيما)
        if (i > 0 && autoLockOnTrim) {
          emitLockPair(lockStep, 0);
        }
        emitTajimaTrim();
        if (dx != 0 || dy != 0) {
          emitDelta(dx, dy, true, false);
        }
        emitDelta(0, 0, false, false);
        if (autoLockOnTrim) {
          emitLockPair(lockStep, 0);
        }
      } else if (mv == 2) {
        if (dx != 0 || dy != 0) {
          emitDelta(dx, dy, true, false);
        }
      } else if (mv != 0 && (dx.abs() > 0 || dy.abs() > 0)) {
        emitDelta(dx, dy, true, false);
        emitDelta(0, 0, false, false);
      } else {
        emitDelta(dx, dy, false, false);
      }

      if (devOn && !inSeqMode) emitSeqToggle();
      if (devOff && inSeqMode) emitSeqToggle();
    }

    if (inSeqMode) emitSeqToggle();
    body.add(const [0x00, 0x00, 0xF3]);

    final int px = maxX.abs().clamp(0, 99999);
    final int mx = minX.abs().clamp(0, 99999);
    final int py = maxY.abs().clamp(0, 99999);
    final int my = minY.abs().clamp(0, 99999);
    final int ax = curX.clamp(-99999, 99999);
    final int ay = curY.clamp(-99999, 99999);

    String fmtSigned5(int v) => (v >= 0 ? '+' : '-') + v.abs().toString().padLeft(5);

    final String headerStr = 'LA:$label\r'
        'ST:${totalRecords.toString().padLeft(7)}\r'
        'CO:${colorChanges.toString().padLeft(3)}\r'
        '+X:${px.toString().padLeft(5)}\r'
        '-X:${mx.toString().padLeft(5)}\r'
        '+Y:${py.toString().padLeft(5)}\r'
        '-Y:${my.toString().padLeft(5)}\r'
        'AX:${fmtSigned5(ax)}\r'
        'AY:${fmtSigned5(ay)}\r'
        'MX:+    0\r'
        'MY:+    0\r'
        'PD:******\r\x1a';

    final Uint8List header = Uint8List(512)..fillRange(0, 512, 0x20);
    final List<int> hBytes = headerStr.codeUnits;
    final int copyLen = math.min(512, hBytes.length);
    for (int i = 0; i < copyLen; i++) {
      header[i] = hBytes[i];
    }

    final out = BytesBuilder(copy: false);
    out.add(header);
    out.add(body.takeBytes());
    return out.takeBytes();
  }

  /// تصدير موحّد لأي صيغة: يستخدم محرك DST الصناعي الحقيقي لملفات .DST، والمحرك العام لبقية الصيغ
  static Future<String?> exportToFile(
    VectorDesignData vec,
    String outPath,
    String formatExt, {
    String baseName = 'tarik_emb',
    int trimJumps = EmbMachineSpecs.defaultTajimaTrimJumps,
    bool autoLockOnTrim = true,
  }) async {
    final ext = formatExt.toUpperCase().replaceAll('.', '');
    if (ext == 'DST') {
      try {
        final bytes = await Isolate.run(() => encode(
              vec,
              baseName,
              trimJumps: trimJumps,
              autoLockOnTrim: autoLockOnTrim,
            ));
        if (bytes.isEmpty) return null;
        final file = File(outPath);
        await file.writeAsBytes(bytes, flush: true);
        return outPath;
      } catch (_) {
        return null;
      }
    }
    return VectorDesignEditor.exportVectorToFile(vec, outPath, ext, baseName: baseName);
  }
}

/// قارئ ملفات Tajima Modern (.TBF) المصحّح:
/// - يعالج خطأ عدّ المقص (0x86) والترتر (0x87) كتغيير لون (الذي كان يُظهر 662 لوناً بدلاً من الألوان الحقيقية!)
/// - يرسم المعاينة بمحرك TarikPro3DRenderer بدون خطوط قفزات عابرة مشوِّهة
class TarikProTbfParser {
  static final Int32List _palette = Int32List.fromList(const [
    0xFF007BFF, 0xFFFF1744, 0xFF00C853, 0xFFFFB300, 0xFFD500F9,
    0xFFFF5722, 0xFF00E5FF, 0xFFFF007F, 0xFF76FF03, 0xFF3D5AFE,
    0xFF00BFA5, 0xFFFF6D00, 0xFF651FFF, 0xFFFFD600,
  ]);

  static int _s8(int b) => b >= 128 ? b - 256 : b;

  static VectorDesignData? decodeSync(Uint8List bytes) {
    if (bytes.length < 0x603) return null;
    final stX = _ProFloat32Buf(8192);
    final stY = _ProFloat32Buf(8192);
    final stMove = _ProUint8Buf(8192);
    final stColor = _ProUint8Buf(8192);
    final stDev = _ProUint8Buf(8192);
    final seqX = _ProFloat32Buf(64);
    final seqY = _ProFloat32Buf(64);
    final seqCode = _ProUint8Buf(64);

    int x = 0, y = 0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int colorIdx = 0;
    int colorCount = 1;
    int stitchCount = 0;
    int jumpCount = 0;
    int trimsCount = 0;
    bool needMove = true;
    bool hasStitchesInCurColor = false;
    bool hasAnyDev = false;

    for (int i = 0x600; i + 2 < bytes.length; i += 3) {
      final int dx = _s8(bytes[i]);
      final int dy = _s8(bytes[i + 1]);
      final int ctrl = bytes[i + 2];

      if (ctrl == 0x8F) break;
      x += dx;
      y += dy;

      if (ctrl == 0x40 || (ctrl >= 0x41 && ctrl <= 0x4F)) {
        // تغيير لون / إبرة حقيقي فقط (وليس مقص 0x86!)
        if (hasStitchesInCurColor) {
          colorIdx = (colorIdx + 1) % _palette.length;
          colorCount++;
          hasStitchesInCurColor = false;
        }
        needMove = true;
      } else if (ctrl == 0x86) {
        // أمر مقص (Trim) في Tajima TBF
        trimsCount++;
        jumpCount++;
        needMove = true;
      } else if (ctrl == 0x81 || ctrl == 0x82 || ctrl == 0x84) {
        // قفزة (Jump)
        jumpCount++;
        needMove = true;
      } else if (ctrl == 0x87 || ctrl == 0x90 || ctrl == 0x91) {
        // أمر ترتر (Sequin Eject / Mode)
        final double px = x.toDouble();
        final double py = -y.toDouble();
        if (ctrl == 0x87 || ctrl == 0x91) {
          seqX.add(px);
          seqY.add(py);
          seqCode.add(1);
          hasAnyDev = true;
          stX.add(px);
          stY.add(py);
          stMove.add(needMove ? 1 : 0);
          stColor.add(colorIdx);
          stDev.add(1);
          needMove = false;
          stitchCount++;
          hasStitchesInCurColor = true;
          if (!hasBounds) {
            minX = maxX = px;
            minY = maxY = py;
            hasBounds = true;
          } else {
            if (px < minX) minX = px;
            if (px > maxX) maxX = px;
            if (py < minY) minY = py;
            if (py > maxY) maxY = py;
          }
        }
      } else {
        final double px = x.toDouble();
        final double py = -y.toDouble();
        stX.add(px);
        stY.add(py);
        stMove.add(needMove ? 1 : 0);
        stColor.add(colorIdx);
        stDev.add(0);
        needMove = false;
        stitchCount++;
        hasStitchesInCurColor = true;
        if (!hasBounds) {
          minX = maxX = px;
          minY = maxY = py;
          hasBounds = true;
        } else {
          if (px < minX) minX = px;
          if (px > maxX) maxX = px;
          if (py < minY) minY = py;
          if (py > maxY) maxY = py;
        }
      }
    }

    if (stitchCount < 2) return null;
    return VectorDesignData(
      stX: stX.finish(),
      stY: stY.finish(),
      stMove: stMove.finish(),
      stColor: stColor.finish(),
      stDev: hasAnyDev ? stDev.finish() : null,
      seqX: seqX.finish(),
      seqY: seqY.finish(),
      seqCode: seqCode.finish(),
      beadX: Float32List(0),
      beadY: Float32List(0),
      beadCode: Uint8List(0),
      paletteArgb: _palette,
      stitches: stitchCount,
      colorCount: colorCount,
      stopsCount: colorCount > 1 ? colorCount - 1 : 0,
      jumpsCount: jumpCount,
      sequinsCount: seqX.length,
      beadsCount: 0,
      trimsCount: trimsCount,
      minX: hasBounds ? minX : 0.0,
      maxX: hasBounds ? maxX : 0.0,
      minY: hasBounds ? minY : 0.0,
      maxY: hasBounds ? maxY : 0.0,
      hasBounds: hasBounds,
      machineType: 'Tajima (TBF)',
    );
  }

  static Future<VectorDesignData?> loadVector(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return await Isolate.run(() => decodeSync(bytes));
    } catch (_) {
      return null;
    }
  }

  static Future<EmbDesignInfo?> parseFile(String filePath, {double maxCanvas = 640.0}) async {
    final vec = await loadVector(filePath);
    if (vec == null || vec.stX.length < 2) return null;
    final previewPng = await TarikPro3DRenderer.renderVectorToPng(
      vec,
      maxCanvas: maxCanvas,
      is3D: false,
      transparentBg: false,
    );
    return EmbDesignInfo(
      filePath: filePath,
      fileName: filePath.split(Platform.pathSeparator).last,
      previewJpeg: previewPng,
      stitches: vec.stitches,
      colorCount: vec.colorCount,
      stopsCount: vec.stopsCount,
      jumpsCount: vec.jumpsCount,
      sequinsCount: vec.sequinsCount,
      beadsCount: vec.beadsCount,
      trimsCount: vec.trimsCount,
      machineType: vec.machineType,
      colorSequence: [],
      widthMm: vec.widthMm,
      heightMm: vec.heightMm,
    );
  }
}

/// تقرير فحص الفيلم (طبيب الفيلم — Film Doctor)
class FilmHealthReport {
  final int totalStitches;
  final int shortStitchesCount; // < 0.35 مم
  final int longStitchesCount; // > 8.0 مم
  final int longJumpsCount; // > 12.1 مم
  final int duplicateColorStopsCount;

  const FilmHealthReport({
    required this.totalStitches,
    required this.shortStitchesCount,
    required this.longStitchesCount,
    required this.longJumpsCount,
    required this.duplicateColorStopsCount,
  });

  bool get isHealthy =>
      shortStitchesCount == 0 && longStitchesCount == 0 && duplicateColorStopsCount == 0;
}

/// طبيب الفيلم الصناعي: يفحص ويعالج عيوب الغرز القصيرة والطويلة والوقفات المكررة مع حماية الزوايا والخرز والترتر
class TarikProFilmDoctor {
  static FilmHealthReport inspect(
    VectorDesignData data, {
    double shortThresholdMm = EmbMachineSpecs.defaultShortStitchMm,
    double longThresholdMm = 8.0,
  }) {
    final int n = data.stX.length;
    final double shortU = shortThresholdMm * 10.0;
    final double longU = longThresholdMm * 10.0;
    int shortC = 0, longC = 0, longJumps = 0, dupStops = 0;

    for (int i = 1; i < n; i++) {
      final double dx = data.stX[i] - data.stX[i - 1];
      final double dy = data.stY[i] - data.stY[i - 1];
      final double len = math.sqrt(dx * dx + dy * dy);
      final bool isJump = data.stMove[i] != 0;
      if (isJump) {
        if (len > 121.0) longJumps++;
        continue;
      }
      if (data.stColor[i] != data.stColor[i - 1]) {
        final int pLen = math.max(1, data.paletteArgb.length);
        if (data.paletteArgb[data.stColor[i] % pLen] == data.paletteArgb[data.stColor[i - 1] % pLen]) {
          dupStops++;
        }
        continue;
      }
      if (len < shortU && len > 0.01) {
        shortC++;
      } else if (len > longU && len < 600.0) {
        longC++;
      }
    }

    return FilmHealthReport(
      totalStitches: n,
      shortStitchesCount: shortC,
      longStitchesCount: longC,
      longJumpsCount: longJumps,
      duplicateColorStopsCount: dupStops,
    );
  }

  /// تنظيف ذكي للفيلم: حذف الغرز القصيرة (<0.35 مم) مع حماية الزوايا والخرز والترتر + تقسيم الغرز الطويلة (>8 مم)
  static EmbStudioDocument cleanDocument(
    EmbStudioDocument doc, {
    bool filterShort = true,
    double shortThresholdMm = EmbMachineSpecs.defaultShortStitchMm,
    bool splitLong = true,
    double maxStitchMm = 8.0,
    bool mergeDuplicateColors = true,
  }) {
    final out = doc.clone();
    List<EmbEditableStitch> list = out.stitches;
    if (list.length < 3) return out;

    // 1) دمج الوقفات المكررة بنفس اللون الفعلي
    if (mergeDuplicateColors && out.paletteArgb.isNotEmpty) {
      final int pLen = out.paletteArgb.length;
      for (int i = 1; i < list.length; i++) {
        if (list[i].colorIndex != list[i - 1].colorIndex) {
          final int argbCur = out.paletteArgb[list[i].colorIndex % pLen];
          final int argbPrev = out.paletteArgb[list[i - 1].colorIndex % pLen];
          if (argbCur == argbPrev) {
            list[i].colorIndex = list[i - 1].colorIndex;
          }
        }
      }
    }

    // 2) فلترة الغرز القصيرة (<0.35 مم) مع حماية الزوايا الحادة وغرز القفل والخرز والترتر
    if (filterShort) {
      final double minU = shortThresholdMm.clamp(0.20, 1.20) * 10.0;
      final List<EmbEditableStitch> filtered = [list.first];
      for (int i = 1; i < list.length; i++) {
        final cur = list[i];
        final prev = filtered.last;
        final bool isProtected = cur.moveFlag != 0 ||
            cur.colorIndex != prev.colorIndex ||
            cur.devCode != 0 ||
            cur.isLockStitch ||
            i == list.length - 1;
        if (isProtected) {
          filtered.add(cur);
          continue;
        }
        final double dx = cur.x - prev.x;
        final double dy = cur.y - prev.y;
        final double d = math.sqrt(dx * dx + dy * dy);
        if (d >= minU) {
          filtered.add(cur);
        } else if (i + 1 < list.length) {
          // حماية الزاوية الحادة (إذا تغير اتجاه الغرزة > 55 درجة نحتفظ بها)
          final nxt = list[i + 1];
          final double dx2 = nxt.x - cur.x;
          final double dy2 = nxt.y - cur.y;
          final double d2 = math.sqrt(dx2 * dx2 + dy2 * dy2);
          if (d > 0.1 && d2 > 0.1) {
            final double cosA = (dx * dx2 + dy * dy2) / (d * d2);
            if (cosA < 0.55) {
              filtered.add(cur);
            }
          }
        }
      }
      list = filtered;
    }

    // 3) تقسيم الغرز الطويلة (>8 مم) بتدرّج تاتامي ناعم
    if (splitLong) {
      final double maxU = maxStitchMm.clamp(4.5, 11.5) * 10.0;
      final List<EmbEditableStitch> splitted = [];
      int rowIdx = 0;
      const offsets = [0.0, 0.16, -0.14, 0.08];
      for (int i = 0; i < list.length; i++) {
        final cur = list[i];
        if (i > 0 && cur.moveFlag == 0 && cur.colorIndex == list[i - 1].colorIndex) {
          final prev = list[i - 1];
          final double dx = cur.x - prev.x;
          final double dy = cur.y - prev.y;
          final double len = math.sqrt(dx * dx + dy * dy);
          if (len > maxU && len < 600.0) {
            final int parts = (len / (maxU * 0.56)).ceil().clamp(2, 10);
            final double stag = offsets[rowIdx & 3];
            for (int k = 1; k < parts; k++) {
              final double t = ((k / parts) + (stag / parts)).clamp(0.12, 0.88);
              splitted.add(EmbEditableStitch(
                x: prev.x + dx * t,
                y: prev.y + dy * t,
                moveFlag: 0,
                colorIndex: cur.colorIndex,
              ));
            }
            rowIdx++;
          }
        }
        splitted.add(cur);
      }
      list = splitted;
    }

    out.stitches = list;
    return out;
  }
}
