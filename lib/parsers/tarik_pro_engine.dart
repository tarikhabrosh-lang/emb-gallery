import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'emb_parser.dart';
import 'wilcom_dst_font_loader.dart';

/// خزنة تشفير الخطوط الخاصة بـ Tarik EMB (ChaCha20 RFC 8439 + HMAC-SHA256):
/// - تفك تشفير ملفات الخطوط المحمية (.tfnt) داخل الذاكرة العشوائية (RAM) فقط بدون حفظ أي ملف .DST مكشوف على الجهاز
/// - ترفض أي ملف تم العبث به أو تعديل بايت واحد فيه عبر التحقق من توقيع HMAC-SHA256
class TarikFontVault {
  static const List<int> _seedA = [
    0x7A, 0x3C, 0x91, 0xE4, 0x52, 0xB8, 0x0F, 0x6D,
    0xC3, 0x19, 0x84, 0x4E, 0xA7, 0x25, 0xF1, 0x68,
    0x3B, 0xD2, 0x59, 0x80, 0x14, 0xCE, 0x77, 0xA2,
    0x46, 0x9B, 0x0D, 0xF5, 0x2E, 0x83, 0x61, 0xB9,
  ];

  static const List<int> _seedB = [
    0x2E, 0x5A, 0xC4, 0x17, 0x89, 0x3D, 0xF2, 0x41,
    0x6B, 0x90, 0x2F, 0xD5, 0x1C, 0x7E, 0x4A, 0xB3,
    0x85, 0x11, 0xE6, 0x39, 0xC0, 0x54, 0x28, 0x7F,
    0xA1, 0x4C, 0x96, 0x23, 0xDE, 0x67, 0x18, 0x50,
  ];

  static const List<int> _sha256K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  static Uint8List _deriveMasterKey() {
    final out = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      out[i] = (_seedA[i] ^ _seedB[(i * 7 + 3) & 31] ^ ((i * 29 + 0x5B) & 0xFF)) & 0xFF;
    }
    return out;
  }

  static int _rotl32(int v, int c) => ((v << c) & 0xFFFFFFFF) | ((v & 0xFFFFFFFF) >>> (32 - c));
  static int _rotr32(int v, int c) => ((v & 0xFFFFFFFF) >>> c) | ((v << (32 - c)) & 0xFFFFFFFF);

  static int _readU32LE(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static void _qr(Uint32List s, int a, int b, int c, int d) {
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF;
    s[d] = _rotl32(s[d] ^ s[a], 16);
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF;
    s[b] = _rotl32(s[b] ^ s[c], 12);
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF;
    s[d] = _rotl32(s[d] ^ s[a], 8);
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF;
    s[b] = _rotl32(s[b] ^ s[c], 7);
  }

  static Uint8List _chacha20Block(Uint8List key, int counter, Uint8List nonce) {
    final state = Uint32List(16);
    state[0] = 0x61707865;
    state[1] = 0x3320646e;
    state[2] = 0x79622d32;
    state[3] = 0x6b206574;
    for (int i = 0; i < 8; i++) {
      state[4 + i] = _readU32LE(key, i * 4);
    }
    state[12] = counter & 0xFFFFFFFF;
    state[13] = _readU32LE(nonce, 0);
    state[14] = _readU32LE(nonce, 4);
    state[15] = _readU32LE(nonce, 8);

    final w = Uint32List.fromList(state);
    for (int r = 0; r < 10; r++) {
      _qr(w, 0, 4, 8, 12);
      _qr(w, 1, 5, 9, 13);
      _qr(w, 2, 6, 10, 14);
      _qr(w, 3, 7, 11, 15);
      _qr(w, 0, 5, 10, 15);
      _qr(w, 1, 6, 11, 12);
      _qr(w, 2, 7, 8, 13);
      _qr(w, 3, 4, 9, 14);
    }

    final out = Uint8List(64);
    for (int i = 0; i < 16; i++) {
      final int v = (w[i] + state[i]) & 0xFFFFFFFF;
      out[i * 4] = v & 0xFF;
      out[i * 4 + 1] = (v >>> 8) & 0xFF;
      out[i * 4 + 2] = (v >>> 16) & 0xFF;
      out[i * 4 + 3] = (v >>> 24) & 0xFF;
    }
    return out;
  }

  static Uint8List _chacha20Xor(Uint8List key, int startCounter, Uint8List nonce, Uint8List input) {
    final out = Uint8List(input.length);
    int pos = 0;
    int ctr = startCounter;
    while (pos < input.length) {
      final ks = _chacha20Block(key, ctr, nonce);
      ctr = (ctr + 1) & 0xFFFFFFFF;
      final int chunk = math.min(64, input.length - pos);
      for (int i = 0; i < chunk; i++) {
        out[pos + i] = input[pos + i] ^ ks[i];
      }
      pos += chunk;
    }
    return out;
  }

  static Uint8List _sha256(Uint8List data) {
    int h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    int h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;

    final int origLen = data.length;
    final int rem = (origLen + 1) % 64;
    final int padZeros = rem <= 56 ? (56 - rem) : (120 - rem);
    final int totalLen = origLen + 1 + padZeros + 8;
    final padded = Uint8List(totalLen);
    padded.setRange(0, origLen, data);
    padded[origLen] = 0x80;

    final int bitLen = origLen * 8;
    final int hiBits = bitLen >>> 32;
    final int loBits = bitLen & 0xFFFFFFFF;
    final int lenOff = totalLen - 8;
    padded[lenOff] = (hiBits >>> 24) & 0xFF;
    padded[lenOff + 1] = (hiBits >>> 16) & 0xFF;
    padded[lenOff + 2] = (hiBits >>> 8) & 0xFF;
    padded[lenOff + 3] = hiBits & 0xFF;
    padded[lenOff + 4] = (loBits >>> 24) & 0xFF;
    padded[lenOff + 5] = (loBits >>> 16) & 0xFF;
    padded[lenOff + 6] = (loBits >>> 8) & 0xFF;
    padded[lenOff + 7] = loBits & 0xFF;

    final w = Uint32List(64);
    for (int off = 0; off < totalLen; off += 64) {
      for (int i = 0; i < 16; i++) {
        final int j = off + i * 4;
        w[i] = (padded[j] << 24) | (padded[j + 1] << 16) | (padded[j + 2] << 8) | padded[j + 3];
      }
      for (int i = 16; i < 64; i++) {
        final int s0 = _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        final int s1 = _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
      }

      int a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (int i = 0; i < 64; i++) {
        final int s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
        final int ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
        final int t1 = (h + s1 + ch + _sha256K[i] + w[i]) & 0xFFFFFFFF;
        final int s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
        final int maj = (a & b) ^ (a & c) ^ (b & c);
        final int t2 = (s0 + maj) & 0xFFFFFFFF;
        h = g;
        g = f;
        f = e;
        e = (d + t1) & 0xFFFFFFFF;
        d = c;
        c = b;
        b = a;
        a = (t1 + t2) & 0xFFFFFFFF;
      }

      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
      h4 = (h4 + e) & 0xFFFFFFFF;
      h5 = (h5 + f) & 0xFFFFFFFF;
      h6 = (h6 + g) & 0xFFFFFFFF;
      h7 = (h7 + h) & 0xFFFFFFFF;
    }

    final out = Uint8List(32);
    final hs = [h0, h1, h2, h3, h4, h5, h6, h7];
    for (int i = 0; i < 8; i++) {
      final int v = hs[i];
      out[i * 4] = (v >>> 24) & 0xFF;
      out[i * 4 + 1] = (v >>> 16) & 0xFF;
      out[i * 4 + 2] = (v >>> 8) & 0xFF;
      out[i * 4 + 3] = v & 0xFF;
    }
    return out;
  }

  static Uint8List _hmacSha256(Uint8List key, Uint8List msg) {
    final k = Uint8List(64);
    if (key.length > 64) {
      final hk = _sha256(key);
      k.setRange(0, 32, hk);
    } else {
      k.setRange(0, key.length, key);
    }

    final inner = Uint8List(64 + msg.length);
    for (int i = 0; i < 64; i++) {
      inner[i] = k[i] ^ 0x36;
    }
    inner.setRange(64, inner.length, msg);
    final innerHash = _sha256(inner);

    final outer = Uint8List(96);
    for (int i = 0; i < 64; i++) {
      outer[i] = k[i] ^ 0x5c;
    }
    outer.setRange(64, 96, innerHash);
    return _sha256(outer);
  }

  static bool isEncryptedTfnt(Uint8List bytes) {
    return bytes.length >= 53 &&
        bytes[0] == 0x54 && // T
        bytes[1] == 0x46 && // F
        bytes[2] == 0x4E && // N
        bytes[3] == 0x54 && // T
        bytes[4] == 0x01;
  }

  /// فك تشفير ملف .tfnt داخل الذاكرة والتحقق من توقيعه (يرجع null عند أي تلاعب)
  static Uint8List? decrypt(Uint8List blob) {
    if (!isEncryptedTfnt(blob)) return null;
    final key = _deriveMasterKey();
    final header = Uint8List.sublistView(blob, 0, 20);
    final nonce = Uint8List.sublistView(blob, 8, 20);
    final tag = Uint8List.sublistView(blob, 20, 52);
    final cipher = Uint8List.sublistView(blob, 52);

    final macKeyBlock = _chacha20Block(key, 0, nonce);
    final macKey = Uint8List.sublistView(macKeyBlock, 0, 32);

    final authInput = Uint8List(header.length + cipher.length);
    authInput.setRange(0, header.length, header);
    authInput.setRange(header.length, authInput.length, cipher);
    final expectedTag = _hmacSha256(macKey, authInput);

    int diff = 0;
    for (int i = 0; i < 32; i++) {
      diff |= (tag[i] ^ expectedTag[i]);
    }
    if (diff != 0) return null;

    return _chacha20Xor(key, 1, nonce, cipher);
  }
}

/// كتالوج الفونطات المحمي والخاص بمالك التطبيق فقط:
/// 1) يحافظ على فونط A2 (رسم أبو وسيم) وفونطات E1..E4 المدمجة في emb_parser.dart
/// 2) يكتشف تلقائياً فقط الخطوط المدمجة داخل مجلد assets/emb_fonts/ (المشفّرة .tfnt بأولوية أولى، ثم .dst)
/// 3) مغلق تماماً أمام المستخدمين — لا يمكن للعميل إضافة أو تعديل أو استخراج الخطوط من التطبيق
class TarikProFontCatalog {
  static List<EmbFontMeta>? _cachedIndex;
  static final Map<String, String> _rawFontCache = {};

  static Future<List<String>> _discoverBundledFontAssets() async {
    final Set<String> found = {};

    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      for (final assetPath in manifest.listAssets()) {
        final lower = assetPath.toLowerCase();
        if (lower.startsWith('assets/emb_fonts/') &&
            (lower.endsWith('.tfnt') || lower.endsWith('.dst'))) {
          found.add(assetPath);
        }
      }
    } catch (_) {
      try {
        final raw = await rootBundle.loadString('AssetManifest.json');
        final Map<String, dynamic> map = jsonDecode(raw) as Map<String, dynamic>;
        for (final key in map.keys) {
          final lower = key.toLowerCase();
          if (lower.startsWith('assets/emb_fonts/') &&
              (lower.endsWith('.tfnt') || lower.endsWith('.dst'))) {
            found.add(key);
          }
        }
      } catch (_) {}
    }

    if (found.isEmpty) {
      found.addAll(const [
        'assets/emb_fonts/A1.tfnt',
        'assets/emb_fonts/a3.tfnt',
        'assets/emb_fonts/a4.tfnt',
        'assets/emb_fonts/A1.DST',
        'assets/emb_fonts/a3.DST',
        'assets/emb_fonts/a4.DST',
      ]);
    }

    // الأولوية دائماً للملفات المشفّرة (.tfnt) قبل أي ملف .dst
    final list = found.toList()
      ..sort((a, b) {
        final aEnc = a.toLowerCase().endsWith('.tfnt') ? 0 : 1;
        final bEnc = b.toLowerCase().endsWith('.tfnt') ? 0 : 1;
        if (aEnc != bEnc) return aEnc.compareTo(bEnc);
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return list;
  }

  static String _stemOfPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final fileName = normalized.split('/').last;
    return fileName.replaceAll(RegExp(r'\.[^.]+$'), '').trim();
  }

