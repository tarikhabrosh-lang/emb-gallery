import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

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
    glyphCount: 132,
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
    glyphCount: 132,
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
    glyphCount: 132,
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
        row5HasFinalYehHamza: false,
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
        row5HasFinalYehHamza: false,
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

    // في السطر العربي: عكس المقاطع اللاتينية والأرقام (بما فيها ٠-٩) لتُقرأ من اليسار لليمين
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

/// محرك الكتابة المطوّر (جيل Pro):
/// - تقويس دائري حقيقي (Wilcom Arc / Circle / Wave) تدور معه الحروف بانسيابية دون تشويه
/// - تعريض وتضييق فستون حقيقي (Satin Width / Pull Comp) يعمل بدقة على خطوط ويلكم (.DST) و Ink/Stitch
/// - تقسيم تلقائي للغرز الطويلة > 8 مم مع تدرّج حريري (Auto-Split)
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
      final raw = _generateSync(
        rawJson: rawJson,
        text: trimmed,
        letterHeightCm: letterHeightCm,
        densityMm: densityMm,
        extraSpacingMm: extraSpacingMm,
        satinWidthOffsetMm: satinWidthOffsetMm,
        autoSplit8Mm: autoSplit8Mm,
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
              ? (targetWidthCm / curW).clamp(0.25, 4.0)
              : (targetHeightCm! / curH).clamp(0.25, 4.0);
          sy = targetHeightCm != null
              ? (targetHeightCm / curH).clamp(0.25, 4.0)
              : sx;
        }
      }

      final bool isWilcomNative = raw.machineType.contains('Wilcom');
      final double dFactor = isWilcomNative
          ? (0.45 / densityMm.clamp(0.25, 1.0)).clamp(0.5, 2.0)
          : 1.0;
      final bool hasRot = rotationDeg.abs() > 0.05;

      if ((sx - 1.0).abs() > 0.015 ||
          (sy - 1.0).abs() > 0.015 ||
          (dFactor - 1.0).abs() > 0.04 ||
          hasRot) {
        return VectorDesignEditor.transform(
          raw,
          scaleX: sx,
          scaleY: sy,
          rotationDeg: rotationDeg,
          densityFactor: dFactor,
        );
      }
      return raw;
    });
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
    final double targetCapUnits = (letterHeightCm * 100.0).clamp(40.0, 1200.0);
    final double scale = targetCapUnits / capH;

    final double spaceW = ((font['spaceW'] as num?)?.toDouble() ?? (capH * 0.60)) * scale;
    final double baseLetterSp = ((font['letterSp'] as num?)?.toDouble() ?? (capH * 0.09)) * scale;
    final double extraSpUnits = extraSpacingMm * 10.0;
    final double lineH = ((font['lineH'] as num?)?.toDouble() ?? (capH * 1.45)) * scale;
    final double densityUnits = (densityMm * 10.0).clamp(2.5, 10.0);
    final double rawJoinOv = (font['joinOverlap'] as num?)?.toDouble() ?? (capH * 0.03);
    final double arabicJoinOverlap = (rawJoinOv * scale).clamp(0.0, 22.0);
    final double satinOffsetUnits = satinWidthOffsetMm.clamp(-0.6, 1.2) * 5.0; // لكل طرف

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
        // تقويس دائري حقيقي مثل ويلكم: الحروف تدور مع نصف القطر بدون ميلان أو قص
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
        final double radius = (minR * (1.35 - pathParam.clamp(-0.6, 0.85) * 0.55)).clamp(180.0, 2200.0);
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
          // تعريض أو تضييق الفستون الفعلي للطرفين مع حماية من انعكاس الحواف
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

        if (newWidth > splitThreshold) {
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

    // تعريض/تضييق حقيقي لأعمدة الفستون في خطوط .DST:
    // كل قمة في زكزاك الفستون تنعكس فيها الزاوية (cosT < -0.22)، فنمدّ القمة للخارج على منصف الزاوية بدقة
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
        if (l1 < 5.0 || l2 < 5.0) continue;

        final double u1x = v1x / l1, u1y = v1y / l1;
        final double u2x = v2x / l2, u2y = v2y / l2;
        final double cosT = u1x * u2x + u1y * u2y;

        if (cosT < -0.22) {
          // متجه الخروج الحقيقي من قلب عمود الفستون نحو الحافة
          double bx = u1x - u2x;
          double by = u1y - u2y;
          final double bLen = math.sqrt(bx * bx + by * by);
          if (bLen > 1e-4) {
            bx /= bLen;
            by /= bLen;
            final double minW = math.min(l1, l2);
            final double safeShift = satinOffsetUnits.clamp(-(minW * 0.32), 12.0);
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
        if (segLen > 80.0) {
          final int parts = (segLen / 42.0).ceil().clamp(2, 12);
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

    // 1) استخراج المقاطع المتصلة على القفزات الفعلية وتغيّر اللون فقط (لا يقطّع غرز الفستون العريضة!)
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

      // نفصل فقط عند قفزة فعلية أو تغيير لون أو نقلة طويلة جداً (> 11.5 مم)
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

    // 2) دمج المقاطع المتتالية من نفس اللون والمتقاربة مكانياً (<= 3.2 مم) كعنصر واحد متماسك
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

  /// بناء التصميم المعدّل مع الحفاظ الكامل على الخرز والترتر (stDev + seq + bead) وتطبيق الألوان والمقص
  static VectorDesignData apply(
    VectorDesignData src,
    List<ProDesignObject> objects,
    List<ProObjectTransform> transforms, {
    List<int>? customPaletteArgb,
  }) {
    final bool hasSrcDev = src.stDev != null && src.stDev!.length == src.stX.length;
    final stX = _ProFloat32Buf(math.max(256, src.stX.length));
    final stY = _ProFloat32Buf(math.max(256, src.stY.length));
    final stMove = _ProUint8Buf(math.max(256, src.stX.length));
    final stColor = _ProUint8Buf(math.max(256, src.stX.length));
    final stDev = hasSrcDev ? _ProUint8Buf(math.max(256, src.stX.length)) : null;

    final seqX = _ProFloat32Buf(math.max(32, src.seqX.length));
    final seqY = _ProFloat32Buf(math.max(32, src.seqY.length));
    final seqCode = _ProUint8Buf(math.max(32, src.seqCode.length));

    final beadX = _ProFloat32Buf(math.max(32, src.beadX.length));
    final beadY = _ProFloat32Buf(math.max(32, src.beadY.length));
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

          final int mv = (firstOfObj || prevRequestedTrim || i == s) ? 1 : src.stMove[i];
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

    // احتياطي للملفات التي تحتوي على ترتر/خرز بدون stDev: تحويل إحداثياتها مع نفس العنصر المحتوي لها
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