  static String _safeIdHash(String input) {
    int h = 0x811c9dc5;
    for (int i = 0; i < input.length; i++) {
      h ^= input.codeUnitAt(i);
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  static Future<List<EmbFontMeta>> loadIndex() async {
    if (_cachedIndex != null) return _cachedIndex!;

    final List<EmbFontMeta> base = await InkStitchFontCatalog.loadIndex();
    final Map<int, EmbFontMeta> arSlots = {};
    final List<EmbFontMeta> enFonts = [];
    final Set<String> seenIds = {};
    final Set<String> seenStems = {};

    // 1) تثبيت A2 الأصلي المرسوم يدوياً من emb_parser.dart أولاً
    for (final f in base) {
      final code = f.nameEn.trim().toUpperCase();
      if (code == 'A2' || f.id == 'wilcom_a2') {
        arSlots[2] = f;
        seenIds.add(f.id);
        seenStems.add('a2');
      }
    }

    int nextFreeArSlot() {
      int s = 1;
      while (arSlots.containsKey(s)) {
        s++;
      }
      return s;
    }

    final RegExp arNumRe = RegExp(r'^A(\d+)$', caseSensitive: false);
    final bundledAssets = await _discoverBundledFontAssets();
    final List<String> unnamedAssets = [];

    // 2) الخطوط المرقّمة داخل assets/emb_fonts/ (A1.tfnt, a3.tfnt, a4.tfnt, A5.tfnt...)
    for (final assetPath in bundledAssets) {
      final stem = _stemOfPath(assetPath);
      final stemLow = stem.toLowerCase();
      if (seenStems.contains(stemLow)) continue;

      final m = arNumRe.firstMatch(stem);
      if (m != null) {
        final int slot = int.parse(m.group(1)!);
        if (slot == 2 && arSlots.containsKey(2)) continue;
        if (!arSlots.containsKey(slot)) {
          final String code = 'A$slot';
          final String id = 'wilcom_a$slot';
          final bool isEnc = assetPath.toLowerCase().endsWith('.tfnt');
          arSlots[slot] = EmbFontMeta(
            id: id,
            nameAr: code,
            nameEn: code,
            rtl: true,
            capH: 260.0,
            spaceW: 150.0,
            letterSp: 21.0,
            lineH: 385.0,
            minScale: 0.40,
            maxScale: 2.8,
            glyphCount: 133,
            file: '${isEnc ? 'tfnt_asset://' : 'dst_asset://'}$assetPath',
          );
          seenIds.add(id);
          seenStems.add(stemLow);
        }
      } else {
        unnamedAssets.add(assetPath);
      }
    }

    // 3) أي خطوط إضافية مسماة بأسماء حرة داخل assets/emb_fonts/ (محمية داخل الـ APK فقط)
    for (final assetPath in unnamedAssets) {
      final stem = _stemOfPath(assetPath);
      final stemLow = stem.toLowerCase();
      if (seenStems.contains(stemLow)) continue;
      final int slot = nextFreeArSlot();
      final String code = 'A$slot';
      final String id = 'wilcom_asset_${_safeIdHash(assetPath)}';
      final bool isEnc = assetPath.toLowerCase().endsWith('.tfnt');
      arSlots[slot] = EmbFontMeta(
        id: id,
        nameAr: stem.isNotEmpty ? stem : code,
        nameEn: code,
        rtl: true,
        capH: 260.0,
        spaceW: 150.0,
        letterSp: 21.0,
        lineH: 385.0,
        minScale: 0.40,
        maxScale: 2.8,
        glyphCount: 133,
        file: '${isEnc ? 'tfnt_asset://' : 'dst_asset://'}$assetPath',
      );
      seenIds.add(id);
      seenStems.add(stemLow);
    }

    // 4) بقية الخطوط المدمجة من emb_parser.dart (E1..E4)
    for (final f in base) {
      if (seenIds.contains(f.id)) continue;
      if (f.rtl) {
        final int slot = nextFreeArSlot();
        arSlots[slot] = f;
        seenIds.add(f.id);
      } else {
        enFonts.add(f);
        seenIds.add(f.id);
      }
    }

    final List<int> sortedArKeys = arSlots.keys.toList()..sort();
    _cachedIndex = [
      for (final k in sortedArKeys) arSlots[k]!,
      ...enFonts,
    ];
    return _cachedIndex!;
  }

  static Future<String?> loadRawFontJson(EmbFontMeta meta) async {
    final cached = _rawFontCache[meta.id];
    if (cached != null) return cached;

    String? raw;
    if (meta.file.startsWith('tfnt_asset://')) {
      final assetPath = meta.file.substring('tfnt_asset://'.length);
      final double overlap = meta.nameEn.toUpperCase() == 'A3' ? 0.036 : 0.048;
      try {
        final bd = await rootBundle.load(assetPath);
        final Uint8List encBytes = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
        raw = await Isolate.run(() {
          final Uint8List? plainDst = TarikFontVault.decrypt(encBytes);
          if (plainDst == null || plainDst.length <= 512) return null;
          return WilcomDstFontLoader.parseDstBytesToFontJson(
            bytes: plainDst,
            nameEn: meta.nameEn,
            row5HasFinalYehHamza: true,
            joinOverlapRatio: overlap,
          );
        });
      } catch (_) {}
    } else if (meta.file.startsWith('dst_asset://')) {
      final assetPath = meta.file.substring('dst_asset://'.length);
      final double overlap = meta.nameEn.toUpperCase() == 'A3' ? 0.036 : 0.048;
      final List<String> candidates = [assetPath];
      if (assetPath.endsWith('.DST')) {
        candidates.add('${assetPath.substring(0, assetPath.length - 4)}.dst');
      } else if (assetPath.endsWith('.dst')) {
        candidates.add('${assetPath.substring(0, assetPath.length - 4)}.DST');
      }
      raw = await WilcomDstFontLoader.loadFontJson(
        fontId: meta.id,
        nameEn: meta.nameEn,
        assetCandidates: candidates,
        row5HasFinalYehHamza: true,
        joinOverlapRatio: overlap,
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
    bool isTatami = false,
    double tatamiAngleDeg = 0.0,
    int tatamiPattern = 0, // 0=قياسي 1/3، 1=مائل 1/4، 2=متعرج، 3=منسوج 1/2
    double tatamiStitchLenMm = 4.0,
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
        autoSplit8Mm: false,
        isTatami: isTatami,
        tatamiAngleDeg: tatamiAngleDeg,
        tatamiPattern: tatamiPattern,
        tatamiStitchLenMm: tatamiStitchLenMm,
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
        if (curW > 0.05 && curH > 0.05) {
          sx = targetWidthCm != null
              ? (targetWidthCm / curW).clamp(0.04, 40.0)
              : (targetHeightCm! / curH).clamp(0.04, 40.0);
          sy = targetHeightCm != null
              ? (targetHeightCm / curH).clamp(0.04, 40.0)
              : sx;
        }
      }

      // إعادة التوليد بالمقاس الحقيقي المباشر (بدون سقف 20 سم) حتى تبقى الكثافة والتاتامي وتعريض الفستون بالمليمتر الدقيق!
      if ((sx - 1.0).abs() > 0.10 && targetHeightCm == null) {
        final double adjustedHeightCm = (letterHeightCm * sx).clamp(0.3, 120.0);
        final VectorDesignData? scaledRaw = _generateSync(
          rawJson: rawJson,
          text: trimmed,
          letterHeightCm: adjustedHeightCm,
          densityMm: densityMm,
          extraSpacingMm: extraSpacingMm,
          satinWidthOffsetMm: satinWidthOffsetMm,
          autoSplit8Mm: false,
          isTatami: isTatami,
          tatamiAngleDeg: tatamiAngleDeg,
          tatamiPattern: tatamiPattern,
          tatamiStitchLenMm: tatamiStitchLenMm,
          pathMode: pathMode,
          pathParam: pathParam,
          underlayMode: underlayMode,
          colorArgb: colorArgb,
        );
        if (scaledRaw != null) {
          raw = scaledRaw;
          final double curW2 = (raw.widthMm ?? 0.0) / 10.0;
          if (targetWidthCm != null && curW2 > 0.05) {
            sx = (targetWidthCm / curW2).clamp(0.2, 5.0);
            sy = sx;
          } else {
            sx = 1.0;
            sy = 1.0;
          }
        }
      }

      final bool isNativeStitch = !isTatami && raw.machineType.contains('(Pro)');
      final double dFactor = isNativeStitch
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
          densityFactor: 1.0,
        );
      }

      if (!isTatami && (dFactor - 1.0).abs() > 0.05) {
        out = _adjustSatinDensityClean(out, dFactor);
      }

      // تقسيم تلقائي احترافي للغرز العريضة (معيار 7.0 مم / أقل غرزة 1.6 مم)
      if (!isTatami && autoSplit8Mm) {
        out = _applyPostScaleAutoSplit(out, maxStitchMm: 7.0, minStitchMm: 1.6);
      }

      return out;
    });
  }

  /// تقسيم تلقائي احترافي بعد التكبير النهائي: أي غرزة فستون أطول من 8 مم تُقسّم بتدرّج حريري متناوب بدون فراغات أو تفتّت
  static VectorDesignData _applyPostScaleAutoSplit(
    VectorDesignData src, {
    double maxStitchMm = 7.0,
    double minStitchMm = 1.6,
  }) {
    final int n = src.stX.length;
    if (n < 2) return src;
    final double maxUnits = maxStitchMm.clamp(4.0, 11.0) * 10.0;
    final double minUnits = minStitchMm.clamp(1.0, 3.0) * 10.0;

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

        // تقسيم الغرز العريضة (> 7.0 مم) مع ضمان أن كل قطعة >= 1.6 مم بتدرج ناعم وواضح
        if (len > maxUnits && len < 800.0) {
          final int parts = (len / (maxUnits * 0.65)).ceil().clamp(2, 16);
          const offsets = [0.0, 0.26, -0.22, 0.14];
          final double stagger = offsets[rowCounter & 3];
          final double minFrac = (minUnits / len).clamp(0.10, 0.38);
          double lastT = 0.0;
          for (int k = 1; k < parts; k++) {
            final double rawT = (k / parts) + (stagger / parts);
            final double t = rawT.clamp(math.max(minFrac, lastT + minFrac), 1.0 - minFrac);
            if (t > lastT + 0.04 && (1.0 - t) * len >= minUnits * 0.85) {
              stX.add(prevX + dx * t);
              stY.add(prevY + dy * t);
              stMove.add(0);
              stColor.add(col);
              lastT = t;
            }
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
    bool isTatami = false,
    double tatamiAngleDeg = 0.0,
    int tatamiPattern = 0,
    double tatamiStitchLenMm = 4.0,
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
    final double targetCapUnits = (letterHeightCm * 100.0).clamp(20.0, 30000.0);
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
      if (isMove && hasNeedle && !isTatami) {
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

      // تجميع الكلمة كاملةً ككتلة واحدة موحّدة في وضع التاتامي (يدمج الحروف المتصلة ويلغي الوصلات والتكسّرات تماماً!)
      final List<List<double>> wordPolysX = [];
      final List<List<double>> wordPolysY = [];
      final List<(Map<String, dynamic>, double, double)> wordRunFallback = [];

      void flushTatamiWord() {
        if (wordPolysX.isNotEmpty) {
          _emitUnifiedTatamiPolygons(
            polysX: wordPolysX,
            polysY: wordPolysY,
            densityUnits: densityUnits,
            angleDeg: tatamiAngleDeg,
            pattern: tatamiPattern,
            stitchLenUnits: (tatamiStitchLenMm * 10.0).clamp(20.0, 75.0),
            addPt: addPt,
          );
          wordPolysX.clear();
          wordPolysY.clear();
        }
        if (wordRunFallback.isNotEmpty) {
          for (final rf in wordRunFallback) {
            _emitRunningPath(el: rf.$1, ox: rf.$2, oy: rf.$3, scale: scale, addPt: addPt);
          }
          wordRunFallback.clear();
        }
      }

      for (int pIdx = 0; pIdx < placed.length; pIdx++) {
        final item = placed[pIdx];
        final g = item.$1;
        final adv = item.$3;
        if (g == null) {
          if (isTatami) flushTatamiWord();
          cursorX += isRtl ? -adv : adv;
          continue;
        }
        final double gw = ((g['w'] as num?)?.toDouble() ?? 50.0) * scale;
        final double ox = isRtl ? (cursorX - gw) : cursorX;
        final double oy = baselineY;

        final List<dynamic> elements = (g['e'] as List<dynamic>?) ?? const [];
        if (isTatami) {
          int addedPolys = 0;
          for (int eIdx = 0; eIdx < elements.length; eIdx++) {
            final el = elements[eIdx] as Map<String, dynamic>;
            final String type = (el['t'] ?? '').toString();
            final int before = wordPolysX.length;
            if (type == 's') {
              _collectSatinColumnPolys(el: el, ox: ox, oy: oy, scale: scale, outX: wordPolysX, outY: wordPolysY);
            } else if (type == 'f') {
              _collectFillPoly(el: el, ox: ox, oy: oy, scale: scale, outX: wordPolysX, outY: wordPolysY);
            } else if (type == 'd') {
              _collectDigitizedRunPolys(el: el, ox: ox, oy: oy, scale: scale, outX: wordPolysX, outY: wordPolysY);
            }
            addedPolys += (wordPolysX.length - before);
          }
          if (addedPolys == 0) {
            for (final el in elements) {
              if ((el as Map<String, dynamic>)['t'] == 'r') {
                wordRunFallback.add((el, ox, oy));
              }
            }
          }
        } else {
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
                angleDeg: 0.0,
                pattern: 0,
                stitchLenUnits: (tatamiStitchLenMm * 10.0).clamp(20.0, 75.0),
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
        }

        cursorX += isRtl ? -adv : adv;
      }
      if (isTatami) flushTatamiWord();
    }

    if (stX.length < 2) return null;

    final bool isNativeStitch = font['nativeStitch'] == true;
    final String fontName = (font['nameEn'] ?? 'Pro Satin').toString();
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
      machineType: isTatami
          ? '$fontName (Tatami)'
          : (isNativeStitch ? '$fontName (Pro)' : '$fontName (Satin)'),
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

  static double _tatamiPhase(int rowIdx, int pattern) {
    switch (pattern) {
      case 1: // مائل (Diagonal Twill 1/4)
        const p1 = [0.0, 0.25, 0.50, 0.75];
        return p1[rowIdx % p1.length];
      case 2: // متعرج (Herringbone / Chevron)
        const p2 = [0.0, 0.20, 0.40, 0.60, 0.40, 0.20];
        return p2[rowIdx % p2.length];
      case 3: // منسوج (Basket Weave 1/2)
        return (rowIdx & 1) == 0 ? 0.0 : 0.50;
      default: // قياسي (Standard Brick 1/3)
        const p0 = [0.0, 0.33, 0.66];
        return p0[rowIdx % p0.length];
    }
  }

  /// محرك تعبئة التاتامي الاحترافي (Closest Point Join + الدخول بدرزة مخفية والعودة بتاتامي + حماية الزوايا):
  /// - يجمع مضلعات الكلمة كاملةً ككتلة واحدة، ثم يرتّب المناطق وفق أقرب نقطة انتقال من آخر موضع للإبرة
  /// - يدخل بدرزة تمشي مخفية داخل الجسم (Underpath) ويعود بتعبئة التاتامي لتغطية الدرزة تماماً والخروج من أقرب نقطة للجزء التالي
  /// - يحافظ على نظافة فتحات الحروف والنقاط بدون أي خطوط وصل عابرة
  static void _emitUnifiedTatamiPolygons({
    required List<List<double>> polysX,
    required List<List<double>> polysY,
    required double densityUnits,
    required double angleDeg,
    required int pattern,
    required double stitchLenUnits,
    required void Function(double, double, bool) addPt,
  }) {
    if (polysX.isEmpty) return;

    final double rad = angleDeg * math.pi / 180.0;
    final double ca = math.cos(rad);
    final double sa = math.sin(rad);

    final List<List<double>> rotX = [];
    final List<List<double>> rotY = [];
    final List<double> polyMinY = [];
    final List<double> polyMaxY = [];
    double minY = double.infinity, maxY = -double.infinity;

    for (int p = 0; p < polysX.length; p++) {
      final xs = polysX[p];
      final ys = polysY[p];
      final int n = xs.length;
      if (n < 3) continue;
      final rx = List<double>.filled(n, 0.0);
      final ry = List<double>.filled(n, 0.0);
      double pMin = double.infinity, pMax = -double.infinity;
      for (int i = 0; i < n; i++) {
        final double vx = xs[i] * ca + ys[i] * sa;
        final double vy = -xs[i] * sa + ys[i] * ca;
        rx[i] = vx;
        ry[i] = vy;
        if (vy < pMin) pMin = vy;
        if (vy > pMax) pMax = vy;
      }
      if (pMax - pMin < 0.4) continue;
      if (pMin < minY) minY = pMin;
      if (pMax > maxY) maxY = pMax;
      rotX.add(rx);
      rotY.add(ry);
      polyMinY.add(pMin);
      polyMaxY.add(pMax);
    }

    if (rotX.isEmpty || maxY - minY < 1.5) return;

    final double stepY = densityUnits.clamp(2.5, 12.0);
    final double stLen = stitchLenUnits.clamp(18.0, 75.0);

    // 1) بناء شرائح المسح الموحّدة للكلمة مع دمج دقيق (0.18 مم) يغلق التقاء الأعمدة دون سد الفتحات
    final List<(double, List<(double, double)>)> rawRows = [];
    for (double y = minY + stepY * 0.5; y <= maxY; y += stepY) {
      final List<(double, double)> rawSpans = [];
      for (int p = 0; p < rotX.length; p++) {
        if (y < polyMinY[p] || y > polyMaxY[p]) continue;
        final rx = rotX[p];
        final ry = rotY[p];
        final int n = rx.length;
        final List<double> hits = [];
        for (int i = 0; i < n; i++) {
          final int j = (i + 1) % n;
          final double y0 = ry[i], y1 = ry[j];
          if ((y0 <= y && y1 > y) || (y1 <= y && y0 > y)) {
            hits.add(rx[i] + (y - y0) * (rx[j] - rx[i]) / (y1 - y0));
          }
        }
        if (hits.length < 2) continue;
        hits.sort();
        for (int h = 0; h + 1 < hits.length; h += 2) {
          if (hits[h + 1] - hits[h] >= 0.9) {
            rawSpans.add((hits[h], hits[h + 1]));
          }
        }
      }
      if (rawSpans.isEmpty) continue;
      rawSpans.sort((a, b) => a.$1.compareTo(b.$1));

      final List<(double, double)> merged = [rawSpans.first];
      for (int k = 1; k < rawSpans.length; k++) {
        final cur = rawSpans[k];
        final last = merged.last;
        if (cur.$1 <= last.$2 + 1.8) {
          merged[merged.length - 1] = (last.$1, math.max(last.$2, cur.$2));
        } else {
          merged.add(cur);
        }
      }
      rawRows.add((y, merged));
    }

    if (rawRows.isEmpty) return;

    // 2) تنعيم حواف لطيف يحافظ على الزوايا الحادة (لا ينعّم إذا كان هناك تغيّر زاوية مفاجئ > 6 وحدات)
    final List<(double, List<(double, double)>)> rows = List.generate(rawRows.length, (r) {
      final double y = rawRows[r].$1;
      final spans = rawRows[r].$2;
      final List<(double, double)> smoothSpans = [];
      for (final sp in spans) {
        double lAcc = sp.$1 * 3.0;
        double rAcc = sp.$2 * 3.0;
        double wSum = 3.0;
        for (final nr in [r - 1, r + 1]) {
          if (nr < 0 || nr >= rawRows.length) continue;
          if ((rawRows[nr].$1 - y).abs() > stepY * 1.35) continue;
          for (final nsp in rawRows[nr].$2) {
            final double ov = math.min(sp.$2, nsp.$2) - math.max(sp.$1, nsp.$1);
            if (ov > 0 && (nsp.$1 - sp.$1).abs() < 6.0 && (nsp.$2 - sp.$2).abs() < 6.0) {
              lAcc += nsp.$1;
              rAcc += nsp.$2;
              wSum += 1.0;
              break;
            }
          }
        }
        final double sl = lAcc / wSum;
        final double sr = rAcc / wSum;
        if (sr - sl >= 1.2) {
          smoothSpans.add((sl, sr));
        }
      }
      return (y, smoothSpans.isNotEmpty ? smoothSpans : spans);
    });

    // 3) استخلاص كل المناطق المتصلة عمودياً (Connected Regions)
    final List<List<bool>> visited = List.generate(
      rows.length,
      (r) => List.filled(rows[r].$2.length, false),
    );
    final List<List<(int, double, double, double)>> regions = [];

    for (int startR = 0; startR < rows.length; startR++) {
      for (int startS = 0; startS < rows[startR].$2.length; startS++) {
        if (visited[startR][startS]) continue;
        final List<(int, double, double, double)> reg = [];
        int r = startR;
        int s = startS;
        while (true) {
          visited[r][s] = true;
          final double y = rows[r].$1;
          final sp = rows[r].$2[s];
          reg.add((r, y, sp.$1, sp.$2));
          if (r + 1 >= rows.length) break;
          int nextS = -1;
          double bestOv = 0.0;
          final nextSpans = rows[r + 1].$2;
          for (int ns = 0; ns < nextSpans.length; ns++) {
            if (visited[r + 1][ns]) continue;
            final double ov = math.min(sp.$2, nextSpans[ns].$2) - math.max(sp.$1, nextSpans[ns].$1);
            if (ov > bestOv) {
              bestOv = ov;
              nextS = ns;
            }
          }
          if (nextS < 0) break;
          r++;
          s = nextS;
        }
        if (reg.isNotEmpty) regions.add(reg);
      }
    }

    if (regions.isEmpty) return;

    // 4) ترتيب المناطق بنظام أقرب نقطة (Closest Point Join)
    final List<bool> regDone = List.filled(regions.length, false);
    final List<(int, bool)> orderedPlan = []; // (regionIndex, enterFromTop)

    // البداية من أقصى يمين الكلمة (طبيعي للعربي)
    int firstIdx = 0;
    double bestStartX = -double.infinity;
    for (int i = 0; i < regions.length; i++) {
      final mx = (regions[i].first.$3 + regions[i].first.$4) * 0.5;
      if (mx > bestStartX) {
        bestStartX = mx;
        firstIdx = i;
      }
    }

    double curRotX = regions[firstIdx].first.$4;
    double curRotY = regions[firstIdx].first.$2;
    regDone[firstIdx] = true;
    orderedPlan.add((firstIdx, true));
    // تحديث الموضع المتوقع بعد المنطقة الأولى
    curRotX = (regions[firstIdx].last.$3 + regions[firstIdx].last.$4) * 0.5;
    curRotY = regions[firstIdx].last.$2;

    for (int step = 1; step < regions.length; step++) {
      int bestI = -1;
      bool bestFromTop = true;
      double bestD2 = double.infinity;

      for (int i = 0; i < regions.length; i++) {
        if (regDone[i]) continue;
        final reg = regions[i];
        final topMidX = (reg.first.$3 + reg.first.$4) * 0.5;
        final topY = reg.first.$2;
        final botMidX = (reg.last.$3 + reg.last.$4) * 0.5;
        final botY = reg.last.$2;

        final dTop = (topMidX - curRotX) * (topMidX - curRotX) + (topY - curRotY) * (topY - curRotY);
        final dBot = (botMidX - curRotX) * (botMidX - curRotX) + (botY - curRotY) * (botY - curRotY);
        if (dTop < bestD2) {
          bestD2 = dTop;
          bestI = i;
          bestFromTop = true;
        }
        if (dBot < bestD2) {
          bestD2 = dBot;
          bestI = i;
          bestFromTop = false;
        }
      }
      if (bestI < 0) break;
      regDone[bestI] = true;
      orderedPlan.add((bestI, bestFromTop));
      final exitRow = bestFromTop ? regions[bestI].last : regions[bestI].first;
      curRotX = (exitRow.$3 + exitRow.$4) * 0.5;
      curRotY = exitRow.$2;
    }

    void emitRot(double vx, double vy, bool isMove) {
      final double gx = vx * ca - vy * sa;
      final double gy = vx * sa + vy * ca;
      addPt(gx, gy, isMove);
    }

    double needleX = 0.0, needleY = 0.0;
    bool hasNeedlePos = false;

    // 5) رسم كل منطقة: إذا كان الخروج الأقرب للمنطقة التالية من نفس طرف الدخول -> دخول بدرزة مخفية (Underpath) وعودة بتاتامي!
    for (int pIdx = 0; pIdx < orderedPlan.length; pIdx++) {
      final reg = regions[orderedPlan[pIdx].$1];
      bool enterFromTop = orderedPlan[pIdx].$2;

      // فحص أيهما أقرب لنهاية الإبرة الفعلية الآن (أعلى أم أسفل المنطقة)
      if (hasNeedlePos) {
        final tX = (reg.first.$3 + reg.first.$4) * 0.5;
        final tY = reg.first.$2;
        final bX = (reg.last.$3 + reg.last.$4) * 0.5;
        final bY = reg.last.$2;
        final dT = (tX - needleX) * (tX - needleX) + (tY - needleY) * (tY - needleY);
        final dB = (bX - needleX) * (bX - needleX) + (bY - needleY) * (bY - needleY);
        enterFromTop = dT <= dB;
      }

      // فحص هل الطرف الأقرب للمنطقة التالية هو نفس طرف الدخول (لاستخدام الدخول بدرزة والعودة بتاتامي)
      bool useUnderpathAndReturn = false;
      if (reg.length >= 4 && pIdx + 1 < orderedPlan.length) {
        final nextReg = regions[orderedPlan[pIdx + 1].$1];
        final nextRow = orderedPlan[pIdx + 1].$2 ? nextReg.first : nextReg.last;
        final nx = (nextRow.$3 + nextRow.$4) * 0.5;
        final ny = nextRow.$2;

        final entryRow = enterFromTop ? reg.first : reg.last;
        final oppRow = enterFromTop ? reg.last : reg.first;
        final dEntryToNext = (((entryRow.$3 + entryRow.$4) * 0.5 - nx) * ((entryRow.$3 + entryRow.$4) * 0.5 - nx)) +
            ((entryRow.$2 - ny) * (entryRow.$2 - ny));
        final dOppToNext = (((oppRow.$3 + oppRow.$4) * 0.5 - nx) * ((oppRow.$3 + oppRow.$4) * 0.5 - nx)) +
            ((oppRow.$2 - ny) * (oppRow.$2 - ny));
        if (dEntryToNext < dOppToNext * 0.85) {
          useUnderpathAndReturn = true;
        }
      }

      final List<(int, double, double, double)> orderedRows =
          enterFromTop ? reg : reg.reversed.toList();

      final firstSpan = orderedRows.first;
      final double entryMidX = (firstSpan.$3 + firstSpan.$4) * 0.5;
      final double entryX = hasNeedlePos
          ? ((needleX - firstSpan.$3).abs() <= (needleX - firstSpan.$4).abs() ? firstSpan.$3 : firstSpan.$4)
          : firstSpan.$4;
      final double distToEntry = hasNeedlePos
          ? math.sqrt((entryX - needleX) * (entryX - needleX) + (firstSpan.$2 - needleY) * (firstSpan.$2 - needleY))
          : 999.0;
      // إذا كانت المنطقة متصلة/ملاصقة للسابقة (<= 1.4 مم) ندخل مباشرةً بدون قفزة، وإلا قفزة نظيفة بدون خيط ظاهر
      final bool needJumpToRegion = !hasNeedlePos || distToEntry > 14.0;

      List<(int, double, double, double)> tatamiRows;
      bool firstRowAlreadyAnchored = false;

      if (useUnderpathAndReturn) {
        // الدخول بدرزة تمشي مخفية داخل منتصف الشكل (Underpath) حتى الطرف المقابل، ثم العودة بتاتامي يغطيها بالكامل!
        emitRot(entryMidX, firstSpan.$2, needJumpToRegion);
        double uxPrev = entryMidX;
        double uyPrev = firstSpan.$2;
        for (int k = 1; k < orderedRows.length; k++) {
          final row = orderedRows[k];
          final double safeL = math.min(row.$4, row.$3 + 2.5);
          final double safeR = math.max(row.$3, row.$4 - 2.5);
          final double mx = ((safeL + safeR) * 0.5);
          final double dy = row.$2 - uyPrev;
          final double dx = mx - uxPrev;
          if (dx * dx + dy * dy >= 324.0 || k == orderedRows.length - 1) {
            // خطوة درزة ~1.8..2.4 مم داخل الجسم
            emitRot(mx, row.$2, false);
            uxPrev = mx;
            uyPrev = row.$2;
          }
        }
        needleX = uxPrev;
        needleY = uyPrev;
        hasNeedlePos = true;
        tatamiRows = orderedRows.reversed.toList();
        firstRowAlreadyAnchored = true;
      } else {
        tatamiRows = orderedRows;
      }

      // تعبئة سطور التاتامي المتصلة للمنطقة
      bool forward = hasNeedlePos
          ? ((needleX - tatamiRows.first.$3).abs() <= (needleX - tatamiRows.first.$4).abs())
          : true;

      for (int k = 0; k < tatamiRows.length; k++) {
        final row = tatamiRows[k];
        final int rIdx = row.$1;
        final double y = row.$2;
        final double leftX = row.$3;
        final double rightX = row.$4;
        final double phase = _tatamiPhase(rIdx, pattern) * stLen;

        final double xStart = forward ? leftX : rightX;
        final double xEnd = forward ? rightX : leftX;
        final bool isMove = (k == 0 && !firstRowAlreadyAnchored) ? needJumpToRegion : false;

        emitRot(xStart, y, isMove);

        if (forward) {
          double gx = ((leftX - phase) / stLen).ceil() * stLen + phase;
          while (gx < rightX - 4.0) {
            if (gx > leftX + 4.0) emitRot(gx, y, false);
            gx += stLen;
          }
        } else {
          double gx = ((rightX - phase) / stLen).floor() * stLen + phase;
          while (gx > leftX + 4.0) {
            if (gx < rightX - 4.0) emitRot(gx, y, false);
            gx -= stLen;
          }
        }

        emitRot(xEnd, y, false);
        needleX = xEnd;
        needleY = y;
        hasNeedlePos = true;
        forward = !forward;
      }
    }
  }

  /// تنعيم انتقائي للمنحنيات اللطيفة فقط مع الحفاظ التام على الزوايا الحادة (< 125°) بدون أي تجويف
  static (List<double>, List<double>) _smoothGentleCurvesOnly(List<double> xs, List<double> ys) {
    final int n = xs.length;
    if (n < 4) return (xs, ys);
    final outX = <double>[xs.first];
    final outY = <double>[ys.first];
    for (int i = 1; i < n - 1; i++) {
      final double v1x = xs[i] - xs[i - 1], v1y = ys[i] - ys[i - 1];
      final double v2x = xs[i + 1] - xs[i], v2y = ys[i + 1] - ys[i];
      final double l1 = math.sqrt(v1x * v1x + v1y * v1y);
      final double l2 = math.sqrt(v2x * v2x + v2y * v2y);
      if (l1 > 0.5 && l2 > 0.5) {
        final double cosA = (v1x * v2x + v1y * v2y) / (l1 * l2);
        if (cosA > 0.72) {
          // منحنى ناعم فقط -> تنعيم خفيف
          outX.add(xs[i - 1] * 0.15 + xs[i] * 0.70 + xs[i + 1] * 0.15);
          outY.add(ys[i - 1] * 0.15 + ys[i] * 0.70 + ys[i + 1] * 0.15);
          continue;
        }
      }
      // زاوية حادة -> نحافظ على النقطة كما هي 100%
      outX.add(xs[i]);
      outY.add(ys[i]);
    }
    outX.add(xs.last);
    outY.add(ys.last);
    return (outX, outY);
  }

  static void _collectSatinColumnPolys({
    required Map<String, dynamic> el,
    required double ox,
    required double oy,
    required double scale,
    required List<List<double>> outX,
    required List<List<double>> outY,
  }) {
    final List<dynamic>? rawR1 = el['r1'] as List<dynamic>?;
    final List<dynamic>? rawR2 = el['r2'] as List<dynamic>?;
    if (rawR1 == null || rawR2 == null || rawR1.length < 4 || rawR2.length < 4) return;

    final b1 = _buildScaledPoly(rawR1, ox, oy, scale);
    final b2 = _buildScaledPoly(rawR2, ox, oy, scale);
    final double maxLen = math.max(b1.$3, b2.$3);
    if (maxLen < 1.5) return;

    final int segs = (maxLen / 7.5).ceil().clamp(8, 56);
    final List<double> r1x = [], r1y = [], r2x = [], r2y = [];
    for (int i = 0; i <= segs; i++) {
      final pt1 = _samplePoly(b1.$1, b1.$2, b1.$3, i / segs);
      final pt2 = _samplePoly(b2.$1, b2.$2, b2.$3, i / segs);
      r1x.add(pt1.$1);
      r1y.add(pt1.$2);
      r2x.add(pt2.$1);
      r2y.add(pt2.$2);
    }
    final sm1 = _smoothGentleCurvesOnly(r1x, r1y);
    final sm2 = _smoothGentleCurvesOnly(r2x, r2y);
    outX.add(<double>[...sm1.$1, ...sm2.$1.reversed]);
    outY.add(<double>[...sm1.$2, ...sm2.$2.reversed]);
  }

  static void _collectFillPoly({
    required Map<String, dynamic> el,
    required double ox,
    required double oy,
    required double scale,
    required List<List<double>> outX,
    required List<List<double>> outY,
  }) {
    final List<dynamic>? rawP = el['p'] as List<dynamic>?;
    if (rawP == null || rawP.length < 6) return;
    final int n = rawP.length ~/ 2;
    final xs = List<double>.filled(n, 0.0);
    final ys = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      xs[i] = ox + (rawP[i * 2] as num).toDouble() * scale;
      ys[i] = oy + (rawP[i * 2 + 1] as num).toDouble() * scale;
    }
    outX.add(xs);
    outY.add(ys);
  }

  /// استخلاص كامل مساحة الفونطات الرقمية (A1 / A3 / A4) عبر اتحاد المثلثات الفستونية المتتالية:
  /// - يغطي كل زاوية ومنحنى حاد (مثل م، ه، س، ل) بنسبة 100% بدون أي ثغرات مثلثية أو انقطاعات!
  static void _collectDigitizedRunPolys({
    required Map<String, dynamic> el,
    required double ox,
    required double oy,
    required double scale,
    required List<List<double>> outX,
    required List<List<double>> outY,
  }) {
    final List<dynamic>? rawP = el['p'] as List<dynamic>?;
    if (rawP == null || rawP.length < 6) return;
    final int n = rawP.length ~/ 2;
    final xs = List<double>.filled(n, 0.0);
    final ys = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      xs[i] = ox + (rawP[i * 2] as num).toDouble() * scale;
      ys[i] = oy + (rawP[i * 2 + 1] as num).toDouble() * scale;
    }

    // كل 3 نقاط فستون متتالية (P[i-1], P[i], P[i+1]) تكوّن مثلثاً يغطي كامل الشريط الفستوني حتى عند أدق الزوايا
    final double maxEdge = math.max(125.0, 90.0 * scale);
    for (int i = 1; i < n - 1; i++) {
      final double x0 = xs[i - 1], y0 = ys[i - 1];
      final double x1 = xs[i], y1 = ys[i];
      final double x2 = xs[i + 1], y2 = ys[i + 1];
      final double d01 = math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
      final double d12 = math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
      if (d01 < 1.2 || d12 < 1.2 || d01 > maxEdge || d12 > maxEdge) continue;
      final double area2 = ((x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)).abs();
      if (area2 < 8.0) continue; // تجاهل غرز التمشي المستقيمة (Underlay / Travel) التي مساحتها ~0
      outX.add(<double>[x0, x1, x2]);
      outY.add(<double>[y0, y1, y2]);
    }
  }

  static void _emitFillPolygon({
    required Map<String, dynamic> el,
    required double ox,
    required double oy,
    required double scale,
    required double densityUnits,
    double angleDeg = 0.0,
    int pattern = 0,
    double stitchLenUnits = 40.0,
    required void Function(double, double, bool) addPt,
  }) {
    final List<List<double>> px = [];
    final List<List<double>> py = [];
    _collectFillPoly(el: el, ox: ox, oy: oy, scale: scale, outX: px, outY: py);
    _emitUnifiedTatamiPolygons(
      polysX: px,
      polysY: py,
      densityUnits: densityUnits,
      angleDeg: angleDeg,
      pattern: pattern,
      stitchLenUnits: stitchLenUnits,
      addPt: addPt,
    );
  }
}

/// قارئ وفك تشفير ملفات داهاو الأصلي الكامل (.DHE و .DHA) بدقة emCAD 100%:
/// - يفصل قنوات .DHE بدقة: `0xD7 b1=10` للخرز (A=2.5مم، B=4مم، C=6×2.5مم) و `0xD7 b1=6` للترتر (A=3مم، B=5مم)
/// - يفصل نبضات .DHA بدقة بدون خطوط مشوّهة: نبضة1=خرزA، نبضة2=ترترB(5مم)، نبضة3/5=خرزB، نبضة4=ترترA(3مم)، نبضة6=خرزC(6×2.5مم)
/// - يحذف الألوان الفارغة الوهمية ويُسجّل رقم الغرزة الحقيقي لكل خرزة وترترة في stDev
class TarikProDahaoParser {
  static const List<int> _keyDhe = [
    0x08,0x50,0x18,0xFF,0x05,0x57,0x10,0x5E,
    0x1B,0x10,0x02,0x16,0x14,0x0D,0xFA,0x68,
    0x18,0x5F,0x1E,0x6D,0x18,0x76,0x26,0x69,
  ];
  static const List<int> _keyDha = [
    0x59,0x24,0x5B,0x26,0x5D,0x20,0x5F,0x22,
    0x51,0x2C,0x59,0x24,0x5B,0x26,0x5D,0x20,
    0x5F,0x22,0x51,0x2C,0x59,0x24,0x5B,0x26,
  ];
  static const List<int> _ip = [58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7];
  static const List<int> _ipr = [40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25];
  static const List<int> _e = [32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1];
  static const List<int> _p = [16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25];
  static const List<int> _pc1 = [57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4];
  static const List<int> _pc2 = [14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32];
  static const List<int> _sh = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1];
  static const List<List<int>> _s = [
    [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
    [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
    [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
    [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14],
    [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
    [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
    [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
    [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11],
  ];
  static final Int32List _palette = Int32List.fromList(const [
    0xFF009944, 0xFFE53935, 0xFFD4A017, 0xFF0088CC, 0xFFD81B60,
    0xFFFF7043, 0xFF6A1B9A, 0xFF00ACC1, 0xFF558B2F, 0xFF3949AB,
    0xFF8D6E63, 0xFFEC407A, 0xFF26A69A, 0xFF5C6BC0, 0xFFFBC02D,
  ]);

  static int _perm(int v, List<int> t, int n) {
    int r = 0;
    for (int i = 0; i < t.length; i++) {
      r = (r << 1) | ((v >>> (n - t[i])) & 1);
    }
    return r;
  }

  static List<int> _subkeys(List<int> k8) {
    int kv = 0;
    for (int i = 0; i < 8; i++) {
      kv = (kv << 8) | k8[i];
    }
    final int k56 = _perm(kv, _pc1, 64);
    int c = (k56 >>> 28) & 0xFFFFFFF;
    int d = k56 & 0xFFFFFFF;
    final List<int> ks = List<int>.filled(16, 0);
    for (int i = 0; i < 16; i++) {
      final int s = _sh[i];
      c = ((c << s) | (c >>> (28 - s))) & 0xFFFFFFF;
      d = ((d << s) | (d >>> (28 - s))) & 0xFFFFFFF;
      ks[i] = _perm((c << 28) | d, _pc2, 56);
    }
    return ks;
  }

  static Uint8List _desBlock(Uint8List b8, int off, List<int> ks) {
    int bv = 0;
    for (int i = 0; i < 8; i++) {
      bv = (bv << 8) | b8[off + i];
    }
    final int v = _perm(bv, _ip, 64);
    int l = (v >>> 32) & 0xFFFFFFFF;
    int r = v & 0xFFFFFFFF;
    for (int rIdx = 0; rIdx < 16; rIdx++) {
      final int ep = _perm(r, _e, 32) ^ ks[rIdx];
      int so = 0;
      for (int i = 0; i < 8; i++) {
        final int ch = (ep >>> (42 - i * 6)) & 0x3F;
        final int row = ((ch & 0x20) >>> 4) | (ch & 1);
        final int col = (ch >>> 1) & 0x0F;
        so = (so << 4) | _s[i][row * 16 + col];
      }
      final int nextR = l ^ _perm(so, _p, 32);
      l = r;
      r = nextR;
    }
    final int outV = _perm((r << 32) | l, _ipr, 64);
    final out = Uint8List(8);
    for (int i = 0; i < 8; i++) {
      out[i] = (outV >>> (56 - i * 8)) & 0xFF;
    }
    return out;
  }

  static Uint8List _des3Dec(Uint8List data, int start, int len, bool useDhe) {
    final key = useDhe ? _keyDhe : _keyDha;
    final k0 = _subkeys(key.sublist(0, 8));
    final k1 = _subkeys(key.sublist(8, 16)).reversed.toList();
    final k2 = _subkeys(key.sublist(16, 24));
    final int blocks = len ~/ 8;
    final out = Uint8List(blocks * 8);
    for (int b = 0; b < blocks; b++) {
      final s1 = _desBlock(data, start + b * 8, k0);
      final s2 = _desBlock(s1, 0, k1);
      final s3 = _desBlock(s2, 0, k2);
      out.setRange(b * 8, b * 8 + 8, s3);
    }
    return out;
  }

  static Uint8List _ringDec(Uint8List data, int start, int len, int seed16) {
    int c = seed16 & 0xFFFF;
    if (c < 0x6E) c += 0x6E;
    final k = <int>[
      c % 0x61,
      (5 * c) % 0x1B,
      (8 * c) % 0x13,
      c % 0x49,
      c % 0x21,
      (3 * c) % 0x39,
      (5 * c) % 0x27,
      c % 0x12,
    ];
    if (((k[0] % 0x3D) - (k[1] % 0x3D)).abs() < 6) k[1] += 0x11;
    if (((k[6] % 0x3F) - (k[7] % 0x3F)).abs() < 7) k[7] += 0x11;
    int i0 = 0, i1 = 2, i2 = 4, i3 = 6;
    final out = Uint8List(len);
    for (int i = 0; i < len; i++) {
      final int b = data[start + i];
      if (b < 0x3D) {
        out[i] = (b + k[i0]) % 0x3D;
        i0 ^= 1;
      } else if (b < 0x6E) {
        out[i] = ((b - 0x3D + k[i1]) % 0x31) + 0x3D;
        i1 ^= 1;
      } else if (b < 0xC1) {
        out[i] = ((b - 0x6E + k[i2]) % 0x53) + 0x6E;
        i2 ^= 1;
      } else {
        out[i] = (((b - 0xC1 + k[i3]) % 0x3F) + 0xC1) & 0xFF;
        i3 ^= 1;
      }
    }
    return out;
  }

  static Uint8List _des3Enc(Uint8List data, int start, int len, bool useDhe) {
    final key = useDhe ? _keyDhe : _keyDha;
    final k0Inv = _subkeys(key.sublist(0, 8)).reversed.toList();
    final k1 = _subkeys(key.sublist(8, 16));
    final k2Inv = _subkeys(key.sublist(16, 24)).reversed.toList();
    final int blocks = len ~/ 8;
    final out = Uint8List(blocks * 8);
    for (int b = 0; b < blocks; b++) {
      final s1 = _desBlock(data, start + b * 8, k2Inv);
      final s2 = _desBlock(s1, 0, k1);
      final s3 = _desBlock(s2, 0, k0Inv);
      out.setRange(b * 8, b * 8 + 8, s3);
    }
    return out;
  }

  static Uint8List _ringEnc(Uint8List data, int start, int len, int seed16) {
    int c = seed16 & 0xFFFF;
    if (c < 0x6E) c += 0x6E;
    final k = <int>[
      c % 0x61,
      (5 * c) % 0x1B,
      (8 * c) % 0x13,
      c % 0x49,
      c % 0x21,
      (3 * c) % 0x39,
      (5 * c) % 0x27,
      c % 0x12,
    ];
    if (((k[0] % 0x3D) - (k[1] % 0x3D)).abs() < 6) k[1] += 0x11;
    if (((k[6] % 0x3F) - (k[7] % 0x3F)).abs() < 7) k[7] += 0x11;
    int i0 = 0, i1 = 2, i2 = 4, i3 = 6;
    final out = Uint8List(len);
    for (int i = 0; i < len; i++) {
      final int b = data[start + i];
      if (b < 0x3D) {
        int v = (b - k[i0]) % 0x3D;
        if (v < 0) v += 0x3D;
        out[i] = v;
        i0 ^= 1;
      } else if (b < 0x6E) {
        int v = (b - 0x3D - k[i1]) % 0x31;
        if (v < 0) v += 0x31;
        out[i] = v + 0x3D;
        i1 ^= 1;
      } else if (b < 0xC1) {
        int v = (b - 0x6E - k[i2]) % 0x53;
        if (v < 0) v += 0x53;
        out[i] = v + 0x6E;
        i2 ^= 1;
      } else {
        int v = (b - 0xC1 - k[i3]) % 0x3F;
        if (v < 0) v += 0x3F;
        out[i] = (v + 0xC1) & 0xFF;
        i3 ^= 1;
      }
    }
    return out;
  }

  static int _u32LE(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);
  static int _u16LE(Uint8List b, int off) => b[off] | (b[off + 1] << 8);
  static void _putU32LE(Uint8List b, int off, int v) {
    b[off] = v & 0xFF;
    b[off + 1] = (v >>> 8) & 0xFF;
    b[off + 2] = (v >>> 16) & 0xFF;
    b[off + 3] = (v >>> 24) & 0xFF;
  }

  /// استخراج رقم القناة (1..8) من قناع البتّات الثماني (0x01=A .. 0x80=H)
  static int _maskToChannel1To8(int mask) {
    for (int bit = 0; bit < 8; bit++) {
      if ((mask & (1 << bit)) != 0) return bit + 1;
    }
    return 1;
  }

  /// استخراج لوحة الألوان الحقيقية للـ 20 لوناً من ترويسة ملف داهاو (0x1C..0x58) كما في emCAD
  static Int32List _extractHeaderPalette(Uint8List data) {
    if (data.length < 0x60) return _palette;
    final int nCol = _u32LE(data, 0x10);
    if (nCol >= 1 && nCol <= 32) {
      final int count = math.min(20, nCol);
      final List<int> cols = [];
      int nonZero = 0;
      for (int i = 0; i < count; i++) {
        final int o = 0x1C + i * 3;
        int r = data[o], g = data[o + 1], b = data[o + 2];
        if (r != 0 || g != 0 || b != 0) nonZero++;
        // تلطيف اللون الأبيض النقي قليلاً ليظهر بوضوح على خلفية العرض البيضاء
        if (r > 235 && g > 235 && b > 235) {
          r = 176;
          g = 190;
          b = 197;
        }
        cols.add((0xFF << 24) | (r << 16) | (g << 8) | b);
      }
      if (nonZero >= 2) return Int32List.fromList(cols);
    }
    return _palette;
  }

  static VectorDesignData? decodeSync(Uint8List data, bool preferDhe) {
    if (data.length < 0x130) return null;

    int? sOff, sNext, sParam;
    int? s1Off, s1Next, s1Param;
    int hdrXor = 0;
    bool matchedDhe = preferDhe;

    for (final useDhe in (preferDhe ? [true, false] : [false, true])) {
      bool nonZeroHdr = false;
      for (int i = 8; i < 16; i++) {
        if (data[i] != 0) {
          nonZeroHdr = true;
          break;
        }
      }
      final int hx = nonZeroHdr ? _u16LE(_des3Dec(data, 8, 8, useDhe), 0) : 0;
      final List<(int, int, int)> secs = [];
      int pos = 0x100;
      bool valid = false;
      for (int k = 0; k < 16; k++) {
        if (pos + 16 > data.length) break;
        final dec = _des3Dec(data, pos, 16, useDhe);
        final int styp = _u32LE(dec, 0);
        final int soff = _u32LE(dec, 4);
        final int sparam = _u32LE(dec, 8);
        if (styp > 24 || soff < 0x110 || soff > data.length) {
          secs.clear();
          break;
        }
        secs.add((styp, soff, sparam));
        if (styp == 0) {
          valid = secs.length >= 2;
          break;
        }
        pos += 16;
      }
      if (!valid) continue;
      for (int i = 0; i < secs.length - 1; i++) {
        if (secs[i].$1 == 1) {
          s1Off = secs[i].$2;
          s1Next = secs[i + 1].$2;
          s1Param = secs[i].$3;
        } else if (secs[i].$1 == 6) {
          sOff = secs[i].$2;
          sNext = secs[i + 1].$2;
          sParam = secs[i].$3;
          hdrXor = hx;
          matchedDhe = useDhe;
        }
      }
      if (sOff != null) break;
    }

    if (sOff == null || sNext == null || sParam == null || sNext <= sOff) return null;

    final Int32List activePalette = _extractHeaderPalette(data);
    // قراءة تسلسل الألوان الحقيقي من القسم 1 (Section 1) تماماً مثل emCAD
    List<int> sec1ColorSeq = const [];
    if (s1Off != null && s1Next != null && s1Param != null && s1Next > s1Off) {
      final s1Plain = _ringDec(data, s1Off, s1Next - s1Off, (s1Param ^ hdrXor ^ 0x3028) & 0xFFFF);
      if (s1Plain.isNotEmpty) {
        final List<int> seqList = [];
        for (int i = 0; i < math.min(256, s1Plain.length); i++) {
          final int v = s1Plain[i];
          if (v >= 1 && v <= activePalette.length) {
            seqList.add(v - 1);
          } else {
            break;
          }
        }
        if (seqList.isNotEmpty) sec1ColorSeq = seqList;
      }
    }
    int colorStepIdx = 0;
    int paletteIndexForStep(int step) =>
        sec1ColorSeq.isNotEmpty ? sec1ColorSeq[step % sec1ColorSeq.length] : (step % activePalette.length);
    final plain = _ringDec(data, sOff, sNext - sOff, (sParam ^ hdrXor ^ 0x3028) & 0xFFFF);
    final int lim = (sParam > 0 && sParam <= plain.length) ? sParam : plain.length;

    final stX = _ProFloat32Buf(8192);
    final stY = _ProFloat32Buf(8192);
    final stMove = _ProUint8Buf(8192);
    final stColor = _ProUint8Buf(8192);
    final stDev = _ProUint8Buf(8192);

    final seqX = _ProFloat32Buf(256);
    final seqY = _ProFloat32Buf(256);
    final seqCode = _ProUint8Buf(256);

    final beadX = _ProFloat32Buf(512);
    final beadY = _ProFloat32Buf(512);
    final beadCode = _ProUint8Buf(512);

    double cx = 0.0, cy = 0.0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int col = paletteIndexForStep(0);
    int colorCount = 1;
    bool hasStitchesInCol = false;
    bool needMove = true;
    bool inDev = false;
    int pulse = 0;
    double pulseOriginX = 0.0, pulseOriginY = 0.0;
    double ljx = 0.0, ljy = 0.0;
    int jumpsCount = 0;
    int pendingDev = 0;
    int pendingBeadCenterIdx = -1; // لتوسيط الخرزة في منتصف غرزة التثبيت تماماً مثل emCAD

    void trackPt(double x, double y) {
      if (!hasBounds) {
        minX = maxX = x;
        minY = maxY = y;
        hasBounds = true;
      } else {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }

    void emitStitch(double x, double y, bool isMove, int devTag) {
      stX.add(x);
      stY.add(y);
      stMove.add(isMove ? 1 : 0);
      stColor.add(col);
      stDev.add(devTag);
      if (isMove) jumpsCount++;
      hasStitchesInCol = true;
      trackPt(x, y);
    }

    int encodeSeqTag(int code) {
      final int c = code.clamp(1, 8);
      return c <= 4 ? c : (0x40 | c);
    }

    int encodeBeadTag(int code) {
      final int c = code.clamp(1, 8);
      return c <= 3 ? (4 + c) : (0x80 | c);
    }

    void recordSeq(double x, double y, int code) {
      final int c = code.clamp(1, 8);
      seqX.add(x);
      seqY.add(y);
      seqCode.add(c);
      final int tag = encodeSeqTag(c);
      if (stDev.length > 0 && stDev._buf[stDev.length - 1] == 0) {
        stDev._buf[stDev.length - 1] = tag;
      } else {
        pendingDev = tag;
      }
    }

    void recordBead(double x, double y, int code, {bool centerOnNextStitch = true}) {
      final int c = code.clamp(1, 8);
      beadX.add(x);
      beadY.add(y);
      beadCode.add(c);
      if (centerOnNextStitch) {
        pendingBeadCenterIdx = beadX.length - 1;
      }
      final int tag = encodeBeadTag(c);
      if (stDev.length > 0 && stDev._buf[stDev.length - 1] == 0) {
        stDev._buf[stDev.length - 1] = tag;
      } else {
        pendingDev = tag;
      }
    }

    /// تفريغ نبضات القفز المعايرة 100% وفق emCAD 2.6 و emCAD Pro 2.10:
    /// 1=ترتر A(3مم)، 2=ترتر B(5مم)، 3..4=خرز A(2.5مم)، 5+=خرز B(4مم)
    void flushPulse() {
      if (pulse <= 0) return;
      int devTag = 0;
      if (pulse == 1) {
        seqX.add(ljx);
        seqY.add(ljy);
        seqCode.add(1);
        devTag = 1;
      } else if (pulse == 2) {
        seqX.add(ljx);
        seqY.add(ljy);
        seqCode.add(2);
        devTag = 2;
      } else if (pulse <= 4) {
        final double mx = (pulseOriginX + ljx) * 0.5;
        final double my = (pulseOriginY + ljy) * 0.5;
        beadX.add(mx);
        beadY.add(my);
        beadCode.add(1); // خرز A (2.5×2.5 مم)
        devTag = 5;
      } else {
        final double mx = (pulseOriginX + ljx) * 0.5;
        final double my = (pulseOriginY + ljy) * 0.5;
        beadX.add(mx);
        beadY.add(my);
        beadCode.add(2); // خرز B (4×4 مم)
        devTag = 6;
      }
      emitStitch(ljx, ljy, needMove, devTag);
      needMove = false;
      pulse = 0;
    }

    for (int p = 0; p + 2 < lim; p += 3) {
      final int cmd = plain[p];
      final int b1 = plain[p + 1];
      final int b2 = plain[p + 2];
      if (cmd == 0xF8) break;

      if (cmd == 0xD7) {
        flushPulse();
        if (b1 == 0 && b2 == 0) {
          inDev = !inDev;
        } else if (b1 == 10) {
          // قناة الخرز الحديثة الكاملة (emCAD 2.10 / OutputDHE): 8 قنوات A..H (بتّات 0x01..0x80)
          final int bc = _maskToChannel1To8(b2);
          recordBead(cx, cy, bc, centerOnNextStitch: true);
        } else if (b1 == 6 && b2 >= 16 && !matchedDhe) {
          // قناة الخرز C/D في emCAD 2.6 (.DHA): 0xD7 (06, 16) = خرز C، 0xD7 (06, 32) = خرز D
          final int bc = b2 == 16 ? 3 : (b2 == 32 ? 4 : (b2 == 64 ? 5 : 6));
          recordBead(cx, cy, bc, centerOnNextStitch: true);
        } else if (b1 == 6) {
          // قناة الترتر الأصلية (A..H: بتّات 0x01..0x80)
          final int sc = _maskToChannel1To8(b2);
          recordSeq(cx, cy, sc);
        }
        continue;
      }

      if (cmd >= 0x88 && cmd <= 0x9F) {
        flushPulse();
        pendingBeadCenterIdx = -1;
        if (hasStitchesInCol) {
          colorStepIdx++;
          col = paletteIndexForStep(colorStepIdx);
          colorCount++;
          hasStitchesInCol = false;
        }
        needMove = true;
        inDev = false;
        continue;
      }

      final int kind = cmd & 0x9F;
      final double dy = ((cmd & 0x40) != 0 ? -b1 : b1).toDouble();
      final double dx = ((cmd & 0x20) != 0 ? -b2 : b2).toDouble();

      if (kind == 0x81) {
        pendingBeadCenterIdx = -1;
        if (inDev) {
          if (dx.abs() > 95.0 || dy.abs() > 95.0) {
            flushPulse();
            cx += dx;
            cy -= dy;
            needMove = true;
          } else {
            // في NONO.DHA (2.10) القفزات المتتالية ذات الحركة غير الصفرية تعني ترترة جديدة لكل قفزة!
            if ((dx != 0.0 || dy != 0.0) && pulse > 0) {
              flushPulse();
            }
            if (pulse == 0) {
              pulseOriginX = cx;
              pulseOriginY = cy;
            }
            cx += dx;
            cy -= dy;
            pulse++;
            ljx = cx;
            ljy = cy;
          }
        } else {
          cx += dx;
          cy -= dy;
          needMove = true;
        }
      } else if (kind == 0x80) {
        flushPulse();
        final double prevX = cx;
        final double prevY = cy;
        cx += dx;
        cy -= dy;
        // توسيط الخرزة على منتصف غرزة التثبيت الفورية (تماماً مثل emCAD)
        if (pendingBeadCenterIdx >= 0 && pendingBeadCenterIdx < beadX.length) {
          if (dx.abs() <= 65.0 && dy.abs() <= 65.0 && (dx != 0.0 || dy != 0.0)) {
            beadX._buf[pendingBeadCenterIdx] = (prevX + cx) * 0.5;
            beadY._buf[pendingBeadCenterIdx] = (prevY + cy) * 0.5;
          }
          pendingBeadCenterIdx = -1;
        }
        emitStitch(cx, cy, needMove, pendingDev);
        pendingDev = 0;
        needMove = false;
      }
    }

    flushPulse();
    if (stX.length < 2) return null;
    return VectorDesignData(
      stX: stX.finish(),
      stY: stY.finish(),
      stMove: stMove.finish(),
      stColor: stColor.finish(),
      stDev: (seqX.length > 0 || beadX.length > 0) ? stDev.finish() : null,
      seqX: seqX.finish(),
      seqY: seqY.finish(),
      seqCode: seqCode.finish(),
      beadX: beadX.finish(),
      beadY: beadY.finish(),
      beadCode: beadCode.finish(),
      paletteArgb: activePalette,
      stitches: stX.length,
      colorCount: colorCount,
      stopsCount: colorCount > 1 ? colorCount - 1 : 0,
      jumpsCount: jumpsCount,
      sequinsCount: seqX.length,
      beadsCount: beadX.length,
      trimsCount: 0,
      minX: hasBounds ? minX : 0.0,
      maxX: hasBounds ? maxX : 0.0,
      minY: hasBounds ? minY : 0.0,
      maxY: hasBounds ? maxY : 0.0,
      hasBounds: hasBounds,
      machineType: matchedDhe ? 'Dahao (.DHE)' : 'Dahao (.DHA)',
    );
  }

  static Future<VectorDesignData?> loadVector(String filePath) async {
    try {
      final f = File(filePath);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      final preferDhe = filePath.toLowerCase().endsWith('.dhe');
      return await Isolate.run(() => decodeSync(bytes, preferDhe));
    } catch (_) {
      return null;
    }
  }
}

/// فهرس مكاني فائق السرعة (O(N+B+S) يُحسب مرة واحدة ويُحفظ تلقائياً عبر Expando):
/// - يحسب زاوية الخيط لكل خرزة C في O(1) بدل 555 مليون عملية/إطار (يسرّع ملفات 185 ألف غرزة 1000 مرة!)
/// - يربط كل خرزة وترترة برقم غرزتها الفعلي لتطابق 100% أثناء المحاكاة بدون أي ظهور مبكّر
class TarikDesignSpatialIndex {
  static final Expando<TarikDesignSpatialIndex> _cache = Expando<TarikDesignSpatialIndex>('tarik_spatial_idx');

  final Float32List beadAngles;
  final Int32List seqStitchIdx;
  final Int32List beadStitchIdx;

  const TarikDesignSpatialIndex({
    required this.beadAngles,
    required this.seqStitchIdx,
    required this.beadStitchIdx,
  });

  static TarikDesignSpatialIndex of(VectorDesignData data) {
    final existing = _cache[data];
    if (existing != null) return existing;
    final built = _build(data);
    _cache[data] = built;
    return built;
  }

  static TarikDesignSpatialIndex _build(VectorDesignData data) {
    final int nSt = data.stX.length;
    final int nSeq = data.seqX.length;
    final int nBead = data.beadX.length;
    final beadAngles = Float32List(nBead);
    final seqStitchIdx = Int32List(nSeq);
    final beadStitchIdx = Int32List(nBead);

    if (nSt < 2 || (nSeq == 0 && nBead == 0)) {
      return TarikDesignSpatialIndex(
        beadAngles: beadAngles,
        seqStitchIdx: seqStitchIdx,
        beadStitchIdx: beadStitchIdx,
      );
    }

    // بناء شبكة مكانية سريعة (خلية = 50 وحدة = 5 مم)
    const double invCell = 1.0 / 50.0;
    final Map<int, List<int>> grid = {};
    int cellKey(int cx, int cy) => ((cx + 32768) << 16) ^ (cy + 32768);

    for (int i = 0; i < nSt; i++) {
      final int cx = (data.stX[i] * invCell).floor();
      final int cy = (data.stY[i] * invCell).floor();
      final k = cellKey(cx, cy);
      final bucket = grid[k];
      if (bucket != null) {
        if (bucket.length < 48) bucket.add(i);
      } else {
        grid[k] = [i];
      }
    }

    // دالة إيجاد أقرب غرزة ضمن الجوار 3×3 (متوسط O(1) لكل عنصر!)
    (int, double) findNearest(double px, double py, int minHintIdx) {
      final int cx = (px * invCell).floor();
      final int cy = (py * invCell).floor();
      int bestIdx = minHintIdx.clamp(0, nSt - 1);
      double bestScore = double.infinity;
      double bestAng = 0.0;

      for (int ox = -1; ox <= 1; ox++) {
        for (int oy = -1; oy <= 1; oy++) {
          final bucket = grid[cellKey(cx + ox, cy + oy)];
          if (bucket == null) continue;
          for (int b = 0; b < bucket.length; b++) {
            final int idx = bucket[b];
            final double dx = data.stX[idx] - px;
            final double dy = data.stY[idx] - py;
            final double d2 = dx * dx + dy * dy;
            // أفضلية خفيفة للغرز التي تأتي بعد العنصر السابق للحفاظ على التسلسل الزمني الصحيح
            final double penalty = idx < minHintIdx ? 25.0 : 0.0;
            final double score = d2 + penalty;
            if (score < bestScore) {
              bestScore = score;
              bestIdx = idx;
              if (idx > 0 && data.stMove[idx] == 0) {
                final double sx = data.stX[idx] - data.stX[idx - 1];
                final double sy = data.stY[idx] - data.stY[idx - 1];
                if (sx * sx + sy * sy > 2.0) bestAng = math.atan2(sy, sx);
              } else if (idx + 1 < nSt && data.stMove[idx + 1] == 0) {
                final double sx = data.stX[idx + 1] - data.stX[idx];
                final double sy = data.stY[idx + 1] - data.stY[idx];
                if (sx * sx + sy * sy > 2.0) bestAng = math.atan2(sy, sx);
              }
            }
          }
        }
      }
      return (bestIdx, bestAng);
    }

    // إذا كان stDev موجوداً (في .DHE و .DHA و .DST)، نستخرج رقم الغرزة المباشر بدقة 100% في O(N)!
    final Uint8List? dev = data.stDev;
    if (dev != null && dev.length == nSt) {
      int si = 0, bi = 0;
      for (int i = 0; i < nSt; i++) {
        final int rawDv = dev[i];
        final bool isSeqTag = ((rawDv & 0xC0) == 0 && (rawDv & 0x0F) >= 1 && (rawDv & 0x0F) <= 4) ||
            ((rawDv & 0x40) != 0 && (rawDv & 0x0F) >= 1 && (rawDv & 0x0F) <= 8);
        final bool isBeadTag = ((rawDv & 0xC0) == 0 && (rawDv & 0x0F) >= 5 && (rawDv & 0x0F) <= 7) ||
            ((rawDv & 0x80) != 0 && (rawDv & 0x0F) >= 1 && (rawDv & 0x0F) <= 8);
        if (isSeqTag && si < nSeq) {
          seqStitchIdx[si++] = i;
        } else if (isBeadTag && bi < nBead) {
          beadStitchIdx[bi] = i;
          double ang = 0.0;
          if (i > 0 && data.stMove[i] == 0) {
            final double sx = data.stX[i] - data.stX[i - 1];
            final double sy = data.stY[i] - data.stY[i - 1];
            if (sx * sx + sy * sy > 2.0) ang = math.atan2(sy, sx);
          } else if (i + 1 < nSt && data.stMove[i + 1] == 0) {
            final double sx = data.stX[i + 1] - data.stX[i];
            final double sy = data.stY[i + 1] - data.stY[i];
            if (sx * sx + sy * sy > 2.0) ang = math.atan2(sy, sx);
          }
          beadAngles[bi] = ang;
          bi++;
        }
      }
      // إكمال أي عناصر متبقية عبر الفهرس المكاني
      int lastS = si > 0 ? seqStitchIdx[si - 1] : 0;
      for (; si < nSeq; si++) {
        final res = findNearest(data.seqX[si], data.seqY[si], lastS);
        seqStitchIdx[si] = res.$1;
        lastS = res.$1;
      }
      int lastB = bi > 0 ? beadStitchIdx[bi - 1] : 0;
      for (; bi < nBead; bi++) {
        final res = findNearest(data.beadX[bi], data.beadY[bi], lastB);
        beadStitchIdx[bi] = res.$1;
        beadAngles[bi] = res.$2;
        lastB = res.$1;
      }
    } else {
      int lastS = 0;
      for (int i = 0; i < nSeq; i++) {
        final res = findNearest(data.seqX[i], data.seqY[i], lastS);
        seqStitchIdx[i] = res.$1;
        lastS = res.$1;
      }
      int lastB = 0;
      for (int i = 0; i < nBead; i++) {
        final res = findNearest(data.beadX[i], data.beadY[i], lastB);
        beadStitchIdx[i] = res.$1;
        beadAngles[i] = res.$2;
        lastB = res.$1;
      }
    }

    return TarikDesignSpatialIndex(
      beadAngles: beadAngles,
      seqStitchIdx: seqStitchIdx,
      beadStitchIdx: beadStitchIdx,
    );
  }
}

/// الثوابت الهندسية الموحّدة لجميع شاشات التطبيق (عرض 3D فقط في كامل التطبيق)
class TarikRenderSpecs {
  static const double unitsPerMm = 10.0;
  static const double unitsPerCm = 100.0;
  /// عرض الخيط الحقيقي في العرض ثلاثي الأبعاد (0.41 مم = 4.1 وحدة)
  static const double threadWidthUnits3D = 4.1;
  /// زاوية برمة الخيط الحلزونية المفتوحة (20 درجة لإطالة البرمة وانسيابيتها)
  static const double threadTwistAngleRad = 20.0 * math.pi / 180.0;
  /// طول دورة البرمة الواحدة (~1.45 مم لتتناسب مع زاوية 20°)
  static const double threadTwistPitchUnits = 14.5;
  /// سماكة خط التحديد الهندسي في محرر العناصر فقط
  static const double stroke2DScreenPx = 1.05;
  /// حدود إلغاء القفزات العابرة
  static const double maxStitchUnits3D = 120.0;
  static const double maxStitchUnits2D = 145.0;
  /// مقاسات الترتر المعايرة: A = 3.0 مم، B = 5.0 مم
  static const List<double> seqDiamUnits = [30.0, 50.0, 30.0, 50.0];
  /// مقاسات الخرز المعايرة: A = 2.5×2.5 مم، B = 4.0×4.0 مم، C = 6.0×2.5 مم
  static const double beadADiamUnits = 25.0;
  static const double beadBDiamUnits = 40.0;
  static const double beadCLenUnits = 60.0;
  static const double beadCHeightUnits = 25.0;
}


/// إعداد قناة واحدة من قنوات الماكينة الثماني (A – H) مثل شريط emCAD العلوي
class TarikDeviceChannelConfig {
  final int index; // 0=A .. 7=H
  /// 0 = خيط عادي (معطّل)، 1 = ترتر (Sequin)، 2 = خرز (Bead)
  int kind;
  /// للترتر: 0 = 3 مم، 1 = 5 مم
  /// للخرز: 0 = مربع 2.5×2.5 مم، 1 = مربع 4×4 مم، 2 = مستطيل 5×2.5 مم، 3 = مستطيل 6×2.5 مم
  int sizeCode;
  /// الخامة في المعاينة 3D: 0 = لؤلؤي، 1 = ذهبي، 2 = فضي، 3 = برونزي، 4 = ملوّن/كريستال
  int finish;
  bool visible;

  TarikDeviceChannelConfig({
    required this.index,
    required this.kind,
    required this.sizeCode,
    required this.finish,
    this.visible = true,
  });

  String get letter => String.fromCharCode(65 + index.clamp(0, 7));

  TarikDeviceChannelConfig copyWith({
    int? kind,
    int? sizeCode,
    int? finish,
    bool? visible,
  }) {
    return TarikDeviceChannelConfig(
      index: index,
      kind: kind ?? this.kind,
      sizeCode: sizeCode ?? this.sizeCode,
      finish: finish ?? this.finish,
      visible: visible ?? this.visible,
    );
  }

  Map<String, dynamic> toJson() => {
        'i': index,
        'k': kind,
        's': sizeCode,
        'f': finish,
        'v': visible,
      };

  factory TarikDeviceChannelConfig.fromJson(Map<String, dynamic> j, int fallbackIdx) {
    return TarikDeviceChannelConfig(
      index: (j['i'] as num?)?.toInt() ?? fallbackIdx,
      kind: ((j['k'] as num?)?.toInt() ?? 0).clamp(0, 2),
      sizeCode: ((j['s'] as num?)?.toInt() ?? 0).clamp(0, 3),
      finish: ((j['f'] as num?)?.toInt() ?? 0).clamp(0, 4),
      visible: j['v'] != false,
    );
  }
}

/// بروفايل أجهزة الماكينة ذو الـ 8 قنوات (A – H) + قوالب داهاو الجاهزة + نطاق التطبيق على الألوان
class TarikMachineDeviceProfile {
  final String presetId; // 'emcad_std', '4b2s', '2b2s', '8b', 'custom'
  final List<TarikDeviceChannelConfig> channels; // 8 قنوات دائماً: A..H
  final bool applyToAllColors;
  final Map<int, String> perColorRule; // عند إيقاف applyToAllColors: رقم اللون -> presetId
  final bool useCustomFinishes;

  const TarikMachineDeviceProfile({
    required this.presetId,
    required this.channels,
    this.applyToAllColors = true,
    this.perColorRule = const {},
    this.useCustomFinishes = false,
  });

  factory TarikMachineDeviceProfile.preset(String id, {bool applyToAllColors = true}) {
    switch (id) {
      case '4b2s':
        // قاعدة OutputDHE.exe (4 خرز A..D + 2 ترتر E,F)
        return TarikMachineDeviceProfile(
          presetId: '4b2s',
          applyToAllColors: applyToAllColors,
          channels: [
            TarikDeviceChannelConfig(index: 0, kind: 2, sizeCode: 0, finish: 0), // A: خرز 2.5×2.5 لؤلؤي
            TarikDeviceChannelConfig(index: 1, kind: 2, sizeCode: 1, finish: 1), // B: خرز 4×4 ذهبي
            TarikDeviceChannelConfig(index: 2, kind: 2, sizeCode: 3, finish: 3), // C: خرز 6×2.5 برونزي
            TarikDeviceChannelConfig(index: 3, kind: 2, sizeCode: 2, finish: 2), // D: خرز 5×2.5 فضي
            TarikDeviceChannelConfig(index: 4, kind: 1, sizeCode: 0, finish: 1), // E: ترتر 3 مم ذهبي
            TarikDeviceChannelConfig(index: 5, kind: 1, sizeCode: 1, finish: 3), // F: ترتر 5 مم برونزي
            TarikDeviceChannelConfig(index: 6, kind: 0, sizeCode: 0, finish: 0), // G: معطّل
            TarikDeviceChannelConfig(index: 7, kind: 0, sizeCode: 0, finish: 0), // H: معطّل
          ],
        );
      case '2b2s':
        // قاعدة 2 خرز (A,B) + 2 ترتر (E,F)
        return TarikMachineDeviceProfile(
          presetId: '2b2s',
          applyToAllColors: applyToAllColors,
          channels: [
            TarikDeviceChannelConfig(index: 0, kind: 2, sizeCode: 0, finish: 0), // A: خرز 2.5×2.5
            TarikDeviceChannelConfig(index: 1, kind: 2, sizeCode: 1, finish: 1), // B: خرز 4×4
            TarikDeviceChannelConfig(index: 2, kind: 0, sizeCode: 0, finish: 0), // C: معطّل
            TarikDeviceChannelConfig(index: 3, kind: 0, sizeCode: 0, finish: 0), // D: معطّل
            TarikDeviceChannelConfig(index: 4, kind: 1, sizeCode: 0, finish: 1), // E: ترتر 3 مم
            TarikDeviceChannelConfig(index: 5, kind: 1, sizeCode: 1, finish: 3), // F: ترتر 5 مم
            TarikDeviceChannelConfig(index: 6, kind: 0, sizeCode: 0, finish: 0), // G: معطّل
            TarikDeviceChannelConfig(index: 7, kind: 0, sizeCode: 0, finish: 0), // H: معطّل
          ],
        );
      case '8b':
        // 8 قنوات خرز فقط (A..H)
        return TarikMachineDeviceProfile(
          presetId: '8b',
          applyToAllColors: applyToAllColors,
          channels: [
            TarikDeviceChannelConfig(index: 0, kind: 2, sizeCode: 0, finish: 0), // A: 2.5×2.5 لؤلؤي
            TarikDeviceChannelConfig(index: 1, kind: 2, sizeCode: 1, finish: 1), // B: 4×4 ذهبي
            TarikDeviceChannelConfig(index: 2, kind: 2, sizeCode: 3, finish: 3), // C: 6×2.5 برونزي
            TarikDeviceChannelConfig(index: 3, kind: 2, sizeCode: 2, finish: 2), // D: 5×2.5 فضي
            TarikDeviceChannelConfig(index: 4, kind: 2, sizeCode: 0, finish: 4), // E: 2.5×2.5 كريستال
            TarikDeviceChannelConfig(index: 5, kind: 2, sizeCode: 1, finish: 0), // F: 4×4 لؤلؤي
            TarikDeviceChannelConfig(index: 6, kind: 2, sizeCode: 3, finish: 1), // G: 6×2.5 ذهبي
            TarikDeviceChannelConfig(index: 7, kind: 2, sizeCode: 2, finish: 4), // H: 5×2.5 كريستال
          ],
        );
      case 'emcad_std':
      default:
        // قياسي emCAD: A,B ترتر (3 و5 مم) + C,D,E,F خرز (2.5، 4، 6×2.5، 5×2.5) + G,H ترتر إضافي
        return TarikMachineDeviceProfile(
          presetId: 'emcad_std',
          applyToAllColors: applyToAllColors,
          channels: [
            TarikDeviceChannelConfig(index: 0, kind: 1, sizeCode: 0, finish: 1), // A: ترتر 3 مم ذهبي
            TarikDeviceChannelConfig(index: 1, kind: 1, sizeCode: 1, finish: 3), // B: ترتر 5 مم برونزي
            TarikDeviceChannelConfig(index: 2, kind: 2, sizeCode: 0, finish: 0), // C: خرز 2.5×2.5 لؤلؤي
            TarikDeviceChannelConfig(index: 3, kind: 2, sizeCode: 1, finish: 1), // D: خرز 4×4 ذهبي
            TarikDeviceChannelConfig(index: 4, kind: 2, sizeCode: 3, finish: 3), // E: خرز 6×2.5 برونزي
            TarikDeviceChannelConfig(index: 5, kind: 2, sizeCode: 2, finish: 2), // F: خرز 5×2.5 فضي
            TarikDeviceChannelConfig(index: 6, kind: 1, sizeCode: 0, finish: 0), // G: ترتر 3 مم لؤلؤي
            TarikDeviceChannelConfig(index: 7, kind: 1, sizeCode: 1, finish: 2), // H: ترتر 5 مم فضي
          ],
        );
    }
  }

  TarikMachineDeviceProfile copyWith({
    String? presetId,
    List<TarikDeviceChannelConfig>? channels,
    bool? applyToAllColors,
    Map<int, String>? perColorRule,
    bool? useCustomFinishes,
  }) {
    return TarikMachineDeviceProfile(
      presetId: presetId ?? this.presetId,
      channels: channels ?? this.channels.map((c) => c.copyWith()).toList(),
      applyToAllColors: applyToAllColors ?? this.applyToAllColors,
      perColorRule: perColorRule ?? Map<int, String>.from(this.perColorRule),
      useCustomFinishes: useCustomFinishes ?? this.useCustomFinishes,
    );
  }

  /// قائمة القنوات المفعّلة من نوع ترتر بالترتيب
  List<TarikDeviceChannelConfig> get sequinChannels =>
      channels.where((c) => c.kind == 1).toList(growable: false);

  /// قائمة القنوات المفعّلة من نوع خرز بالترتيب
  List<TarikDeviceChannelConfig> get beadChannels =>
      channels.where((c) => c.kind == 2).toList(growable: false);

  /// استرجاع إعداد العرض لترتر برقم (1..8) حسب البروفايل النشط
  TarikDeviceChannelConfig resolveSequinConfig(int code) {
    final int idx = (code - 1).clamp(0, 7);
    final seqs = sequinChannels;
    if (seqs.isNotEmpty) {
      return seqs[idx % seqs.length];
    }
    return channels[idx];
  }

  /// استرجاع إعداد العرض لخرز برقم (1..8) حسب البروفايل النشط
  TarikDeviceChannelConfig resolveBeadConfig(int code) {
    final int idx = (code - 1).clamp(0, 7);
    final beads = beadChannels;
    if (beads.isNotEmpty) {
      return beads[idx % beads.length];
    }
    return channels[idx];
  }

  /// استرجاع البروفايل الفعلي للون معين عند التصدير
  TarikMachineDeviceProfile effectiveForColor(int colorIndex) {
    if (applyToAllColors) return this;
    final override = perColorRule[colorIndex];
    if (override == null || override == presetId) return this;
    if (override == 'none') {
      return TarikMachineDeviceProfile(
        presetId: 'none',
        channels: List.generate(
          8,
          (i) => TarikDeviceChannelConfig(index: i, kind: 0, sizeCode: 0, finish: 0, visible: false),
        ),
      );
    }
    return TarikMachineDeviceProfile.preset(override);
  }

  String label(bool isAr) {
    switch (presetId) {
      case '4b2s':
        return isAr ? '4 خرز + 2 ترتر' : '4 Beads + 2 Sequins';
      case '2b2s':
        return isAr ? '2 خرز + 2 ترتر' : '2 Beads + 2 Sequins';
      case '8b':
        return isAr ? '8 خرز فقط' : '8 Beads Only';
      case 'custom':
        return isAr ? 'مخصص (A–H)' : 'Custom (A–H)';
      default:
        return isAr ? 'داهاو قياسي' : 'emCAD Standard';
    }
  }

  Map<String, dynamic> toJson() => {
        'presetId': presetId,
        'applyToAllColors': applyToAllColors,
        'useCustomFinishes': useCustomFinishes,
        'channels': channels.map((c) => c.toJson()).toList(),
        'perColorRule': perColorRule.map((k, v) => MapEntry(k.toString(), v)),
      };

  factory TarikMachineDeviceProfile.fromJson(Map<String, dynamic> j) {
    final String pid = (j['presetId'] ?? 'emcad_std').toString();
    final rawCh = j['channels'] as List?;
    List<TarikDeviceChannelConfig> chs;
    if (rawCh != null && rawCh.length == 8) {
      chs = List.generate(
        8,
        (i) => TarikDeviceChannelConfig.fromJson(Map<String, dynamic>.from(rawCh[i] as Map), i),
      );
    } else {
      chs = TarikMachineDeviceProfile.preset(pid).channels;
    }
    final Map<int, String> pcr = {};
    if (j['perColorRule'] is Map) {
      (j['perColorRule'] as Map).forEach((k, v) {
        final ki = int.tryParse(k.toString());
        if (ki != null && v != null) pcr[ki] = v.toString();
      });
    }
    return TarikMachineDeviceProfile(
      presetId: pid,
      channels: chs,
      applyToAllColors: j['applyToAllColors'] != false,
      perColorRule: pcr,
      useCustomFinishes: j['useCustomFinishes'] == true,
    );
  }
}

/// المدير المركزي الدائم لإعدادات أجهزة الماكينة (A – H) عبر التطبيق بالكامل
class TarikMachineDeviceManager {
  static TarikMachineDeviceProfile _current = TarikMachineDeviceProfile.preset('emcad_std');
  static final ValueNotifier<int> versionNotifier = ValueNotifier<int>(0);
  static String? _prefsFilePath;

  static TarikMachineDeviceProfile get current => _current;

  static Future<void> loadFromFile(String filePath) async {
    _prefsFilePath = filePath;
    try {
      final f = File(filePath);
      if (await f.exists()) {
        final raw = await f.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _current = TarikMachineDeviceProfile.fromJson(decoded);
          versionNotifier.value++;
        }
      }
    } catch (_) {}
  }

  static Future<void> update(TarikMachineDeviceProfile next) async {
    _current = next;
    versionNotifier.value++;
    if (_prefsFilePath != null) {
      try {
        final f = File(_prefsFilePath!);
        await f.writeAsString(jsonEncode(next.toJson()), flush: true);
      } catch (_) {}
    }
  }
}

/// محسّن معاينات ملفات `.EMB` مع الحفاظ التام على لون الخلفية الأساسي وتمديده لآخر البطاقة بدون حواف بيضاء
class TarikProEmbImageEnhancer {
  static final Map<int, Color> _bgColorCache = {};

  /// استخراج لون الخلفية الأساسي لصورة `.EMB` من الزوايا الأربعة لتلوين كامل البطاقة به بدون حواف بيضاء
  static Future<Color> detectBgColor(Uint8List rawBytes) async {
    final int key = rawBytes.length ^
        (rawBytes.isNotEmpty ? rawBytes[0] << 8 : 0) ^
        (rawBytes.length > 128 ? rawBytes[128] << 16 : 0) ^
        (rawBytes.length > 256 ? rawBytes[rawBytes.length - 1] << 24 : 0);
    final cached = _bgColorCache[key];
    if (cached != null) return cached;
    try {
      final codec = await ui.instantiateImageCodec(rawBytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final int w = img.width;
      final int h = img.height;
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      codec.dispose();
      if (bd == null || w < 4 || h < 4) return Colors.white;
      final Uint8List src = bd.buffer.asUint8List();
      final List<int> cornerIdx = [
        0,
        (w - 1) * 4,
        (h - 1) * w * 4,
        ((h - 1) * w + (w - 1)) * 4,
      ];
      int r = 0, g = 0, b = 0;
      for (final ci in cornerIdx) {
        r += src[ci];
        g += src[ci + 1];
        b += src[ci + 2];
      }
      final col = Color.fromARGB(255, r ~/ 4, g ~/ 4, b ~/ 4);
      _bgColorCache[key] = col;
      return col;
    } catch (_) {
      return Colors.white;
    }
  }

  static Future<Uint8List?> enhancePreview(Uint8List rawBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(rawBytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final int w = img.width;
      final int h = img.height;
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      codec.dispose();
      if (bd == null || w < 16 || h < 16) return rawBytes;

      final Uint8List src = bd.buffer.asUint8List();

      final List<int> cornerIdx = [
        0,
        (w - 1) * 4,
        (h - 1) * w * 4,
        ((h - 1) * w + (w - 1)) * 4,
      ];
      int bgR = 0, bgG = 0, bgB = 0;
      for (final ci in cornerIdx) {
        bgR += src[ci];
        bgG += src[ci + 1];
        bgB += src[ci + 2];
      }
      bgR ~/= 4;
      bgG ~/= 4;
      bgB ~/= 4;

      int minX = w, maxX = 0, minY = h, maxY = 0;
      for (int y = 0; y < h; y++) {
        int rowHits = 0;
        int rowMinX = w, rowMaxX = 0;
        final int rowOff = y * w * 4;
        for (int x = 0; x < w; x++) {
          final int o = rowOff + x * 4;
          if ((src[o] - bgR).abs() > 14 ||
              (src[o + 1] - bgG).abs() > 14 ||
              (src[o + 2] - bgB).abs() > 14) {
            rowHits++;
            if (x < rowMinX) rowMinX = x;
            if (x > rowMaxX) rowMaxX = x;
          }
        }
        if (rowHits >= 2) {
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
          if (rowMinX < minX) minX = rowMinX;
          if (rowMaxX > maxX) maxX = rowMaxX;
        }
      }

      if (maxX <= minX + 4 || maxY <= minY + 4) return rawBytes;
      minX = math.max(0, minX - 4);
      minY = math.max(0, minY - 4);
      maxX = math.min(w - 1, maxX + 4);
      maxY = math.min(h - 1, maxY + 4);

      final int cw = maxX - minX + 1;
      final int ch = maxY - minY + 1;
      final out = Uint8List(cw * ch * 4);

      for (int y = 0; y < ch; y++) {
        final int srcRow = (minY + y) * w * 4;
        final int dstRow = y * cw * 4;
        for (int x = 0; x < cw; x++) {
          final int so = srcRow + (minX + x) * 4;
          final int doff = dstRow + x * 4;
          double r = src[so].toDouble();
          double g = src[so + 1].toDouble();
          double b = src[so + 2].toDouble();

          final bool isBg = (r - bgR).abs() <= 10 && (g - bgG).abs() <= 10 && (b - bgB).abs() <= 10;
          if (!isBg) {
            r = (r - 128.0) * 1.10 + 128.0;
            g = (g - 128.0) * 1.10 + 128.0;
            b = (b - 128.0) * 1.10 + 128.0;
            final double luma = 0.299 * r + 0.587 * g + 0.114 * b;
            r = luma + (r - luma) * 1.08;
            g = luma + (g - luma) * 1.08;
            b = luma + (b - luma) * 1.08;
          }

          out[doff] = r.clamp(0, 255).round();
          out[doff + 1] = g.clamp(0, 255).round();
          out[doff + 2] = b.clamp(0, 255).round();
          out[doff + 3] = 255;
        }
      }

      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(out, cw, ch, ui.PixelFormat.rgba8888, completer.complete);
      final outImg = await completer.future;
      final pngBd = await outImg.toByteData(format: ui.ImageByteFormat.png);
      outImg.dispose();
      return pngBd?.buffer.asUint8List() ?? rawBytes;
    } catch (_) {
      return rawBytes;
    }
  }
}

/// مولّد وكاش الخامات الفوتوغرافية فائقة الدقة (256×256 PBR Sprites):
/// - الترتر: قرص معدني مقعّر بدقة 256×256 (A=3 مم، B=5 مم)
/// - الخرز A و B: مربّع مكسور الحواف (2.5×2.5 مم و 4.0×4.0 مم) بتدرّج ناصع من المنتصف وغامق من الأطراف
/// - الخرز C: مستطيل مكسور الحواف (5.0×2.5 مم) بتدرّج ناصع من المنتصف وغامق من الأطراف يدور باتجاه الخيط
class TarikProPbrSprites {
  static ui.Image? seqGold;
  static ui.Image? seqBronze;
  static ui.Image? seqSilver;
  static ui.Image? seqPearl;
  static ui.Image? seqRuby;

  // خرز مربع مكسور الحواف (A: 2.5x2.5mm, B: 4.0x4.0mm)
  static ui.Image? beadSqPearl;
  static ui.Image? beadSqGold;
  static ui.Image? beadSqBronze;
  static ui.Image? beadSqSilver;
  static ui.Image? beadSqCrystal;

  // خرز مستطيل مكسور الحواف (C: 5.0x2.5mm باتجاه الخيط)
  static ui.Image? beadRectPearl;
  static ui.Image? beadRectGold;
  static ui.Image? beadRectBronze;
  static ui.Image? beadRectSilver;
  static ui.Image? beadRectCrystal;

  static bool _ready = false;
  static Future<void>? _loadingFuture;

  static bool get isReady => _ready;

  static Future<void> ensureLoaded() {
    if (_ready) return Future.value();
    _loadingFuture ??= _loadAll();
    return _loadingFuture!;
  }

  static Future<void> _loadAll() async {
    seqGold = await _buildSequin(const [232, 180, 42], const [255, 250, 205], const [116, 74, 12]);
    seqBronze = await _buildSequin(const [176, 108, 48], const [250, 212, 168], const [72, 36, 10]);
    seqSilver = await _buildSequin(const [198, 206, 218], const [255, 255, 255], const [78, 86, 100]);
    seqPearl = await _buildSequin(const [240, 234, 224], const [255, 255, 252], const [142, 132, 122], iridescent: true);
    seqRuby = await _buildSequin(const [214, 34, 62], const [255, 205, 215], const [88, 10, 22]);

    beadSqPearl = await _buildChamferedBead(const [242, 236, 224], const [255, 255, 255], const [112, 102, 92], w: 128, h: 128);
    beadSqGold = await _buildChamferedBead(const [232, 178, 38], const [255, 250, 205], const [92, 56, 8], w: 128, h: 128);
    beadSqBronze = await _buildChamferedBead(const [172, 102, 46], const [252, 218, 178], const [58, 28, 6], w: 128, h: 128);
    beadSqSilver = await _buildChamferedBead(const [198, 206, 218], const [255, 255, 255], const [68, 76, 90], w: 128, h: 128);
    beadSqCrystal = await _buildChamferedBead(const [20, 168, 192], const [228, 254, 255], const [6, 56, 70], w: 128, h: 128);

    beadRectPearl = await _buildChamferedBead(const [242, 236, 224], const [255, 255, 255], const [112, 102, 92], w: 128, h: 54);
    beadRectGold = await _buildChamferedBead(const [232, 178, 38], const [255, 250, 205], const [92, 56, 8], w: 128, h: 54);
    beadRectBronze = await _buildChamferedBead(const [172, 102, 46], const [252, 218, 178], const [58, 28, 6], w: 128, h: 54);
    beadRectSilver = await _buildChamferedBead(const [198, 206, 218], const [255, 255, 255], const [68, 76, 90], w: 128, h: 54);
    beadRectCrystal = await _buildChamferedBead(const [20, 168, 192], const [228, 254, 255], const [6, 56, 70], w: 128, h: 54);

    _ready = true;
  }

  static Future<ui.Image> _buildSequin(
    List<int> baseRgb,
    List<int> hiRgb,
    List<int> shRgb, {
    bool iridescent = false,
    int size = 128,
  }) async {
    final Uint8List pixels = await Isolate.run(() {
      final out = Uint8List(size * size * 4);
      const double l1x = -0.58, l1y = -0.62, l1z = 0.53;
      const double h1x = -0.351, h1y = -0.375, h1z = 0.858;
      for (int py = 0; py < size; py++) {
        final double y = -1.2 + (2.4 * py / (size - 1));
        for (int px = 0; px < size; px++) {
          final double x = -1.2 + (2.4 * px / (size - 1));
          final double r = math.sqrt(x * x + y * y);
          final double th = math.atan2(y, x);
          final double rSh = math.sqrt((x - 0.07) * (x - 0.07) + (y - 0.09) * (y - 0.09));
          final double shA = ((1.0 - rSh) / 0.22).clamp(0.0, 1.0) * 0.26;
          final double discA = (((0.96 - r) / 0.03).clamp(0.0, 1.0)) * (((r - 0.28) / 0.03).clamp(0.0, 1.0));

          double cR = 0, cG = 0, cB = 0;
          if (discA > 0.001) {
            final double eOut = math.exp(-math.pow((r - 0.92) / 0.05, 2));
            final double eIn = math.exp(-math.pow((r - 0.30) / 0.04, 2));
            final double slope = 0.26 + 0.52 * eOut - 0.42 * eIn;
            final double nx = -slope * math.cos(th);
            final double ny = -slope * math.sin(th);
            final double nz = math.sqrt((1.0 - nx * nx - ny * ny).clamp(0.05, 1.0));
            final double ndotl = (nx * l1x + ny * l1y + nz * l1z).clamp(0.0, 1.0);
            final double ndoth = (nx * h1x + ny * h1y + nz * h1z).clamp(0.0, 1.0);
            final double aniso = math.pow(math.cos(2.0 * (th + 0.65)) * 0.5 + 0.5, 2.0).toDouble();
            final double spec = math.pow(ndoth, 11.0).toDouble();
            final double rimAo = 1.0 - 0.24 * math.exp(-math.pow((r - 0.95) / 0.025, 2)) - 0.30 * math.exp(-math.pow((r - 0.29) / 0.025, 2));

            cR = (shRgb[0] * (0.40 + 0.60 * (1.0 - ndotl)) + baseRgb[0] * (0.58 * ndotl + 0.48 * aniso) + hiRgb[0] * 0.78 * spec) * rimAo;
            cG = (shRgb[1] * (0.40 + 0.60 * (1.0 - ndotl)) + baseRgb[1] * (0.58 * ndotl + 0.48 * aniso) + hiRgb[1] * 0.78 * spec) * rimAo;
            cB = (shRgb[2] * (0.40 + 0.60 * (1.0 - ndotl)) + baseRgb[2] * (0.58 * ndotl + 0.48 * aniso) + hiRgb[2] * 0.78 * spec) * rimAo;
            if (iridescent) {
              cR += 16.0 * math.sin(th * 2.0 + r * 4.0);
              cG += 12.0 * math.sin(th * 2.0 + r * 4.0 + 2.1);
              cB += 18.0 * math.sin(th * 2.0 + r * 4.0 + 4.2);
            }
          }
          final double ad = discA * 0.96;
          final double oa = ad + shA * (1.0 - ad);
          final int o = (py * size + px) * 4;
          if (oa > 1e-4) {
            out[o] = ((cR * ad) / oa).clamp(0, 255).round();
            out[o + 1] = ((cG * ad) / oa).clamp(0, 255).round();
            out[o + 2] = ((cB * ad) / oa).clamp(0, 255).round();
            out[o + 3] = (oa * 255.0).clamp(0, 255).round();
          }
        }
      }
      return out;
    });
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixels, size, size, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  /// خرز مربّع أو مستطيل مكسور الحواف (Chamfered / Rounded Box SDF) بتدرّج لوني ناصع من المنتصف وغامق من الأطراف
  static Future<ui.Image> _buildChamferedBead(
    List<int> baseRgb,
    List<int> hiRgb,
    List<int> shRgb, {
    required int w,
    required int h,
  }) async {
    final Uint8List pixels = await Isolate.run(() {
      final out = Uint8List(w * h * 4);
      final double aspect = w / h; // 1.0 للمربّع، 2.0 للمستطيل (5×2.5 مم)
      final double hx = 0.88 * aspect;
      final double hy = 0.88;
      const double cornerR = 0.28; // كسر الحواف (Chamfered rounded corner)

      double sdRoundedBox(double px, double py, double bx, double by, double r) {
        final double qx = px.abs() - (bx - r);
        final double qy = py.abs() - (by - r);
        final double ox = math.max(qx, 0.0);
        final double oy = math.max(qy, 0.0);
        return math.sqrt(ox * ox + oy * oy) + math.min(math.max(qx, qy), 0.0) - r;
      }

      for (int py = 0; py < h; py++) {
        final double y = -1.18 + (2.36 * py / (h - 1));
        for (int px = 0; px < w; px++) {
          final double x = (-1.18 + (2.36 * px / (w - 1))) * aspect;

          // ظل خفيف ناعم تحت الخرزة
          final double dSh = sdRoundedBox(x - 0.07, y - 0.09, hx + 0.02, hy + 0.02, cornerR);
          final double shA = ((0.14 - dSh) / 0.22).clamp(0.0, 1.0) * 0.34;

          final double d = sdRoundedBox(x, y, hx, hy, cornerR);
          final double bodyA = ((-d) / 0.045).clamp(0.0, 1.0);

          double cR = 0, cG = 0, cB = 0;
          if (bodyA > 0.001) {
            // المسافة المعيّرة من المنتصف إلى الأطراف (0 = المركز الناصع، 1 = الأطراف الغامقة)
            final double nx = x / hx;
            final double ny = y / hy;
            final double centerDist = math.sqrt(nx * nx * 0.85 + ny * ny * 0.85).clamp(0.0, 1.0);
            // عامل السطوع: ناصع جداً في المنتصف ويتدرّج للظل الغامق عند الأطراف
            final double dome = math.pow(1.0 - centerDist, 0.72).toDouble();
            // شطفة حواف حادة قريبة من المحيط
            final double edgeDark = ((-d) / 0.22).clamp(0.0, 1.0);
            // بريق سطوع حريري ناصع في قلب الخرزة
            final double spec = math.exp(-((nx + 0.08) * (nx + 0.08) * 6.5 + (ny + 0.10) * (ny + 0.10) * 7.5));

            final double shadeT = (dome * 0.68 + edgeDark * 0.32).clamp(0.0, 1.0);
            cR = shRgb[0] * (1.0 - shadeT) + baseRgb[0] * shadeT + (hiRgb[0] - baseRgb[0]) * (0.45 * dome + 0.78 * spec);
            cG = shRgb[1] * (1.0 - shadeT) + baseRgb[1] * shadeT + (hiRgb[1] - baseRgb[1]) * (0.45 * dome + 0.78 * spec);
            cB = shRgb[2] * (1.0 - shadeT) + baseRgb[2] * shadeT + (hiRgb[2] - baseRgb[2]) * (0.45 * dome + 0.78 * spec);
          }

          final double oa = bodyA + shA * (1.0 - bodyA);
          final int o = (py * w + px) * 4;
          if (oa > 1e-4) {
            out[o] = ((cR * bodyA) / oa).clamp(0, 255).round();
            out[o + 1] = ((cG * bodyA) / oa).clamp(0, 255).round();
            out[o + 2] = ((cB * bodyA) / oa).clamp(0, 255).round();
            out[o + 3] = (oa * 255.0).clamp(0, 255).round();
          }
        }
      }
      return out;
    });
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixels, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  static ui.Image? sequinFor(int bucket, int decorTheme) {
    if (decorTheme == 1) {
      return bucket == 1 ? seqPearl : (bucket == 2 ? seqBronze : seqSilver);
    } else if (decorTheme == 2) {
      return bucket == 1 ? seqGold : seqPearl;
    } else if (decorTheme == 3) {
      return bucket == 0 ? seqRuby : (bucket == 1 ? seqGold : (bucket == 2 ? seqSilver : seqPearl));
    }
    return bucket == 1 ? seqGold : (bucket == 2 ? seqBronze : (bucket == 3 ? seqPearl : seqGold));
  }

  static ui.Image? sequinByFinish(int finish) {
    switch (finish) {
      case 0: return seqPearl;
      case 1: return seqGold;
      case 2: return seqSilver;
      case 3: return seqBronze;
      case 4: return seqRuby;
      default: return seqGold;
    }
  }

  static ui.Image? beadByFinish(int finish, bool isRect) {
    if (isRect) {
      switch (finish) {
        case 0: return beadRectPearl;
        case 1: return beadRectGold;
        case 2: return beadRectSilver;
        case 3: return beadRectBronze;
        case 4: return beadRectCrystal;
        default: return beadRectBronze;
      }
    }
    switch (finish) {
      case 0: return beadSqPearl;
      case 1: return beadSqGold;
      case 2: return beadSqSilver;
      case 3: return beadSqBronze;
      case 4: return beadSqCrystal;
      default: return beadSqPearl;
    }
  }

  static ui.Image? beadFor(int code, int decorTheme) {
    final bool isRectC = code == 3 || code == 4 || code == 7 || code == 8;
    if (decorTheme == 1) {
      if (isRectC) return beadRectSilver;
      return (code == 2 || code == 6) ? beadSqSilver : beadSqPearl;
    } else if (decorTheme == 2) {
      return isRectC ? beadRectPearl : beadSqPearl;
    } else if (decorTheme == 3) {
      if (isRectC) return beadRectGold;
      return (code == 2 || code == 6) ? beadSqCrystal : beadSqPearl;
    }
    if (isRectC) return beadRectBronze;
    return (code == 2 || code == 6) ? beadSqGold : beadSqPearl;
  }
}

/// المحرك المركزي الموحّد للرسم ثلاثي الأبعاد (3D ONLY):
/// - خيط مبروم حقيقي بعرض 0.41 مم وزاوية برمة 20° وتدرّج إضاءة من الظل عند نقطتَي نزول الإبرة إلى ذروة السطوع في المنتصف
/// - الترتر: A=3 مم، B=5 مم بخامات 256×256
/// - الخرز: A=2.5×2.5 مم مربع مكسور الحواف، B=4×4 مم مربع مكسور الحواف، C=5×2.5 مم مستطيل يدور باتجاه الخيط
class TarikUnifiedCanvasRenderer {
  /// رسم شبكة 1 سم × 1 سم حقيقية مرتبطة بمقياس التصميم (100 وحدة = 1 سم)
  static void drawCmGrid(
    Canvas canvas,
    Size size, {
    required double scale,
    required double originX,
    required double originY,
  }) {
    final double cmPx = TarikRenderSpecs.unitsPerCm * scale;
    final double halfCmPx = cmPx * 0.5;
    if (halfCmPx < 5.0) return;

    final Paint minorPaint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 0.7;
    final Paint majorPaint = Paint()
      ..color = const Color(0xFF94A3B8).withOpacity(0.55)
      ..strokeWidth = 1.1;
    final Paint axisPaint = Paint()
      ..color = const Color(0xFF64748B).withOpacity(0.50)
      ..strokeWidth = 1.3;

    final int minCol = ((-originX) / halfCmPx).floor() - 1;
    final int maxCol = ((size.width - originX) / halfCmPx).ceil() + 1;
    for (int c = minCol; c <= maxCol; c++) {
      final double x = originX + c * halfCmPx;
      final Paint p = (c == 0) ? axisPaint : ((c & 1) == 0 ? majorPaint : minorPaint);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }

    final int minRow = ((-originY) / halfCmPx).floor() - 1;
    final int maxRow = ((size.height - originY) / halfCmPx).ceil() + 1;
    for (int r = minRow; r <= maxRow; r++) {
      final double y = originY + r * halfCmPx;
      final Paint p = (r == 0) ? axisPaint : ((r & 1) == 0 ? majorPaint : minorPaint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }



  /// رسم التصميم المتجهي بالعرض ثلاثي الأبعاد الموحّد (3D Only) + خرز وترتر PBR
  static void paintDesign({
    required Canvas canvas,
    required VectorDesignData data,
    required double scale,
    required double offX,
    required double offY,
    bool is3D = true, // العرض 3D فقط في كامل التطبيق
    int decorTheme = 0,
    int startIndex = 0,
    int? stitchLimit,
    bool fastSimMode = false,
    Rect? visibleRect,
    double stroke2DPx = TarikRenderSpecs.stroke2DScreenPx,
  }) {
    final int nSt = (stitchLimit ?? data.stX.length).clamp(0, data.stX.length);
    final int sIdx = startIndex.clamp(0, nSt);
    if (nSt < 2 || sIdx >= nSt) return;
    final int loopStart = sIdx > 0 ? sIdx - 1 : 0;

    final int palLen = math.max(1, data.paletteArgb.length);
    final Float32List stX = data.stX;
    final Float32List stY = data.stY;
    final Uint8List stMove = data.stMove;
    final Uint8List stColor = data.stColor;

    const double maxSegSq = TarikRenderSpecs.maxStitchUnits3D * TarikRenderSpecs.maxStitchUnits3D;

    final double cullPad = visibleRect != null ? math.max(24.0, scale * 60.0) : 0.0;
    final double vLeft = visibleRect != null ? visibleRect.left - cullPad : -1e9;
    final double vRight = visibleRect != null ? visibleRect.right + cullPad : 1e9;
    final double vTop = visibleRect != null ? visibleRect.top - cullPad : -1e9;
    final double vBottom = visibleRect != null ? visibleRect.bottom + cullPad : 1e9;

    // ================== 3D موحّد: الخيط المبروم الحقيقي (0.41 مم، برمة 20°، تدرّج نقطتَي الإبرة) ==================
    final double tw = (scale * TarikRenderSpecs.threadWidthUnits3D).clamp(1.15, 28.0);

    int visCount = 0;
    if (!fastSimMode && tw >= 2.0) {
      double pSx = 0, pSy = 0;
      for (int i = loopStart; i < nSt; i++) {
        final double sx = stX[i] * scale + offX;
        final double sy = stY[i] * scale + offY;
        if (i > loopStart && stMove[i] == 0) {
          if (math.max(pSx, sx) >= vLeft &&
              math.min(pSx, sx) <= vRight &&
              math.max(pSy, sy) >= vTop &&
              math.min(pSy, sy) <= vBottom) {
            visCount++;
            if (visCount > 5500) break;
          }
        }
        pSx = sx;
        pSy = sy;
      }
    }

    final bool usePerStitchTwisted = !fastSimMode && tw >= 2.1 && visCount <= 5500;

    if (usePerStitchTwisted) {
      final bool drawTwistPlies = tw >= 2.8;
      final double pitchPx = math.max(4.0, TarikRenderSpecs.threadTwistPitchUnits * scale);
      final double shOff = (tw * 0.20).clamp(0.35, 3.2);
      const double lx = -0.7071, ly = -0.7071;

      final Paint shadowPaint = Paint()
        ..color = Colors.black.withOpacity(0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = tw * 1.04
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;

      final Paint bodyPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = tw
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;

      final Paint hiPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (tw * 0.24).clamp(0.45, 4.5)
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;

      final Paint twistShadowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (tw * 0.13).clamp(0.4, 2.4)
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;

      final Paint twistLightPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (tw * 0.12).clamp(0.35, 2.2)
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;

      double prevRx = 0.0, prevRy = 0.0;
      double prevSx = 0.0, prevSy = 0.0;
      int prevCol = -1;
      bool hasPrev = false;

      for (int i = loopStart; i < nSt; i++) {
        final int cIdx = stColor[i];
        final double rx = stX[i];
        final double ry = stY[i];
        final double sx = rx * scale + offX;
        final double sy = ry * scale + offY;

        bool isJump = stMove[i] != 0 || !hasPrev || cIdx != prevCol;
        if (!isJump) {
          final double dxR = rx - prevRx;
          final double dyR = ry - prevRy;
          if (dxR * dxR + dyR * dyR > maxSegSq) isJump = true;
        }

        if (!isJump &&
            math.max(prevSx, sx) >= vLeft &&
            math.min(prevSx, sx) <= vRight &&
            math.max(prevSy, sy) >= vTop &&
            math.min(prevSy, sy) <= vBottom) {
          final double dx = sx - prevSx;
          final double dy = sy - prevSy;
          final double segLen = math.sqrt(dx * dx + dy * dy);
          if (segLen >= 0.4) {
            final double ux = dx / segLen;
            final double uy = dy / segLen;
            final double nx = -uy;
            final double ny = ux;
            final double align = (nx * lx + ny * ly).abs();

            final Color baseColor = Color(data.paletteArgb[cIdx % palLen]);
            final Color darkEnd = Color.lerp(baseColor, Colors.black, 0.52) ?? baseColor;
            final Color midBody = Color.lerp(
                  Color.lerp(baseColor, Colors.black, 0.06) ?? baseColor,
                  Color.lerp(baseColor, Colors.white, 0.14) ?? baseColor,
                  align,
                ) ??
                baseColor;
            final Color peakCenter = Color.lerp(baseColor, Colors.white, 0.28 + 0.36 * align) ?? Colors.white;

            final Offset p0 = Offset(prevSx, prevSy);
            final Offset p1 = Offset(sx, sy);

            // 1) ظل ناعم تحت الغرزة
            canvas.drawLine(p0.translate(shOff, shOff), p1.translate(shOff, shOff), shadowPaint);

            // 2) جسم الخيط المتدرج من ظل نقطتَي نزول الإبرة إلى ذروة السطوع في المنتصف
            bodyPaint.shader = ui.Gradient.linear(
              p0,
              p1,
              [darkEnd, midBody, peakCenter, midBody, darkEnd],
              const [0.0, 0.19, 0.50, 0.81, 1.0],
            );
            canvas.drawLine(p0, p1, bodyPaint);

            // 3) خط لمعان الحرير الرفيع على الحافة المضيئة
            final double hiShift = tw * 0.17;
            final Offset h0 = Offset(prevSx + ux * (segLen * 0.15) - hiShift, prevSy + uy * (segLen * 0.15) - hiShift);
            final Offset h1 = Offset(sx - ux * (segLen * 0.15) - hiShift, sy - uy * (segLen * 0.15) - hiShift);
            hiPaint.shader = ui.Gradient.linear(
              h0,
              h1,
              [
                peakCenter.withOpacity(0.05),
                Colors.white.withOpacity(0.45 + 0.35 * align),
                peakCenter.withOpacity(0.05),
              ],
              const [0.0, 0.5, 1.0],
            );
            canvas.drawLine(h0, h1, hiPaint);

            // 4) برمة الخيط الحلزونية المفتوحة بزاوية 20° (طويلة وانسيابية على طول الغرزة)
            if (drawTwistPlies && segLen > pitchPx * 0.55) {
              twistShadowPaint.color = darkEnd.withOpacity(0.48);
              twistLightPaint.color = peakCenter.withOpacity(0.46);
              final double halfW = tw * 0.42;
              final double slant = math.min(
                segLen * 0.32,
                halfW / math.tan(TarikRenderSpecs.threadTwistAngleRad), // زاوية 20° المفتوحة
              );
              final int plies = (segLen / pitchPx).floor().clamp(1, 18);
              for (int k = 1; k <= plies; k++) {
                final double t = k / (plies + 1);
                final double cx = prevSx + dx * t;
                final double cy = prevSy + dy * t;
                final Offset a = Offset(cx - nx * halfW - ux * slant, cy - ny * halfW - uy * slant);
                final Offset b = Offset(cx + nx * halfW + ux * slant, cy + ny * halfW + uy * slant);
                canvas.drawLine(a, b, twistShadowPaint);
                canvas.drawLine(
                  a.translate(ux * (pitchPx * 0.18), uy * (pitchPx * 0.18)),
                  b.translate(ux * (pitchPx * 0.18), uy * (pitchPx * 0.18)),
                  twistLightPaint,
                );
              }
            }
          }
        }

        prevRx = rx;
        prevRy = ry;
        prevSx = sx;
        prevSy = sy;
        prevCol = cIdx;
        hasPrev = true;
      }
    } else {
      // النظرة البعيدة الكاملة السريعة للتصاميم الضخمة (8 حاويات إضاءة حريرية ثلاثية الأبعاد 0.41 مم)
      const double lx = -0.7071, ly = -0.7071;
      List<Path> angleBuckets = List.generate(8, (_) => Path());
      List<bool> bucketUsed = List.filled(8, false);
      Path fullColorPath = Path();
      bool hasAnySeg = false;
      int activeColorIdx = -1;
      double prevRx = 0.0, prevRy = 0.0;
      double prevSx = 0.0, prevSy = 0.0;
      bool hasPrev = false;

      void flush3DColor() {
        if (!hasAnySeg || activeColorIdx < 0) return;
        final Color baseColor = Color(data.paletteArgb[activeColorIdx % palLen]);
        final double shOff = (tw * 0.24).clamp(0.25, 1.2);
        final double hiOff = (tw * 0.15).clamp(0.16, 0.7);

        canvas.save();
        canvas.translate(shOff, shOff);
        canvas.drawPath(
          fullColorPath,
          Paint()
            ..color = Colors.black.withOpacity(0.16)
            ..style = PaintingStyle.stroke
            ..strokeWidth = tw * 1.05
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true,
        );
        canvas.restore();

        canvas.drawPath(
          fullColorPath,
          Paint()
            ..color = Color.lerp(baseColor, Colors.black, 0.28) ?? baseColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = tw
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true,
        );

        for (int b = 0; b < 8; b++) {
          if (!bucketUsed[b]) continue;
          final double midAng = (b + 0.5) * (math.pi / 8.0);
          final double nx = -math.sin(midAng);
          final double ny = math.cos(midAng);
          final double align = (nx * lx + ny * ly).abs();
          final Color bodyCol = Color.lerp(
                Color.lerp(baseColor, Colors.black, 0.08) ?? baseColor,
                Color.lerp(baseColor, Colors.white, 0.18) ?? baseColor,
                align,
              ) ??
              baseColor;
          final Color hiCol = (Color.lerp(baseColor, Colors.white, 0.36 + 0.46 * align) ?? Colors.white)
              .withOpacity(0.45 + 0.38 * align);

          canvas.drawPath(
            angleBuckets[b],
            Paint()
              ..color = bodyCol
              ..style = PaintingStyle.stroke
              ..strokeWidth = tw * 0.78
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..isAntiAlias = true,
          );

          canvas.save();
          canvas.translate(-hiOff, -hiOff);
          canvas.drawPath(
            angleBuckets[b],
            Paint()
              ..color = hiCol
              ..style = PaintingStyle.stroke
              ..strokeWidth = (tw * 0.24).clamp(0.24, 1.05)
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..isAntiAlias = true,
          );
          canvas.restore();
        }

        angleBuckets = List.generate(8, (_) => Path());
        bucketUsed = List.filled(8, false);
        fullColorPath = Path();
        hasAnySeg = false;
      }

      for (int i = loopStart; i < nSt; i++) {
        final int cIdx = stColor[i];
        if (cIdx != activeColorIdx) {
          flush3DColor();
          activeColorIdx = cIdx;
          hasPrev = false;
        }
        final double rx = stX[i];
        final double ry = stY[i];
        final double sx = rx * scale + offX;
        final double sy = ry * scale + offY;

        bool isJump = stMove[i] != 0 || !hasPrev;
        if (!isJump) {
          final double dx = rx - prevRx;
          final double dy = ry - prevRy;
          if (dx * dx + dy * dy > maxSegSq) isJump = true;
        }

        if (!isJump &&
            math.max(prevSx, sx) >= vLeft &&
            math.min(prevSx, sx) <= vRight &&
            math.max(prevSy, sy) >= vTop &&
            math.min(prevSy, sy) <= vBottom) {
          fullColorPath.moveTo(prevSx, prevSy);
          fullColorPath.lineTo(sx, sy);
          double ang = math.atan2(sy - prevSy, sx - prevSx);
          if (ang < 0) ang += math.pi;
          final int b = ((ang / math.pi) * 8.0).floor().clamp(0, 7);
          angleBuckets[b].moveTo(prevSx, prevSy);
          angleBuckets[b].lineTo(sx, sy);
          bucketUsed[b] = true;
          hasAnySeg = true;
        }
        prevRx = rx;
        prevRy = ry;
        prevSx = sx;
        prevSy = sy;
        hasPrev = true;
      }
      flush3DColor();
    }

    // ================== رسم الترتر (A=3 مم، B=5 مم) والخرز (A=2.5×2.5، B=4×4، C=6×2.5 باتجاه الخيط) بتزامن فوري O(1) ==================
    final bool isPartialSim = (stitchLimit != null && nSt < data.stX.length) || sIdx > 0;
    final TarikDesignSpatialIndex? spatialIdx =
        (data.seqX.isNotEmpty || data.beadX.isNotEmpty) ? TarikDesignSpatialIndex.of(data) : null;

    final TarikMachineDeviceProfile activeProfile = TarikMachineDeviceManager.current;
    final bool usePerChannelFinish = activeProfile.useCustomFinishes || decorTheme == 0;

    void drawBeadSprite(double sx, double sy, double ang, TarikDeviceChannelConfig cfg, Paint spritePaint, int fallbackCode) {
      final bool isRect = cfg.sizeCode == 2 || cfg.sizeCode == 3;
      final ui.Image? sp = usePerChannelFinish
          ? TarikProPbrSprites.beadByFinish(cfg.finish, isRect)
          : TarikProPbrSprites.beadFor(isRect ? 3 : (cfg.sizeCode == 1 ? 2 : fallbackCode), decorTheme);
      if (sp == null) return;
      if (isRect) {
        final double lenUnits = cfg.sizeCode == 2 ? 50.0 : TarikRenderSpecs.beadCLenUnits; // 5×2.5 أو 6×2.5 مم
        final double wPx = (lenUnits * scale * 1.24).clamp(5.0, 280.0);
        final double hPx = (TarikRenderSpecs.beadCHeightUnits * scale * 1.24).clamp(3.0, 140.0);
        canvas.save();
        canvas.translate(sx, sy);
        canvas.rotate(ang);
        canvas.drawImageRect(
          sp,
          Rect.fromLTWH(0, 0, sp.width.toDouble(), sp.height.toDouble()),
          Rect.fromCenter(center: Offset.zero, width: wPx, height: hPx),
          spritePaint,
        );
        canvas.restore();
      } else {
        final double units = cfg.sizeCode == 1 ? TarikRenderSpecs.beadBDiamUnits : TarikRenderSpecs.beadADiamUnits;
        final double dPx = (units * scale * 1.24).clamp(3.2, 220.0);
        canvas.drawImageRect(
          sp,
          Rect.fromLTWH(0, 0, sp.width.toDouble(), sp.height.toDouble()),
          Rect.fromCenter(center: Offset(sx, sy), width: dPx, height: dPx),
          spritePaint,
        );
      }
    }

    void drawSequinSprite(double sx, double sy, TarikDeviceChannelConfig cfg, Paint spritePaint, int fallbackBucket) {
      final double diamUnits = cfg.sizeCode == 1 ? 50.0 : 30.0; // 5 مم أو 3 مم
      final double dPx = (diamUnits * scale * 1.25).clamp(3.8, 260.0);
      final ui.Image? sp = usePerChannelFinish
          ? TarikProPbrSprites.sequinByFinish(cfg.finish)
          : TarikProPbrSprites.sequinFor(fallbackBucket, decorTheme);
      if (sp != null) {
        canvas.drawImageRect(
          sp,
          Rect.fromLTWH(0, 0, sp.width.toDouble(), sp.height.toDouble()),
          Rect.fromCenter(center: Offset(sx, sy), width: dPx, height: dPx),
          spritePaint,
        );
      }
    }

    if (data.seqX.isNotEmpty && spatialIdx != null) {
      final spritePaint = Paint()..filterQuality = fastSimMode ? FilterQuality.low : FilterQuality.medium;
      final Int32List sIdxArr = spatialIdx.seqStitchIdx;
      for (int i = 0; i < data.seqX.length; i++) {
        if (isPartialSim && (sIdxArr[i] < sIdx || sIdxArr[i] >= nSt)) continue;
        final double sx = data.seqX[i] * scale + offX;
        final double sy = data.seqY[i] * scale + offY;
        if (sx < vLeft || sx > vRight || sy < vTop || sy > vBottom) continue;

        final int code = data.seqCode[i];
        int normCode = code;
        if (code == 6) normCode = 2;
        else if (code == 16) normCode = 3;
        else if (code == 32) normCode = 4;
        final TarikDeviceChannelConfig cfg = activeProfile.resolveSequinConfig(normCode);
        if (!cfg.visible || cfg.kind == 0) continue;
        if (cfg.kind == 2) {
          drawBeadSprite(sx, sy, 0.0, cfg, spritePaint, normCode);
        } else {
          drawSequinSprite(sx, sy, cfg, spritePaint, (normCode - 1).clamp(0, 3));
        }
      }
    }

    if (data.beadX.isNotEmpty && spatialIdx != null) {
      final spritePaint = Paint()..filterQuality = fastSimMode ? FilterQuality.low : FilterQuality.medium;
      final Int32List bIdxArr = spatialIdx.beadStitchIdx;
      final Float32List bAngArr = spatialIdx.beadAngles;
      for (int i = 0; i < data.beadX.length; i++) {
        if (isPartialSim && (bIdxArr[i] < sIdx || bIdxArr[i] >= nSt)) continue;
        final double sx = data.beadX[i] * scale + offX;
        final double sy = data.beadY[i] * scale + offY;
        if (sx < vLeft || sx > vRight || sy < vTop || sy > vBottom) continue;

        final int code = data.beadCode[i];
        final TarikDeviceChannelConfig cfg = activeProfile.resolveBeadConfig(code);
        if (!cfg.visible || cfg.kind == 0) continue;
        if (cfg.kind == 1) {
          drawSequinSprite(sx, sy, cfg, spritePaint, (code - 1).clamp(0, 3));
        } else {
          drawBeadSprite(sx, sy, bAngArr[i], cfg, spritePaint, code);
        }
      }
    }
  }
}

/// مولّد صور المعاينة (يستخدم TarikUnifiedCanvasRenderer بالعرض ثلاثي الأبعاد الموحّد 3D Only)
class TarikPro3DRenderer {
  static Future<Uint8List?> renderHighResPreview(
    String filePath, {
    double maxCanvas = 2200.0,
    bool is3D = true,
    bool transparentBg = true,
    int decorTheme = 0,
  }) async {
    try {
      final low = filePath.toLowerCase();
      VectorDesignData? vec;
      if (low.endsWith('.tbf')) {
        vec = await TarikProTbfParser.loadVector(filePath);
      } else if (low.endsWith('.dhe') || low.endsWith('.dha')) {
        vec = await TarikProDahaoParser.loadVector(filePath);
      }
      vec ??= await VectorDesignLoader.load(filePath);
      if (vec == null || vec.stX.length < 2) return null;
      return await renderVectorToPng(
        vec,
        maxCanvas: maxCanvas,
        is3D: true,
        transparentBg: transparentBg,
        decorTheme: decorTheme,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> renderVectorToPng(
    VectorDesignData data, {
    double maxCanvas = 2200.0,
    bool is3D = true,
    bool transparentBg = true,
    int decorTheme = 0,
  }) async {
    if (!data.hasBounds || data.stX.length < 2) return null;
    final double rawW = data.maxX - data.minX;
    final double rawH = data.maxY - data.minY;
    if (!rawW.isFinite || !rawH.isFinite || rawW <= 0 || rawH <= 0) return null;

    if (data.seqX.isNotEmpty || data.beadX.isNotEmpty) {
      await TarikProPbrSprites.ensureLoaded();
    }

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

    TarikUnifiedCanvasRenderer.paintDesign(
      canvas: canvas,
      data: data,
      scale: scale,
      offX: -data.minX * scale + pad,
      offY: -data.minY * scale + pad,
      is3D: true,
      decorTheme: decorTheme,
    );

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
        final int rawDv = devArr[idx];
        final int dt = rawDv & 0x0F;
        if (((rawDv & 0xC0) == 0 && dt >= 1 && dt <= 4) || ((rawDv & 0x40) != 0 && dt >= 1 && dt <= 8)) {
          rSeq++;
        } else if (((rawDv & 0xC0) == 0 && dt >= 5 && dt <= 7) || ((rawDv & 0x80) != 0 && dt >= 1 && dt <= 8)) {
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
            if ((dv & 0x40) != 0 && dt >= 1 && dt <= 8) {
              seqX.add(rx);
              seqY.add(ry);
              seqCode.add(dt);
            } else if ((dv & 0x80) != 0 && dt >= 1 && dt <= 8) {
              beadX.add(rx);
              beadY.add(ry);
              beadCode.add(dt);
            } else if ((dv & 0xC0) == 0 && dt >= 1 && dt <= 4) {
              seqX.add(rx);
              seqY.add(ry);
              seqCode.add(dt);
            } else if ((dv & 0xC0) == 0 && dt >= 5 && dt <= 7) {
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

    final beadX = _ProFloat32Buf(64);
    final beadY = _ProFloat32Buf(64);
    final beadCode = _ProUint8Buf(64);
    int prevDx = 0, prevDy = 0;

    for (int i = 0x600; i + 2 < bytes.length; i += 3) {
      final int dx = _s8(bytes[i]);
      final int dy = _s8(bytes[i + 1]);
      final int ctrl = bytes[i + 2];

      if (ctrl == 0x8F) break;
      final double prevPx = x.toDouble();
      final double prevPy = -y.toDouble();
      x += dx;
      y += dy;

      if (ctrl == 0x4D || ctrl == 0x88) {
        // تفعيل / إيقاف جهاز التزيين في Tajima TBF
        continue;
      } else if (ctrl == 0x81 || (ctrl >= 0x40 && ctrl <= 0x4F)) {
        // تغيير لون / إبرة حقيقي (0x81 في emCAD TBF و 0x40..0x4F)
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
      } else if (ctrl == 0x90 || ctrl == 0x82 || ctrl == 0x84) {
        // قفزة حرة (Jump — 0x90 في emCAD TBF)
        jumpCount++;
        needMove = true;
      } else if (ctrl == 0x89 || ctrl == 0x69 || ctrl == 0x87 || ctrl == 0x91) {
        final double px = x.toDouble();
        final double py = -y.toDouble();
        hasAnyDev = true;
        int devTag = 1;
        if (ctrl == 0x69 && (dx * prevDx + dy * prevDy) < -120 && dx.abs() <= 35 && dy.abs() <= 35) {
          // تراجع قصير مع 0x69 في TBF = خرز A (1.7مم) أو B (2.5مم)
          final int bc = math.sqrt(dx * dx + dy * dy) > 21.0 ? 2 : 1;
          beadX.add((prevPx + px) * 0.5);
          beadY.add((prevPy + py) * 0.5);
          beadCode.add(bc);
          devTag = 4 + bc;
        } else {
          final int sc = ctrl == 0x69 ? 2 : 1; // 0x89=ترتر A(3مم)، 0x69=ترتر B(5مم)
          seqX.add(px);
          seqY.add(py);
          seqCode.add(sc);
          devTag = sc;
        }
        stX.add(px);
        stY.add(py);
        stMove.add(needMove ? 1 : 0);
        stColor.add(colorIdx);
        stDev.add(devTag);
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
        if (dx != 0 || dy != 0) {
          prevDx = dx;
          prevDy = dy;
        }
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
      beadX: beadX.finish(),
      beadY: beadY.finish(),
      beadCode: beadCode.finish(),
      paletteArgb: _palette,
      stitches: stitchCount,
      colorCount: colorCount,
      stopsCount: colorCount > 1 ? colorCount - 1 : 0,
      jumpsCount: jumpCount,
      sequinsCount: seqX.length,
      beadsCount: beadX.length,
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
      is3D: true,
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


// ============================================================================
// TARIK EMB PRO v6.8 — 8-CHANNEL DAHAO CONVERTER (DST <-> DHA <-> DHE)
// - قارئ DST ذكي يدعم قنوات emCAD 2.6 الثماني (A..H مع 8 Sequin Patch)
// - مشفّر DHE / DHA أصلي كامل (3DES + Ring Cipher + 20-Color Header + Sec1 + Sec6)
// - مصدّر موحّد يدعم DHE و DHA و DST وجميع الصيغ الأخرى بقواعد أجهزة الماكينة (A–H)
// ============================================================================

/// قارئ ملفات .DST المعاير بقاعدة أجهزة الماكينة الثماني (A – H):
/// يدعم كلاً من ملفات emCAD 2.6 القياسية وملفات 8 Sequin Patch (A=1, B=2, C=4, D=8, E=7/ABC, F=11/ABD, G=13/ACD, H=14/BCD)
class TarikProDstDeviceParser {
  static final Int32List _defaultPalette = Int32List.fromList(const [
    0xFF009900, 0xFF0000FF, 0xFFFF0000, 0xFFFFFF00, 0xFF00FFFF,
    0xFFFF00FF, 0xFF00FF00, 0xFF000099, 0xFF990000, 0xFFFF9933,
    0xFF9900CC, 0xFF996633, 0xFFB0BEC5, 0xFF000000, 0xFFFF7ECC,
    0xFFFFCC7E, 0xFF66FFCC, 0xFF666666, 0xFF999966, 0xFF7E7EFF,
  ]);

  /// تحويل عدد قفزات DST المتتالية داخل وضع 0x43 إلى رقم قناة A..H (0..7)
  static int _pulsesToChannel0To7(int pulses) {
    if (pulses <= 1) return 0; // A
    if (pulses == 2) return 1; // B
    if (pulses == 3 || pulses == 4) return 2; // C
    if (pulses == 5 || pulses == 6 || pulses == 7) return 4; // E (ABC في 8-Sequin Patch)
    if (pulses == 8) return 3; // D
    if (pulses == 9 || pulses == 10 || pulses == 11) return 5; // F (ABD)
    if (pulses == 12 || pulses == 13) return 6; // G (ACD)
    return 7; // H (BCD)
  }

  static VectorDesignData? decodeSync(Uint8List data, TarikMachineDeviceProfile profile) {
    if (data.length <= 515) return null;

    final stX = _ProFloat32Buf(8192);
    final stY = _ProFloat32Buf(8192);
    final stMove = _ProUint8Buf(8192);
    final stColor = _ProUint8Buf(8192);
    final stDev = _ProUint8Buf(8192);

    final seqX = _ProFloat32Buf(256);
    final seqY = _ProFloat32Buf(256);
    final seqCode = _ProUint8Buf(256);

    final beadX = _ProFloat32Buf(256);
    final beadY = _ProFloat32Buf(256);
    final beadCode = _ProUint8Buf(256);

    double cx = 0.0, cy = 0.0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int col = 0;
    int colorCount = 1;
    bool hasStitchesInCol = false;
    bool needMove = true;
    bool inSeqMode = false;
    int pulseCount = 0;
    double pulseOriginX = 0.0, pulseOriginY = 0.0;
    double ljx = 0.0, ljy = 0.0;
    int jumpsCount = 0;

    void trackPt(double x, double y) {
      if (!hasBounds) {
        minX = maxX = x;
        minY = maxY = y;
        hasBounds = true;
      } else {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }

    void emitStitch(double x, double y, bool isMove, int devTag) {
      stX.add(x);
      stY.add(y);
      stMove.add(isMove ? 1 : 0);
      stColor.add(col);
      stDev.add(devTag);
      if (isMove) jumpsCount++;
      hasStitchesInCol = true;
      trackPt(x, y);
    }

    void flushPulse() {
      if (pulseCount <= 0) return;
      final TarikMachineDeviceProfile activeP = profile.effectiveForColor(col);
      final int chIdx = _pulsesToChannel0To7(pulseCount);
      final TarikDeviceChannelConfig chCfg = activeP.channels[chIdx];
      int devTag = 0;

      if (chCfg.kind == 2) {
        // خرز -> ترتيب الخرز ضمن القنوات المفعّلة للخرز (1..8)
        int beadOrdinal = 1;
        for (int i = 0; i < chIdx; i++) {
          if (activeP.channels[i].kind == 2) beadOrdinal++;
        }
        final double mx = (pulseOriginX + ljx) * 0.5;
        final double my = (pulseOriginY + ljy) * 0.5;
        beadX.add(mx);
        beadY.add(my);
        beadCode.add(beadOrdinal.clamp(1, 8));
        devTag = beadOrdinal <= 3 ? (4 + beadOrdinal) : (0x80 | beadOrdinal);
      } else if (chCfg.kind == 1) {
        // ترتر -> ترتيب الترتر ضمن القنوات المفعّلة للترتر (1..8)
        int seqOrdinal = 1;
        for (int i = 0; i < chIdx; i++) {
          if (activeP.channels[i].kind == 1) seqOrdinal++;
        }
        seqX.add(ljx);
        seqY.add(ljy);
        seqCode.add(seqOrdinal.clamp(1, 8));
        devTag = seqOrdinal <= 4 ? seqOrdinal : (0x40 | seqOrdinal);
      }

      emitStitch(ljx, ljy, needMove, devTag);
      needMove = false;
      pulseCount = 0;
    }

    for (int off = 512; off + 2 < data.length; off += 3) {
      final int b0 = data[off];
      final int b1 = data[off + 1];
      final int b2 = data[off + 2];
      if (b2 == 0xF3) break;

      int dx = 0, dy = 0;
      if ((b0 & 0x01) != 0) dx += 1;
      if ((b0 & 0x02) != 0) dx -= 1;
      if ((b0 & 0x04) != 0) dx += 9;
      if ((b0 & 0x08) != 0) dx -= 9;
      if ((b0 & 0x80) != 0) dy += 1;
      if ((b0 & 0x40) != 0) dy -= 1;
      if ((b0 & 0x20) != 0) dy += 9;
      if ((b0 & 0x10) != 0) dy -= 9;

      if ((b1 & 0x01) != 0) dx += 3;
      if ((b1 & 0x02) != 0) dx -= 3;
      if ((b1 & 0x04) != 0) dx += 27;
      if ((b1 & 0x08) != 0) dx -= 27;
      if ((b1 & 0x80) != 0) dy += 3;
      if ((b1 & 0x40) != 0) dy -= 3;
      if ((b1 & 0x20) != 0) dy += 27;
      if ((b1 & 0x10) != 0) dy -= 27;

      if ((b2 & 0x04) != 0) dx += 81;
      if ((b2 & 0x08) != 0) dx -= 81;
      if ((b2 & 0x20) != 0) dy += 81;
      if ((b2 & 0x10) != 0) dy -= 81;

      if (b2 == 0x43) {
        flushPulse();
        inSeqMode = !inSeqMode;
        continue;
      }

      if ((b2 & 0xC0) == 0xC0) {
        flushPulse();
        inSeqMode = false;
        if (hasStitchesInCol) {
          col = (col + 1) % _defaultPalette.length;
          colorCount++;
          hasStitchesInCol = false;
        }
        needMove = true;
        continue;
      }

      final bool isJump = (b2 & 0x80) != 0;
      if (isJump) {
        if (inSeqMode) {
          if (dx.abs() > 95 || dy.abs() > 95) {
            flushPulse();
            cx += dx;
            cy -= dy;
            needMove = true;
          } else {
            if ((dx != 0 || dy != 0) && pulseCount > 0) {
              flushPulse();
            }
            if (pulseCount == 0) {
              pulseOriginX = cx;
              pulseOriginY = cy;
            }
            cx += dx;
            cy -= dy;
            pulseCount++;
            ljx = cx;
            ljy = cy;
          }
        } else {
          cx += dx;
          cy -= dy;
          needMove = true;
        }
      } else {
        flushPulse();
        cx += dx;
        cy -= dy;
        emitStitch(cx, cy, needMove, 0);
        needMove = false;
      }
    }

    flushPulse();
    if (stX.length < 2) return null;

    return VectorDesignData(
      stX: stX.finish(),
      stY: stY.finish(),
      stMove: stMove.finish(),
      stColor: stColor.finish(),
      stDev: (seqX.length > 0 || beadX.length > 0) ? stDev.finish() : null,
      seqX: seqX.finish(),
      seqY: seqY.finish(),
      seqCode: seqCode.finish(),
      beadX: beadX.finish(),
      beadY: beadY.finish(),
      beadCode: beadCode.finish(),
      paletteArgb: _defaultPalette,
      stitches: stX.length,
      colorCount: colorCount,
      stopsCount: colorCount > 1 ? colorCount - 1 : 0,
      jumpsCount: jumpsCount,
      sequinsCount: seqX.length,
      beadsCount: beadX.length,
      trimsCount: 0,
      minX: hasBounds ? minX : 0.0,
      maxX: hasBounds ? maxX : 0.0,
      minY: hasBounds ? minY : 0.0,
      maxY: hasBounds ? maxY : 0.0,
      hasBounds: hasBounds,
      machineType: 'Tajima (DST • ${profile.label(false)})',
    );
  }

  static Future<VectorDesignData?> loadVector(
    String filePath, {
    TarikMachineDeviceProfile? profile,
  }) async {
    try {
      final f = File(filePath);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      final p = profile ?? TarikMachineDeviceManager.current;
      return await Isolate.run(() => decodeSync(bytes, p));
    } catch (_) {
      return null;
    }
  }
}

/// مشفّر ومصدّر داهاو الأصلي الكامل (.DHE و .DHA) بدقة emCAD 2.10 و OutputDHE.exe:
/// - يكتب ترويسة 20 لوناً حقيقية + جدول الأقسام مشفّراً بـ 3DES (مفتاح DHE أو DHA)
/// - يشفّر القسم 1 (تسلسل الألوان) والقسم 2 والقسم 6 (الغرز + أوامر الخرز 0xD7 0A والترتر 0xD7 06 لـ 8 قنوات A–H)
class TarikProDahaoEncoder {
  static const List<int> _stdEmcadRgb = [
    0x009900, 0x0000FF, 0xFF0000, 0xFFFF00, 0x00FFFF,
    0xFF00FF, 0x00FF00, 0x000099, 0x990000, 0xFF9933,
    0x9900CC, 0x996633, 0xFFFFFF, 0x000000, 0xFF7ECC,
    0xFFCC7E, 0x66FFCC, 0x666666, 0x999966, 0x7E7EFF,
  ];

  static Uint8List encode(
    VectorDesignData vec, {
    required bool asDhe,
    TarikMachineDeviceProfile? profile,
  }) {
    final TarikMachineDeviceProfile activeProf = profile ?? TarikMachineDeviceManager.current;
    final int n = vec.stX.length;
    if (n < 2) return Uint8List(0);

    // 1) بناء لوحة الألوان (20 لوناً في الترويسة) وتسلسل الألوان في القسم 1
    final List<int> pal20 = List<int>.from(_stdEmcadRgb);
    for (int i = 0; i < math.min(20, vec.paletteArgb.length); i++) {
      pal20[i] = vec.paletteArgb[i] & 0xFFFFFF;
    }

    final List<int> colorSeq = [];
    int lastSeenCol = -1;
    for (int i = 0; i < n; i++) {
      final int c = vec.stColor[i] % 20;
      if (c != lastSeenCol) {
        colorSeq.add(c + 1); // 1-based color index
        lastSeenCol = c;
      }
    }
    if (colorSeq.isEmpty) colorSeq.add(1);

    // 2) بناء بايتات القسم 6 (غرز داهاو ثلاثية البايت + أوامر 0xD7 0A / 0xD7 06)
    final sec6Buf = BytesBuilder(copy: false);
    final Uint8List? stDev = vec.stDev;
    final TarikDesignSpatialIndex? spatial =
        (vec.seqX.isNotEmpty || vec.beadX.isNotEmpty) ? TarikDesignSpatialIndex.of(vec) : null;

    // ربط مباشر لرقم الغرزة بأوامر الخرز والترتر لضمان عدم ضياع أي قطعة حتى لو لم يكن stDev مكتملاً
    final Map<int, int> seqAtStitch = {};
    final Map<int, int> beadAtStitch = {};
    if (spatial != null) {
      for (int i = 0; i < vec.seqX.length; i++) {
        seqAtStitch[spatial.seqStitchIdx[i]] = vec.seqCode[i];
      }
      for (int i = 0; i < vec.beadX.length; i++) {
        beadAtStitch[spatial.beadStitchIdx[i]] = vec.beadCode[i];
      }
    }

    int curX = 0, curY = 0;
    int activeColor = vec.stColor[0];
    bool inDevMode = false;

    void emitRecord(int cmd, int b1, int b2) {
      sec6Buf.add([cmd & 0xFF, b1 & 0xFF, b2 & 0xFF]);
    }

    void emitMoveSteps(int dx, int dy, bool isJump) {
      int remX = dx;
      int remY = dy;
      while (remX.abs() > 127 || remY.abs() > 127) {
        final int sx = remX.clamp(-127, 127);
        final int sy = remY.clamp(-127, 127);
        int cmd = 0x81;
        if (sy < 0) cmd |= 0x40;
        if (sx < 0) cmd |= 0x20;
        emitRecord(cmd, sy.abs(), sx.abs());
        curX += sx;
        curY += sy;
        remX -= sx;
        remY -= sy;
      }
      int cmd = isJump ? 0x81 : 0x80;
      if (remY < 0) cmd |= 0x40;
      if (remX < 0) cmd |= 0x20;
      emitRecord(cmd, remY.abs(), remX.abs());
      curX += remX;
      curY += remY;
    }

    // بداية التصميم
    emitRecord(0x81, 0, 0);

    for (int i = 0; i < n; i++) {
      final int tx = vec.stX[i].round();
      final int ty = (-vec.stY[i]).round(); // Dahao Y للأعلى موجب
      final int c = vec.stColor[i];

      if (i > 0 && c != activeColor) {
        if (inDevMode) {
          emitRecord(0xD7, 0x00, 0x00);
          inDevMode = false;
        }
        // كود تغيير اللون في داهاو (0x8B..0x9F)
        emitRecord(0x8B + (c % 12), 0x00, 0x00);
        activeColor = c;
      }

      // فحص هل توجد خرزة أو ترترة على هذه الغرزة
      int? seqOrd = seqAtStitch[i];
      int? beadOrd = beadAtStitch[i];
      if (seqOrd == null && beadOrd == null && stDev != null && i < stDev.length) {
        final int dv = stDev[i];
        if ((dv & 0x80) != 0) {
          beadOrd = dv & 0x0F;
        } else if ((dv & 0x40) != 0) {
          seqOrd = dv & 0x0F;
        } else {
          final int low = dv & 0x0F;
          if (low >= 1 && low <= 4) seqOrd = low;
          else if (low >= 5 && low <= 7) beadOrd = low - 4;
        }
      }

      final TarikMachineDeviceProfile colProf = activeProf.effectiveForColor(c);
      int emitKind = 0; // 0=none, 1=sequin, 2=bead
      int emitChannelIdx = 0; // 0..7 (A..H)

      if (beadOrd != null) {
        final cfg = colProf.resolveBeadConfig(beadOrd);
        if (cfg.visible && cfg.kind != 0) {
          emitKind = cfg.kind;
          emitChannelIdx = (beadOrd - 1).clamp(0, 7);
        }
      } else if (seqOrd != null) {
        final cfg = colProf.resolveSequinConfig(seqOrd);
        if (cfg.visible && cfg.kind != 0) {
          emitKind = cfg.kind;
          emitChannelIdx = (seqOrd - 1).clamp(0, 7);
        }
      }

      final int dx = tx - curX;
      final int dy = ty - curY;
      final bool isMove = vec.stMove[i] != 0;

      if (emitKind == 0 && inDevMode && isMove && (dx.abs() > 95 || dy.abs() > 95)) {
        emitRecord(0xD7, 0x00, 0x00);
        inDevMode = false;
      }

      if (emitKind == 2) {
        // أمر خرز صريح في قناة 0xD7 (0x0A, 1<<ch) — مدعوم في emCAD 2.10 DHE و DHA!
        if (!inDevMode) {
          emitMoveSteps(dx, dy, isMove);
          emitRecord(0xD7, 0x00, 0x00);
          inDevMode = true;
        } else {
          emitMoveSteps(dx, dy, false);
        }
        emitRecord(0xD7, 0x0A, 1 << emitChannelIdx);
      } else if (emitKind == 1) {
        // أمر ترتر
        if (!inDevMode) {
          emitMoveSteps(dx, dy, isMove);
          emitRecord(0xD7, 0x00, 0x00);
          inDevMode = true;
        } else if (asDhe) {
          emitMoveSteps(dx, dy, false);
        }
        if (asDhe) {
          emitRecord(0xD7, 0x06, 1 << emitChannelIdx);
        } else {
          // في DHA (2.10) الترتر A=قفزة 1، B=قفزتان (الثانية صفرية) باستخدام الإزاحة المتبقية الفعلية
          emitMoveSteps(tx - curX, ty - curY, true);
          if (emitChannelIdx >= 1) {
            emitRecord(0x81, 0, 0);
          }
        }
      } else {
        if (inDevMode && isMove) {
          emitRecord(0xD7, 0x00, 0x00);
          inDevMode = false;
        }
        if (isMove && (dx != 0 || dy != 0)) {
          emitMoveSteps(dx, dy, true);
          emitRecord(0x80, 0, 0);
        } else {
          emitMoveSteps(dx, dy, false);
        }
      }
    }

    if (inDevMode) {
      emitRecord(0xD7, 0x00, 0x00);
      inDevMode = false;
    }
    emitRecord(0xF8, 0x00, 0x00);

    final Uint8List sec6PlainRaw = sec6Buf.takeBytes();
    final int sec6RawLen = sec6PlainRaw.length;
    final int sec6PaddedLen = ((sec6RawLen + 15) ~/ 16) * 16;
    final Uint8List sec6Plain = Uint8List(sec6PaddedLen);
    sec6Plain.setRange(0, sec6RawLen, sec6PlainRaw);
    final Uint8List sec6Enc = TarikProDahaoParser._ringEnc(
      sec6Plain,
      0,
      sec6PaddedLen,
      (sec6RawLen ^ 0x3028) & 0xFFFF,
    );

    // 3) القسم 1 (1000 بايت: تسلسل الألوان المتكرر مشفّر بـ Ring Cipher)
    final Uint8List sec1Plain = Uint8List(1000);
    for (int i = 0; i < 1000; i++) {
      sec1Plain[i] = colorSeq[i % colorSeq.length];
    }
    final Uint8List sec1Enc = TarikProDahaoParser._ringEnc(sec1Plain, 0, 1000, (1000 ^ 0x3028) & 0xFFFF);

    // 4) القسم 2 (16 بايت metadata مشفّر بـ Ring Cipher)
    final Uint8List sec2Plain = Uint8List(16);
    final Uint8List sec2Enc = TarikProDahaoParser._ringEnc(sec2Plain, 0, 16, (2 ^ 0x3028) & 0xFFFF);

    // 5) الترويسة (0x00..0x100) + جدول الأقسام المشفّر بـ 3DES (0x100..0x140)
    final Uint8List header = Uint8List(0x100);
    // Version 2.10.7070 (02 0A 9E 1B 0A 00 + flags 03 00 for DHE / 00 00 for DHA)
    header[0] = 0x02;
    header[1] = 0x0A;
    header[2] = 0x9E;
    header[3] = 0x1B;
    header[4] = 0x0A;
    header[5] = 0x00;
    header[6] = asDhe ? 0x03 : 0x00;
    header[7] = 0x00;
    // hdr[0x08..0x10] = 0 (hdr_xor = 0)
    TarikProDahaoParser._putU32LE(header, 0x10, 20);
    for (int i = 0; i < 20; i++) {
      final int o = 0x1C + i * 3;
      header[o] = (pal20[i] >> 16) & 0xFF;
      header[o + 1] = (pal20[i] >> 8) & 0xFF;
      header[o + 2] = pal20[i] & 0xFF;
    }

    const int offSec1 = 0x140;
    const int offSec2 = 0x140 + 1000; // 0x528
    const int offSec6 = offSec2 + 16; // 0x538
    final int offEnd = offSec6 + sec6PaddedLen;

    final Uint8List secTablePlain = Uint8List(0x40);
    TarikProDahaoParser._putU32LE(secTablePlain, 0, 1);
    TarikProDahaoParser._putU32LE(secTablePlain, 4, offSec1);
    TarikProDahaoParser._putU32LE(secTablePlain, 8, 1000);

    TarikProDahaoParser._putU32LE(secTablePlain, 16, 2);
    TarikProDahaoParser._putU32LE(secTablePlain, 20, offSec2);
    TarikProDahaoParser._putU32LE(secTablePlain, 24, 2);

    TarikProDahaoParser._putU32LE(secTablePlain, 32, 6);
    TarikProDahaoParser._putU32LE(secTablePlain, 36, offSec6);
    TarikProDahaoParser._putU32LE(secTablePlain, 40, sec6RawLen);

    TarikProDahaoParser._putU32LE(secTablePlain, 48, 0);
    TarikProDahaoParser._putU32LE(secTablePlain, 52, offEnd);
    TarikProDahaoParser._putU32LE(secTablePlain, 56, 0);

    final Uint8List secTableEnc = TarikProDahaoParser._des3Enc(secTablePlain, 0, 0x40, asDhe);

    final out = BytesBuilder(copy: false);
    out.add(header);
    out.add(secTableEnc);
    out.add(sec1Enc);
    out.add(sec2Enc);
    out.add(sec6Enc);
    return out.takeBytes();
  }
}

/// المصدّر الشامل الموحّد (يدعم DHE و DHA و DST وجميع الصيغ القياسية مع ضبط القنوات A–H)
class TarikProUniversalExporter {
  static List<Map<String, String>> get supportedFormats {
    final List<Map<String, String>> list = [
      {'ext': 'DHE', 'name': 'Dahao Extended — 8 Beads/Sequins (.DHE)'},
      {'ext': 'DHA', 'name': 'Dahao Machine (.DHA)'},
    ];
    for (final f in UniversalExporter.supportedFormats) {
      final ext = (f['ext'] ?? '').toUpperCase();
      if (ext != 'DHE' && ext != 'DHA') {
        list.add(f);
      }
    }
    return list;
  }

  static bool canExport(String filePath) {
    final low = filePath.toLowerCase();
    if (low.endsWith('.emb')) return false;
    return low.endsWith('.dhe') ||
        low.endsWith('.dha') ||
        low.endsWith('.dhp') ||
        low.endsWith('.dst') ||
        low.endsWith('.tbf') ||
        UniversalExporter.canExport(filePath);
  }

  static Future<String?> exportVector(
    VectorDesignData vec,
    String outPath,
    String formatExt, {
    String baseName = 'tarik_emb',
    TarikMachineDeviceProfile? profile,
  }) async {
    final ext = formatExt.toUpperCase().replaceAll('.', '');
    if (ext == 'DHE' || ext == 'DHA') {
      try {
        final p = profile ?? TarikMachineDeviceManager.current;
        final bytes = await Isolate.run(() => TarikProDahaoEncoder.encode(vec, asDhe: ext == 'DHE', profile: p));
        if (bytes.isEmpty) return null;
        final file = File(outPath);
        await file.writeAsBytes(bytes, flush: true);
        return outPath;
      } catch (_) {
        return null;
      }
    }
    return TarikProDstEncoder.exportToFile(vec, outPath, ext, baseName: baseName);
  }

  static Future<String?> exportFromFile(
    String srcPath,
    String outPath,
    String formatExt, {
    TarikMachineDeviceProfile? profile,
  }) async {
    final ext = formatExt.toUpperCase().replaceAll('.', '');
    final p = profile ?? TarikMachineDeviceManager.current;
    final low = srcPath.toLowerCase();
    if (ext == 'DHE' || ext == 'DHA' || (ext == 'DST' && (low.endsWith('.dhe') || low.endsWith('.dha') || low.endsWith('.dst') || low.endsWith('.tbf')))) {
      VectorDesignData? vec;
      if (low.endsWith('.dhe') || low.endsWith('.dha')) {
        vec = await TarikProDahaoParser.loadVector(srcPath);
      } else if (low.endsWith('.dst')) {
        vec = await TarikProDstDeviceParser.loadVector(srcPath, profile: p);
      } else if (low.endsWith('.tbf')) {
        vec = await TarikProTbfParser.loadVector(srcPath);
      }
      vec ??= await VectorDesignLoader.load(srcPath);
      if (vec != null && vec.stX.length >= 2) {
        final baseName = srcPath.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.[^.]+$'), '');
        return exportVector(vec, outPath, ext, baseName: baseName, profile: p);
      }
    }
    return UniversalExporter.exportToFormat(srcPath, outPath, ext);
  }
}
