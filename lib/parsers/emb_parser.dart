import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ThreadColorStep {
  final int stopNumber, colorIndex, stitches, colorValue;
  final String colorName;
  ThreadColorStep({
    required this.stopNumber,
    required this.colorIndex,
    required this.stitches,
    required this.colorName,
    required this.colorValue,
  });
}

class EmbDesignInfo {
  final String filePath, fileName, machineType;
  final Uint8List? previewJpeg, stitchPreviewBytes;
  final int previewWidth, previewHeight, stitches, colorCount, stopsCount, jumpsCount, sequinsCount, trimsCount, beadsCount;
  final List colorSequence;
  final double? widthMm, heightMm;

  EmbDesignInfo({
    required this.filePath,
    required this.fileName,
    this.previewJpeg,
    this.stitchPreviewBytes,
    this.previewWidth = 0,
    this.previewHeight = 0,
    required this.stitches,
    required this.colorCount,
    this.stopsCount = 0,
    required this.jumpsCount,
    required this.sequinsCount,
    this.trimsCount = 0,
    this.beadsCount = 0,
    required this.machineType,
    required this.colorSequence,
    this.widthMm,
    this.heightMm,
  });
  int get actualStopsCount => stopsCount > 0 ? stopsCount : (colorSequence.isNotEmpty ? colorSequence.length : colorCount);
}

class _ExtractedImage {
  final Uint8List bytes;
  final int width, height;
  _ExtractedImage(this.bytes, this.width, this.height);
  int get pixels => width * height;
}

class EmbParser {
  static Future<EmbDesignInfo?> parseFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final ole = _Ole2Reader(bytes);
      if (!ole.isValid) return null;

      _ExtractedImage? bestTrueView = _decodeStreamImage(ole.getStream('TRUEVIEW_ICON'));
      final _ExtractedImage? stitchView = _decodeStreamImage(ole.getStream('DESIGN_ICON'));
      for (final name in ole.streamNames) {
        if (name == 'TRUEVIEW_ICON' || name == 'DESIGN_ICON') continue;
        final candidate = _decodeStreamImage(ole.getStream(name));
        if (candidate != null && (bestTrueView == null || candidate.pixels > bestTrueView.pixels)) {
          bestTrueView = candidate;
        }
      }
      final _ExtractedImage? primaryImg = bestTrueView ?? stitchView;
      final Uint8List? secondaryStitch = (bestTrueView != null && stitchView != null) ? stitchView.bytes : null;

      int stitches = 0, colors = 0, stops = 0, jumps = 0, sequins = 0, blings = 0, trims = 0;
      String machine = 'Wilcom EMB';
      List sequence = [];

      double? designWidthMm;
      double? designHeightMm;
      double? fallbackLeft, fallbackRight, fallbackUp, fallbackDown;

      final infoStream = ole.getStream('${String.fromCharCode(5)}WilcomDesignInformationDDD');
      if (infoStream != null && infoStream.length > 56) {
        final bd = ByteData.sublistView(infoStream);
        final sectionOffset = bd.getUint32(44, Endian.little);
        if (sectionOffset + 8 <= infoStream.length) {
          final propCount = bd.getUint32(sectionOffset + 4, Endian.little);
          final Map propPositions = {};
          for (int i = 0; i < propCount; i++) {
            final entryPos = sectionOffset + 8 + (i * 8);
            if (entryPos + 8 > infoStream.length) break;
            propPositions[bd.getUint32(entryPos, Endian.little)] = sectionOffset + bd.getUint32(entryPos + 4, Endian.little);
          }

          final Map pidNames = {};
          if (propPositions.containsKey(0)) {
            final int dictPos = propPositions[0];
            if (dictPos + 4 <= infoStream.length) {
              int curr = dictPos + 4;
              final int dictCount = bd.getUint32(dictPos, Endian.little);
              for (int d = 0; d < dictCount; d++) {
                if (curr + 8 > infoStream.length) break;
                final dPid = bd.getUint32(curr, Endian.little);
                final nameLen = bd.getUint32(curr + 4, Endian.little);
                curr += 8;
                if (curr + nameLen > infoStream.length) break;
                pidNames[dPid] = latin1
                    .decode(infoStream.sublist(curr, curr + nameLen), allowInvalid: true)
                    .replaceAll('\x00', '')
                    .trim()
                    .toLowerCase();
                curr += nameLen;
              }
            }
          }

          for (final entry in propPositions.entries) {
            final int pid = entry.key;
            final int propPos = entry.value;
            if (pid == 0 || propPos + 8 > infoStream.length) continue;
            final propType = bd.getUint32(propPos, Endian.little);
            final String pname = (pidNames[pid] ?? '').toString().toLowerCase();

            if ((propType == 3 || propType == 19 || propType == 22) && propPos + 8 <= infoStream.length) {
              final val = bd.getInt32(propPos + 4, Endian.little);
              if (pname == 'number of stitches' || pname == 'stitches' || pname == 'stitch count') {
                if (val > 0) stitches = val;
              } else if (pname == 'number of colours' || pname == 'number of colors' || pname == 'colors') {
                if (val > 0) colors = val;
              } else if (pname == 'number of stops') {
                if (val > 0) stops = val;
              } else if (pname == 'number of jumps') {
                if (val >= 0) jumps = val;
              } else if (pname == 'number of trims') {
                if (val >= 0) trims = val;
              } else if (pname.contains('sequin')) {
                if (val >= 0) sequins = val;
              } else if (pname.contains('bling') || pname.contains('bead')) {
                if (val >= 0) blings = val;
              }
            } else if ((propType == 4 || propType == 5) && propPos + 8 <= infoStream.length) {
              final double dVal = propType == 4
                  ? bd.getFloat32(propPos + 4, Endian.little)
                  : (propPos + 12 <= infoStream.length ? bd.getFloat64(propPos + 4, Endian.little) : 0.0);

              if (dVal.isNaN || dVal.isInfinite) continue;

              double correctedVal = dVal.abs();
              if (correctedVal > 2000.0) {
                correctedVal = correctedVal / 180.0;
              }

              if (pname == 'design width') {
                designWidthMm = correctedVal;
              } else if (pname == 'design height') {
                designHeightMm = correctedVal;
              } else if (pname == 'design left') {
                fallbackLeft = dVal;
              } else if (pname == 'design right') {
                fallbackRight = dVal;
              } else if (pname == 'design up' || pname == 'design top') {
                fallbackUp = dVal;
              } else if (pname == 'design down' || pname == 'design bottom') {
                fallbackDown = dVal;
              }
            } else if (propType == 30 && propPos + 8 <= infoStream.length) {
              final strLen = bd.getUint32(propPos + 4, Endian.little);
              final rawStr = latin1
                  .decode(infoStream.sublist(propPos + 8, (propPos + 8 + strLen).clamp(0, infoStream.length)), allowInvalid: true)
                  .replaceAll('\x00', '')
                  .trim();
              if ((pid == 19 || pname.contains('machine')) && rawStr.isNotEmpty) {
                machine = rawStr;
              } else if ((pid == 34 || pname.contains('colorway') || pname.contains('thread')) && rawStr.isNotEmpty) {
                final parsed = _parseColorwayTable(rawStr);
                if (parsed.isNotEmpty) sequence = parsed;
              }
            }
          }
        }
      }

      double? finalWidthMm = designWidthMm;
      double? finalHeightMm = designHeightMm;

      if ((finalWidthMm == null || finalWidthMm <= 0) && fallbackLeft != null && fallbackRight != null) {
        double w = (fallbackRight - fallbackLeft).abs();
        if (w > 2000.0) w = w / 180.0;
        finalWidthMm = w;
      }
      if ((finalHeightMm == null || finalHeightMm <= 0) && fallbackUp != null && fallbackDown != null) {
        double h = (fallbackUp - fallbackDown).abs();
        if (h > 2000.0) h = h / 180.0;
        finalHeightMm = h;
      }

      if (finalWidthMm == null || finalHeightMm == null || finalWidthMm <= 0 || finalHeightMm <= 0) {
        final stitchBounds = _extractDesignFileStitchBounds(ole.getStream('DESIGN_FILE'));
        if (stitchBounds != null) {
          finalWidthMm ??= stitchBounds.$1;
          finalHeightMm ??= stitchBounds.$2;
        }
      }

      if (colors == 0 && sequence.isNotEmpty) {
        colors = sequence.length;
      } else if (colors == 0) {
        colors = 1;
      }

      return EmbDesignInfo(
        filePath: filePath,
        fileName: filePath.split(Platform.pathSeparator).last,
        previewJpeg: primaryImg?.bytes,
        stitchPreviewBytes: secondaryStitch,
        previewWidth: primaryImg?.width ?? 0,
        previewHeight: primaryImg?.height ?? 0,
        stitches: stitches,
        colorCount: colors,
        stopsCount: stops,
        jumpsCount: jumps,
        sequinsCount: sequins > 0 ? sequins : blings,
        trimsCount: trims,
        beadsCount: blings,
        machineType: machine,
        colorSequence: sequence,
        widthMm: finalWidthMm,
        heightMm: finalHeightMm,
      );
    } catch (_) {
      return null;
    }
  }

  static (double, double)? _extractDesignFileStitchBounds(Uint8List? rawStream) {
    if (rawStream == null || rawStream.length < 16) return null;
    Uint8List? decompressed;
    for (int offset = 0; offset < math.min(32, rawStream.length - 2); offset++) {
      if (rawStream[offset] == 0x78 && (rawStream[offset + 1] == 0x9C || rawStream[offset + 1] == 0x01 || rawStream[offset + 1] == 0xDA)) {
        try {
          decompressed = Uint8List.fromList(ZLibDecoder().convert(rawStream.sublist(offset)));
          break;
        } catch (_) {}
      }
    }
    if (decompressed == null || decompressed.length < 64) return null;

    final headerSample = latin1.decode(decompressed.sublist(0, math.min(1024, decompressed.length)), allowInvalid: true);
    if (headerSample.contains('+X:') && headerSample.contains('-X:')) {
      final px = DstParser._extractInt(headerSample, '+X:');
      final mx = DstParser._extractInt(headerSample, '-X:');
      final py = DstParser._extractInt(headerSample, '+Y:');
      final my = DstParser._extractInt(headerSample, '-Y:');
      if (px + mx > 0 && py + my > 0) {
        return ((px + mx) / 10.0, (py + my) / 10.0);
      }
    }
    return null;
  }

  static _ExtractedImage? _decodeStreamImage(Uint8List? stream) {
    if (stream == null || stream.length < 16) return null;
    Uint8List? imgBytes;
    if (stream.length > 6 && stream[4] == 0x78) {
      try {
        imgBytes = Uint8List.fromList(ZLibDecoder().convert(stream.sublist(4)));
      } catch (_) {}
    }
    if (imgBytes == null && stream[0] == 0x78) {
      try {
        imgBytes = Uint8List.fromList(ZLibDecoder().convert(stream));
      } catch (_) {}
    }
    imgBytes ??= stream;
    final dims = _readImageDimensions(imgBytes);
    if (dims != null) return _ExtractedImage(imgBytes, dims.$1, dims.$2);

    if ((imgBytes[0] == 0x42 && imgBytes[1] == 0x4D) ||
        (imgBytes[0] == 0xFF && imgBytes[1] == 0xD8) ||
        (imgBytes[0] == 0x89 && imgBytes[1] == 0x50)) {
      return _ExtractedImage(imgBytes, 256, 256);
    }
    return null;
  }

  static (int, int)? _readImageDimensions(Uint8List bytes) {
    if (bytes.length < 26) return null;
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getInt32(18, Endian.little).abs();
      final h = bd.getInt32(22, Endian.little).abs();
      if (w > 0 && h > 0) return (w, h);
    }
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getUint32(16, Endian.big), h = bd.getUint32(20, Endian.big);
      if (w > 0 && h > 0) return (w, h);
    }
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      int offset = 2;
      final bd = ByteData.sublistView(bytes);
      while (offset + 9 < bytes.length) {
        if (bytes[offset] != 0xFF) {
          offset++;
          continue;
        }
        final marker = bytes[offset + 1];
        if (marker == 0xD8 || marker == 0xD9 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
          offset += 2;
          continue;
        }
        if (offset + 4 >= bytes.length) break;
        final segLen = bd.getUint16(offset + 2, Endian.big);
        if (segLen < 2) break;
        if ((marker == 0xC0 || marker == 0xC1 || marker == 0xC2) && offset + 9 <= bytes.length) {
          final h = bd.getUint16(offset + 5, Endian.big), w = bd.getUint16(offset + 7, Endian.big);
          if (w > 0 && h > 0) return (w, h);
        }
        offset += 2 + segLen;
      }
      return (256, 256);
    }
    return null;
  }

  static List _parseColorwayTable(String rawTable) {
    final List steps = [];
    for (final line in rawTable.split('\n')) {
      if (line.trim().isEmpty) continue;
      final cols = line.split('\t');
      if (cols.length >= 2) {
        final stopNum = int.tryParse(cols[0].trim()) ?? (steps.length + 1);
        final colorIdx = int.tryParse(cols[1].trim()) ?? steps.length;
        final stepStitches = cols.length > 3 ? (int.tryParse(cols[3].trim()) ?? 0) : 0;
        final colorName = cols.length > 6 ? cols[6].trim() : 'Color $colorIdx';

        steps.add(
          ThreadColorStep(
            stopNumber: stopNum,
            colorIndex: colorIdx,
            stitches: stepStitches,
            colorName: colorName,
            colorValue: _resolveColorFromName(colorName, colorIdx),
          ),
        );
      }
    }
    return steps;
  }

  static int _resolveColorFromName(String name, int fallbackIdx) {
    const palette = [
      0xFF00BCD4, 0xFFFBC02D, 0xFF6D4C41, 0xFFF06292, 0xFF2E7D32, 0xFFE53935,
      0xFF1E88E5, 0xFF8E24AA, 0xFFF57C00, 0xFFD4AF37, 0xFF00897B, 0xFFE91E63,
    ];
    return palette[fallbackIdx.abs() % palette.length];
  }
}

class _Ole2Reader {
  final Uint8List _data;
  late final ByteData _bd;
  bool isValid = false;
  int _sectorSize = 512, _miniSectorSize = 64, _miniCutoff = 4096;
  int _firstDirSector = 0, _firstMiniFatSector = 0, _numMiniFatSectors = 0;
  final List _fat = [], _miniFat = [];
  Uint8List? _miniStream;
  final Map _entries = {};

  Iterable get streamNames => _entries.keys;

  _Ole2Reader(this._data) {
    if (_data.length < 512) return;
    const magic = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    for (int i = 0; i < 8; i++) {
      if (_data[i] != magic[i]) return;
    }
    isValid = true;
    _bd = ByteData.sublistView(_data);

    _sectorSize = math.pow(2, _bd.getUint16(30, Endian.little)).toInt();
    _miniSectorSize = math.pow(2, _bd.getUint16(32, Endian.little)).toInt();
    final numFatSectors = _bd.getUint32(44, Endian.little);
    _firstDirSector = _bd.getUint32(48, Endian.little);
    _miniCutoff = _bd.getUint32(56, Endian.little);
    _firstMiniFatSector = _bd.getUint32(60, Endian.little);
    _numMiniFatSectors = _bd.getUint32(64, Endian.little);
    int difatSector = _bd.getUint32(68, Endian.little);
    final numDifatSectors = _bd.getUint32(72, Endian.little);

    final List fatSectorIds = [];
    for (int i = 0; i < 109; i++) {
      final sec = _bd.getUint32(76 + i * 4, Endian.little);
      if (sec < 0xFFFFFFFA) fatSectorIds.add(sec);
    }
    for (int d = 0; d < numDifatSectors && difatSector < 0xFFFFFFFA; d++) {
      final offset = (difatSector + 1) * _sectorSize;
      if (offset + _sectorSize > _data.length) break;
      final entriesPerSec = (_sectorSize ~/ 4) - 1;
      for (int i = 0; i < entriesPerSec; i++) {
        final sec = _bd.getUint32(offset + i * 4, Endian.little);
        if (sec < 0xFFFFFFFA) fatSectorIds.add(sec);
      }
      difatSector = _bd.getUint32(offset + entriesPerSec * 4, Endian.little);
    }
    for (int i = 0; i < numFatSectors && i < fatSectorIds.length; i++) {
      final int secId = fatSectorIds[i];
      final offset = (secId + 1) * _sectorSize;
      if (offset + _sectorSize > _data.length) break;
      for (int j = 0; j < _sectorSize ~/ 4; j++) {
        _fat.add(_bd.getUint32(offset + j * 4, Endian.little));
      }
    }
    if (_numMiniFatSectors > 0 && _firstMiniFatSector < 0xFFFFFFFA) {
      final miniFatBytes = _readChain(_firstMiniFatSector);
      final mBd = ByteData.sublistView(miniFatBytes);
      for (int j = 0; j < miniFatBytes.length ~/ 4; j++) {
        _miniFat.add(mBd.getUint32(j * 4, Endian.little));
      }
    }
    final dirBytes = _readChain(_firstDirSector);
    final dirBd = ByteData.sublistView(dirBytes);
    for (int off = 0; off + 128 <= dirBytes.length; off += 128) {
      final nameLen = dirBd.getUint16(off + 64, Endian.little);
      final type = dirBytes[off + 66];
      if (type == 0 || nameLen < 2 || nameLen > 64) continue;
      final List codeUnits = [];
      for (int c = 0; c < nameLen - 2; c += 2) {
        codeUnits.add(dirBd.getUint16(off + c, Endian.little));
      }
      final name = String.fromCharCodes(codeUnits.cast());
      final startSec = dirBd.getUint32(off + 116, Endian.little);
      final size = dirBd.getUint32(off + 120, Endian.little);

      if (type == 5 && startSec < 0xFFFFFFFA && size > 0) {
        _miniStream = _readChain(startSec, maxBytes: size);
      } else if (type == 2) {
        _entries[name] = _DirEntry(name, startSec, size);
      }
    }
  }

  Uint8List? getStream(String name) {
    final _DirEntry? entry = _entries[name];
    if (entry == null || entry.size == 0) return null;
    if (entry.size < _miniCutoff && _miniStream != null) {
      return _readMiniChain(entry.startSector, entry.size);
    }
    return _readChain(entry.startSector, maxBytes: entry.size);
  }

  Uint8List _readChain(int startSector, {int? maxBytes}) {
    final builder = BytesBuilder(copy: false);
    int sec = startSector, collected = 0;
    final Set visited = {};
    while (sec >= 0 && sec < 0xFFFFFFFA && !visited.contains(sec)) {
      visited.add(sec);
      final offset = (sec + 1) * _sectorSize;
      if (offset + _sectorSize > _data.length) break;
      int toRead = _sectorSize;
      if (maxBytes != null && collected + toRead > maxBytes) toRead = maxBytes - collected;
      builder.add(_data.sublist(offset, offset + toRead));
      collected += toRead;
      if (maxBytes != null && collected >= maxBytes) break;
      sec = sec < _fat.length ? _fat[sec] : 0xFFFFFFFE;
    }
    return builder.takeBytes();
  }

  Uint8List _readMiniChain(int startMiniSector, int size) {
    final builder = BytesBuilder(copy: false);
    int sec = startMiniSector, collected = 0;
    final Set visited = {};
    while (sec >= 0 && sec < 0xFFFFFFFA && !visited.contains(sec)) {
      visited.add(sec);
      final offset = sec * _miniSectorSize;
      if (offset + _miniSectorSize > _miniStream!.length) break;
      int toRead = _miniSectorSize;
      if (collected + toRead > size) toRead = size - collected;
      builder.add(_miniStream!.sublist(offset, offset + toRead));
      collected += toRead;
      if (collected >= size) break;
      sec = sec < _miniFat.length ? _miniFat[sec] : 0xFFFFFFFE;
    }
    return builder.takeBytes();
  }
}

class _DirEntry {
  final String name;
  final int startSector, size;
  _DirEntry(this.name, this.startSector, this.size);
}

// ---------------------------------------------------------------------------
// مخازن بيانات سريعة وخفيفة للعبور بين خيوط المعالجة (Isolates) دون استهلاك للذاكرة
// ---------------------------------------------------------------------------

class _Float32Buf {
  Float32List _buf;
  int length = 0;
  _Float32Buf([int initialCapacity = 4096]) : _buf = Float32List(initialCapacity);

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

class _Uint8Buf {
  Uint8List _buf;
  int length = 0;
  _Uint8Buf([int initialCapacity = 4096]) : _buf = Uint8List(initialCapacity);

  void add(int v) {
    if (length == _buf.length) {
      final next = Uint8List(_buf.length * 2);
      next.setRange(0, length, _buf);
      _buf = next;
    }
    _buf[length++] = v;
  }

  int at(int i) => _buf[i];
  void setAt(int i, int v) {
    _buf[i] = v;
  }

  Uint8List finish() => Uint8List.sublistView(_buf, 0, length);
}

/// حزمة متجهية نقية (Pure Dart TypedData) تُجهّز في الخيط الخلفي وتُسلَّم جاهزة للرسم السريع
class VectorDesignData {
  final Float32List stX;
  final Float32List stY;
  final Uint8List stMove; // 1 = moveTo (بعد قفزة أو تغيير لون), 0 = lineTo
  final Uint8List stColor;
  final Uint8List? stDev; // أكواد الأجهزة لكل غرزة (ترتر 1..4، خرز 5..7، تشغيل 0x10، إيقاف 0x20)

  final Float32List seqX;
  final Float32List seqY;
  final Uint8List seqCode;

  final Float32List beadX;
  final Float32List beadY;
  final Uint8List beadCode;

  final Int32List paletteArgb;
  final int stitches, colorCount, stopsCount, jumpsCount, sequinsCount, beadsCount, trimsCount;
  final double minX, maxX, minY, maxY;
  final bool hasBounds;
  final String machineType;

  VectorDesignData({
    required this.stX,
    required this.stY,
    required this.stMove,
    required this.stColor,
    this.stDev,
    required this.seqX,
    required this.seqY,
    required this.seqCode,
    required this.beadX,
    required this.beadY,
    required this.beadCode,
    required this.paletteArgb,
    required this.stitches,
    required this.colorCount,
    required this.stopsCount,
    required this.jumpsCount,
    required this.sequinsCount,
    required this.beadsCount,
    required this.trimsCount,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.hasBounds,
    required this.machineType,
  });

  double? get widthMm => hasBounds && (maxX - minX) > 0 ? (maxX - minX) / 10.0 : null;
  double? get heightMm => hasBounds && (maxY - minY) > 0 ? (maxY - minY) / 10.0 : null;
}

/// قارئ صفحات مجمّع (4 صفحات × 1 ميجا) يخفض عمليات القراءة في ملفات .DHP من 205,000 إلى ~67 فقط
class _BufferedFileReader {
  final RandomAccessFile _raf;
  final int fileLen;
  final int pageSize;
  final int maxPages;
  final Map<int, Uint8List> _cache = {};
  final List<int> _order = [];

  _BufferedFileReader(this._raf, this.fileLen, {this.pageSize = 1024 * 1024, this.maxPages = 4});

  Uint8List _getPage(int pg) {
    final existing = _cache[pg];
    if (existing != null) return existing;
    final int start = pg * pageSize;
    final int len = math.min(pageSize, fileLen - start);
    _raf.setPositionSync(start);
    final Uint8List buf = _raf.readSync(len);
    _cache[pg] = buf;
    _order.add(pg);
    if (_order.length > maxPages) {
      final int evict = _order.removeAt(0);
      _cache.remove(evict);
    }
    return buf;
  }

  Uint8List? readBytes(int offset, int length) {
    if (offset < 0 || length <= 0 || offset + length > fileLen) return null;
    final int pg0 = offset ~/ pageSize;
    final int pg1 = (offset + length - 1) ~/ pageSize;
    if (pg0 == pg1) {
      final buf = _getPage(pg0);
      final int rel = offset - pg0 * pageSize;
      if (rel + length > buf.length) return null;
      return Uint8List.sublistView(buf, rel, rel + length);
    }
    final out = Uint8List(length);
    int written = 0;
    int cur = offset;
    while (written < length) {
      final int pg = cur ~/ pageSize;
      final buf = _getPage(pg);
      final int rel = cur - pg * pageSize;
      final int avail = buf.length - rel;
      if (avail <= 0) return null;
      final int take = math.min(length - written, avail);
      out.setRange(written, written + take, buf, rel);
      written += take;
      cur += take;
    }
    return out;
  }
}

/// محرك رسم موحّد ومُسرّع بالـ GPU (تجميع الخرز عبر drawRawPoints والترتر عبر 4 مسارات Path)
Future<Uint8List?> _renderVectorDesignToImage(VectorDesignData data, {double maxCanvas = 1200.0, bool is3D = false, bool transparentBg = false}) async {
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

  final int palLen = data.paletteArgb.length;
  final double strokeW = maxCanvas >= 1800.0 ? 0.62 : 0.56;
  final double minX = data.minX;
  final double minY = data.minY;

  // 1) رسم الغرز مساراً لكل لون
  final Float32List stX = data.stX;
  final Float32List stY = data.stY;
  final Uint8List stMove = data.stMove;
  final Uint8List stColor = data.stColor;
  final int nSt = stX.length;

  Path currentPath = Path();
  int activeColorIdx = -1;
  bool hasMove = false;

  void flushPath() {
    if (!hasMove || activeColorIdx < 0) return;
    final Color baseColor = Color(data.paletteArgb[activeColorIdx % palLen]);
    if (is3D) {
      final double threadW = (strokeW * 5.2).clamp(2.4, 5.4);
      final double shOff = threadW * 0.44;
      final double hiOff = threadW * 0.24;

      // 1) ظل ناعم أوسع لإبراز ارتفاع الخيط فوق القماش
      canvas.save();
      canvas.translate(shOff, shOff);
      final shadowPaint = Paint()
        ..color = Colors.black.withOpacity(0.32)
        ..style = PaintingStyle.stroke
        ..strokeWidth = threadW * 1.28
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      canvas.drawPath(currentPath, shadowPaint);
      canvas.restore();

      // 2) حافة الخيط السفلية الداكنة (العمق ثلاثي الأبعاد)
      final edgePaint = Paint()
        ..color = Color.lerp(baseColor, Colors.black, 0.24) ?? baseColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = threadW
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      canvas.drawPath(currentPath, edgePaint);

      // 3) قلب الخيط الغني باللون
      final corePaint = Paint()
        ..color = baseColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = threadW * 0.74
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      canvas.drawPath(currentPath, corePaint);

      // 4) لمعة الحرير العلوية المزدوجة (TrueView 3D Silk Sheen + Specular Rim)
      canvas.save();
      canvas.translate(-hiOff * 0.7, -hiOff * 0.7);
      final midHiPaint = Paint()
        ..color = (Color.lerp(baseColor, Colors.white, 0.38) ?? Colors.white).withOpacity(0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = threadW * 0.48
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      canvas.drawPath(currentPath, midHiPaint);
      canvas.restore();

      canvas.save();
      canvas.translate(-hiOff * 1.15, -hiOff * 1.15);
      final hiPaint = Paint()
        ..color = (Color.lerp(baseColor, Colors.white, 0.72) ?? Colors.white).withOpacity(0.88)
        ..style = PaintingStyle.stroke
        ..strokeWidth = threadW * 0.22
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      canvas.drawPath(currentPath, hiPaint);
      canvas.restore();
    } else {
      final paint = Paint()
        ..color = baseColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      canvas.drawPath(currentPath, paint);
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
    final double sx = (stX[i] - minX) * scale + pad;
    final double sy = (stY[i] - minY) * scale + pad;
    if (stMove[i] != 0 || !hasMove) {
      currentPath.moveTo(sx, sy);
      hasMove = true;
    } else {
      currentPath.lineTo(sx, sy);
    }
  }
  flushPath();

  // 2) رسم الترتر مجمّعاً في 4 مسارات Path فقط (أسرع بعشرات المرات من drawCircle الفردي)
  final int nSeq = data.seqX.length;
  if (nSeq > 0) {
    final List<Path> seqPaths = List.generate(4, (_) => Path());
    final List<bool> hasSeqBucket = [false, false, false, false];
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

    final Float32List seqX = data.seqX;
    final Float32List seqY = data.seqY;
    final Uint8List seqCode = data.seqCode;

    for (int i = 0; i < nSeq; i++) {
      final int code = seqCode[i];
      int b = 0;
      if (code == 2 || code == 6) {
        b = 1;
      } else if (code == 3 || code == 16) {
        b = 2;
      } else if (code == 4 || code == 8 || code == 32) {
        b = 3;
      }
      final double sx = (seqX[i] - minX) * scale + pad;
      final double sy = (seqY[i] - minY) * scale + pad;
      final double r = seqRadiiPx[b];
      seqPaths[b].addOval(Rect.fromCircle(center: Offset(sx, sy), radius: r));
      hasSeqBucket[b] = true;
    }

    for (int b = 0; b < 4; b++) {
      if (!hasSeqBucket[b]) continue;
      final double r = seqRadiiPx[b];
      final paint = Paint()
        ..color = seqColors[b]
        ..style = PaintingStyle.stroke
        ..strokeWidth = (r * 0.25).clamp(0.65, 2.2)
        ..isAntiAlias = true;
      canvas.drawPath(seqPaths[b], paint);
    }
  }

  // 3) رسم الخرز عبر drawRawPoints بدفعة واحدة لكل نوع (4 استدعاءات GPU فقط بدل 30,000)
  final int nBead = data.beadX.length;
  if (nBead > 0) {
    final List<_Float32Buf> beadPts = [
      _Float32Buf(1024),
      _Float32Buf(512),
      _Float32Buf(512),
    ];
    final _Float32Buf hiPts = _Float32Buf(math.min(nBead * 2, 65536));
    final double r = (12.0 * scale).clamp(1.5, 8.0);
    final double hiOff = r * 0.25;

    final Float32List beadX = data.beadX;
    final Float32List beadY = data.beadY;
    final Uint8List beadCode = data.beadCode;

    for (int i = 0; i < nBead; i++) {
      final int c = beadCode[i];
      final int b = (c == 2) ? 1 : (c == 3 ? 2 : 0);
      final double sx = (beadX[i] - minX) * scale + pad;
      final double sy = (beadY[i] - minY) * scale + pad;
      beadPts[b].add(sx);
      beadPts[b].add(sy);
      hiPts.add(sx - hiOff);
      hiPts.add(sy - hiOff);
    }

    const beadColors = [
      Color(0xFFD4A017), // Bead A (ذهبي)
      Color(0xFF00ACC1), // Bead B (فيروزي)
      Color(0xFF8E24AA), // Bead C (بنفسجي)
    ];

    for (int b = 0; b < 3; b++) {
      if (beadPts[b].length == 0) continue;
      final paint = Paint()
        ..color = beadColors[b]
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = r * 2.0
        ..isAntiAlias = true;
      canvas.drawRawPoints(ui.PointMode.points, beadPts[b].finish(), paint);
    }

    if (hiPts.length > 0 && r >= 2.0) {
      final hiPaint = Paint()
        ..color = const Color(0xBFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = r * 0.64
        ..isAntiAlias = true;
      canvas.drawRawPoints(ui.PointMode.points, hiPts.finish(), hiPaint);
    }
  }

  final picture = recorder.endRecording();
  final img = await picture.toImage(imgW, imgH);
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  picture.dispose();
  return byteData?.buffer.asUint8List();
}

class DstParser {
  static Future<EmbDesignInfo?> parseFile(String filePath, {double maxCanvas = 1200.0}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final decoded = await Isolate.run(() => _decodeDstSync(filePath));
      if (decoded == null) return null;

      final Uint8List? imageBytes = await _renderVectorDesignToImage(decoded.$1, maxCanvas: maxCanvas);
      final fileName = filePath.split(Platform.pathSeparator).last;
      return EmbDesignInfo(
        filePath: filePath,
        fileName: fileName,
        previewJpeg: imageBytes,
        stitches: decoded.$2 > 0 ? decoded.$2 : decoded.$1.stitches,
        colorCount: decoded.$3,
        jumpsCount: decoded.$1.jumpsCount,
        sequinsCount: 0,
        machineType: 'Tajima (DST)',
        colorSequence: [],
        widthMm: decoded.$4 > 0 ? decoded.$4 : decoded.$1.widthMm,
        heightMm: decoded.$5 > 0 ? decoded.$5 : decoded.$1.heightMm,
      );
    } catch (_) {
      return null;
    }
  }

  /// توليد معاينة فائقة الدقة (2200 بكسل) عند فتح شاشة التكبير
  static Future<Uint8List?> renderHighResPreview(String filePath, {double maxCanvas = 2200.0, bool is3D = false}) async {
    try {
      final decoded = await Isolate.run(() => _decodeDstSync(filePath));
      if (decoded == null) return null;
      return await _renderVectorDesignToImage(decoded.$1, maxCanvas: maxCanvas, is3D: is3D, transparentBg: true);
    } catch (_) {
      return null;
    }
  }

  static (VectorDesignData, int, int, double, double)? _decodeDstSync(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    if (bytes.length < 512) return null;

    final header = String.fromCharCodes(bytes.sublist(0, 512));
    final headerStitches = _extractInt(header, 'ST:');
    final colors = _extractInt(header, 'CO:') + 1;
    final plusX = _extractInt(header, '+X:');
    final minusX = _extractInt(header, '-X:');
    final plusY = _extractInt(header, '+Y:');
    final minusY = _extractInt(header, '-Y:');
    final widthMm = (plusX + minusX) / 10.0;
    final heightMm = (plusY + minusY) / 10.0;

    final stX = _Float32Buf(8192);
    final stY = _Float32Buf(8192);
    final stMove = _Uint8Buf(8192);
    final stColor = _Uint8Buf(8192);

    int x = 0, y = 0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int colorIdx = 0;
    int stitchCount = 0;
    int jumpCount = 0;
    bool needMove = true;

    for (int i = 512; i < bytes.length - 2; i += 3) {
      final int b1 = bytes[i], b2 = bytes[i + 1], b3 = bytes[i + 2];
      if (b1 == 0x00 && b2 == 0x00 && b3 == 0xF3) break;
      int dx = 0, dy = 0;
      if ((b1 & 0x01) != 0) dx += 1;
      if ((b1 & 0x02) != 0) dx -= 1;
      if ((b1 & 0x04) != 0) dx += 9;
      if ((b1 & 0x08) != 0) dx -= 9;
      if ((b1 & 0x80) != 0) dy += 1;
      if ((b1 & 0x40) != 0) dy -= 1;
      if ((b1 & 0x20) != 0) dy += 9;
      if ((b1 & 0x10) != 0) dy -= 9;
      if ((b2 & 0x01) != 0) dx += 3;
      if ((b2 & 0x02) != 0) dx -= 3;
      if ((b2 & 0x04) != 0) dx += 27;
      if ((b2 & 0x08) != 0) dx -= 27;
      if ((b2 & 0x80) != 0) dy += 3;
      if ((b2 & 0x40) != 0) dy -= 3;
      if ((b2 & 0x20) != 0) dy += 27;
      if ((b2 & 0x10) != 0) dy -= 27;
      if ((b3 & 0x04) != 0) dx += 81;
      if ((b3 & 0x08) != 0) dx -= 81;
      if ((b3 & 0x20) != 0) dy += 81;
      if ((b3 & 0x10) != 0) dy -= 81;
      x += dx;
      y += dy;
      final double px = x.toDouble();
      final double py = -y.toDouble();
      final bool isStop = (b3 & 0x40) != 0;
      final bool isJump = (b3 & 0x80) != 0;

      if (isStop) {
        colorIdx = (colorIdx + 1) % 10;
        needMove = true;
      }
      if (isJump) {
        jumpCount++;
        needMove = true;
      } else {
        stX.add(px);
        stY.add(py);
        stMove.add(needMove ? 1 : 0);
        stColor.add(colorIdx);
        needMove = false;
        stitchCount++;
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

    final palette = Int32List.fromList(const [
      0xFF007BFF, 0xFFFF1744, 0xFF00C853, 0xFFFFB300, 0xFFD500F9,
      0xFFFF5722, 0xFF00E5FF, 0xFFFF007F, 0xFF76FF03, 0xFF3D5AFE,
    ]);

    final vec = VectorDesignData(
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
      paletteArgb: palette,
      stitches: stitchCount,
      colorCount: colors,
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
      machineType: 'Tajima (DST)',
    );

    return (vec, headerStitches, colors, widthMm, heightMm);
  }

  static int _extractInt(String header, String key) {
    final idx = header.indexOf(key);
    if (idx == -1) return 0;
    final endIdx = header.indexOf('\r', idx);
    if (endIdx == -1) return 0;
    final valStr = header.substring(idx + key.length, endIdx).trim();
    return int.tryParse(valStr) ?? 0;
  }
}

class _R2Coord {
  final int sign;
  final int state;
  final int val;
  _R2Coord(this.sign, this.state, this.val);
}

class _DhpChunkItem {
  final int type;
  final int colorOverride;
  final Uint8List? payload;
  _DhpChunkItem(this.type, this.colorOverride, this.payload);
}

/// محرك فك تشفير داهوا الموحّد والمُسرّع عبر Isolate (.DHE / .DHA + .DHP مع فصل كامل للترتر والخرز)
class DahaoParser {
  static int _mod(int a, int m) => ((a % m) + m) % m;

  static bool _isSequinOrStopPayload(bool flip1, bool flip2, int dy, int dx) {
    if (flip1 || flip2) return false;
    if (dx == 0 && dy == 0) return true;
    return (dy == 6 || dy == 10) &&
        (dx == 1 || dx == 2 || dx == 4 || dx == 6 || dx == 8 || dx == 16 || dx == 32);
  }

  /// قراءة وتحليل ملفات داهوا على خيط خلفي (Isolate) لمنع تجمّد الشاشة أو سخونة الهاتف
  static Future<EmbDesignInfo?> parseFile(String filePath, {double maxCanvas = 1200.0}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final lower = filePath.toLowerCase();
      final fileName = filePath.split(Platform.pathSeparator).last;

      final VectorDesignData? vec = await Isolate.run(() {
        if (lower.endsWith('.dhp')) {
          return _decodeDhpSync(filePath);
        }
        return _decodeDheDhaSync(filePath, lower.endsWith('.dhe'));
      });

      if (vec == null) return null;

      Uint8List? previewPng;
      if (vec.stX.length > 2) {
        previewPng = await _renderVectorDesignToImage(vec, maxCanvas: maxCanvas);
      }

      return EmbDesignInfo(
        filePath: filePath,
        fileName: fileName,
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
    } catch (_) {
      return null;
    }
  }

  /// توليد معاينة فائقة الدقة (2200 بكسل) عند فتح شاشة التكبير للتفاصيل الدقيقة
  static Future<Uint8List?> renderHighResPreview(String filePath, {double maxCanvas = 2200.0, bool is3D = false}) async {
    try {
      final lower = filePath.toLowerCase();
      final VectorDesignData? vec = await Isolate.run(() {
        if (lower.endsWith('.dhp')) {
          return _decodeDhpSync(filePath);
        }
        return _decodeDheDhaSync(filePath, lower.endsWith('.dhe'));
      });
      if (vec == null || vec.stX.length <= 2) return null;
      return await _renderVectorDesignToImage(vec, maxCanvas: maxCanvas, is3D: is3D, transparentBg: true);
    } catch (_) {
      return null;
    }
  }

  /// استخراج لوحة ألوان emCAD الحقيقية بصيغة ARGB (أرقام صحيحة نقية للعمل داخل Isolate)
  static (Int32List, int) _extractDhpPaletteArgb(Uint8List hdr) {
    const fallbackPalette = [
      0xFF009900, 0xFFE53935, 0xFFFBC02D, 0xFF00ACC1, 0xFFD81B60, 0xFFFB8C00,
      0xFF5C6BC0, 0xFF2E7D32, 0xFF1E88E5, 0xFF8E24AA, 0xFF00897B, 0xFF6D4C41,
      0xFF3949AB,
    ];

    const defaultUtf16 = [0x44, 0x00, 0x65, 0x00, 0x66, 0x00, 0x61, 0x00, 0x75, 0x00, 0x6C, 0x00, 0x74, 0x00];
    int defPos = -1;
    final int limit = math.min(hdr.length - defaultUtf16.length, 0x1F00);
    for (int i = 0x1000; i <= limit; i++) {
      bool match = true;
      for (int j = 0; j < defaultUtf16.length; j++) {
        if (hdr[i + j] != defaultUtf16[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        defPos = i;
        break;
      }
    }

    if (defPos < 8) {
      return (Int32List.fromList(fallbackPalette), 0);
    }

    final bd = ByteData.sublistView(hdr);
    int colCnt = bd.getUint32(defPos - 8, Endian.little);
    if (colCnt <= 0 || colCnt > 64) colCnt = 0;

    final List<int> parsed = [];
    int p = defPos + 160;
    for (int i = 0; i < (colCnt > 0 ? colCnt : 16); i++) {
      if (p + 8 > hdr.length || p >= 0x2000) break;
      final int structSize = bd.getUint32(p, Endian.little);
      if (structSize != 400) break;
      int r = hdr[p + 4];
      int g = hdr[p + 5];
      int b = hdr[p + 6];
      if (r > 235 && g > 235 && b < 40) {
        r = 225;
        g = 185;
        b = 0;
      } else if (r < 40 && g > 235 && b > 235) {
        r = 0;
        g = 180;
        b = 200;
      } else if (r > 240 && g > 240 && b > 240) {
        r = 175;
        g = 175;
        b = 175;
      }
      parsed.add(0xFF000000 | (r << 16) | (g << 8) | b);
      p += 400;
    }

    final int targetCount = math.max(colCnt, parsed.length);
    for (int i = parsed.length; i < math.max(targetCount, 13); i++) {
      parsed.add(fallbackPalette[i % fallbackPalette.length]);
    }

    return (Int32List.fromList(parsed), colCnt);
  }

  /// قارئ .DHP أحادي المرور بذاكرة صفحات 4×1 ميجا (أسرع بأكثر من 1500 ضعف من القراءة الفردية)
  static VectorDesignData? _decodeDhpSync(String filePath) {
    RandomAccessFile? raf;
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      raf = file.openSync(mode: FileMode.read);
      final int fileLen = raf.lengthSync();
      if (fileLen < 1024) return null;

      final reader = _BufferedFileReader(raf, fileLen, pageSize: 1024 * 1024, maxPages: 4);

      final Uint8List? hdr = reader.readBytes(0, math.min(fileLen, 0x2000));
      if (hdr == null) return null;
      final hdrBd = ByteData.sublistView(hdr);

      int colors = 1;
      int stops = 0;
      int trims = 0;
      if (hdr.length > 740) {
        trims = hdrBd.getInt32(680, Endian.little);
        colors = hdrBd.getInt32(700, Endian.little);
        stops = hdrBd.getInt32(732, Endian.little);
        if (colors <= 0 || colors > 256) colors = 1;
      }

      final palResult = _extractDhpPaletteArgb(hdr);
      final Int32List dhpPalette = palResult.$1;
      if (palResult.$2 > 0) {
        colors = palResult.$2;
      }

      final int tailOffset = _findDhpChainTailSync(reader, fileLen);
      if (tailOffset == -1) {
        return VectorDesignData(
          stX: Float32List(0),
          stY: Float32List(0),
          stMove: Uint8List(0),
          stColor: Uint8List(0),
          seqX: Float32List(0),
          seqY: Float32List(0),
          seqCode: Uint8List(0),
          beadX: Float32List(0),
          beadY: Float32List(0),
          beadCode: Uint8List(0),
          paletteArgb: dhpPalette,
          stitches: 0,
          colorCount: colors,
          stopsCount: stops > 0 ? stops : 0,
          jumpsCount: 0,
          sequinsCount: 0,
          beadsCount: 0,
          trimsCount: trims > 0 ? trims : 0,
          minX: 0,
          maxX: 0,
          minY: 0,
          maxY: 0,
          hasBounds: false,
          machineType: 'Dahao CAD (.DHP)',
        );
      }

      // مرور واحد فقط للخلف مع فحص الترابط المباشر واستخراج الحمولة من الصفحة المخزنة في الكاش
      final List<_DhpChunkItem> reversedItems = [];
      final Set<int> visited = {};
      int cur = tailOffset;
      int? expectedNext;

      while (cur > 0 && cur + 20 <= fileLen && !visited.contains(cur) && reversedItems.length < 250000) {
        visited.add(cur);
        final Uint8List? hbuf = reader.readBytes(cur, 20);
        if (hbuf == null) break;
        final bd = ByteData.sublistView(hbuf);
        final int sz = bd.getUint32(0, Endian.little);
        final int typ = bd.getUint32(4, Endian.little);
        final int nxt = bd.getUint32(8, Endian.little);
        final int prv = bd.getUint32(12, Endian.little);

        if (expectedNext != null && nxt != expectedNext) break;
        if (sz < 20 || cur + sz > fileLen) break;

        final int nRec = (sz - 20) ~/ 12;
        if (typ == 1 && nRec > 0) {
          final Uint8List? pbuf = reader.readBytes(cur + 20, nRec * 12);
          int cIdx = -1;
          if (pbuf != null) {
            final pBd = ByteData.sublistView(pbuf);
            for (int i = 0; i < nRec; i++) {
              final int fl = pBd.getUint32(i * 12 + 8, Endian.little);
              if ((fl & 0xFF) == 0x17) {
                final int v = (fl >> 16) - 1;
                if (v >= 0) cIdx = v;
              }
            }
          }
          reversedItems.add(_DhpChunkItem(1, cIdx, null));
        } else if ((typ == 0 || typ == 2 || typ == 3) && nRec > 0) {
          final Uint8List? pbuf = reader.readBytes(cur + 20, nRec * 12);
          if (pbuf != null) {
            // نسخ الحمولة فقط (بضعة ميجا للغرز) حتى تتحرر صفحة الـ 1 ميجا تلقائياً
            reversedItems.add(_DhpChunkItem(typ, -1, Uint8List.fromList(pbuf)));
          }
        }

        expectedNext = cur;
        cur = prv;
      }

      // مرور خطي سريع في الذاكرة لتعبئة المصفوفات المسطحة (Float32List)
      final stX = _Float32Buf(32768);
      final stY = _Float32Buf(32768);
      final stMove = _Uint8Buf(32768);
      final stColor = _Uint8Buf(32768);
      final stDev = _Uint8Buf(32768);

      final seqX = _Float32Buf(4096);
      final seqY = _Float32Buf(4096);
      final seqCode = _Uint8Buf(4096);

      final beadX = _Float32Buf(4096);
      final beadY = _Float32Buf(4096);
      final beadCode = _Uint8Buf(4096);

      int stitchCount = 0;
      int sequinCount = 0;
      int beadCount = 0;
      int jumpCount = 0;
      int colorChangeCount = 0;
      int currentColorIdx = 0;
      final int palLen = dhpPalette.length;
      double minX = double.infinity, maxX = -double.infinity;
      double minY = double.infinity, maxY = -double.infinity;
      bool hasBounds = false;

      for (int idx = reversedItems.length - 1; idx >= 0; idx--) {
        final item = reversedItems[idx];
        if (item.type == 1) {
          if (item.colorOverride >= 0) {
            currentColorIdx = item.colorOverride % palLen;
            colorChangeCount++;
          }
          jumpCount++;
          continue;
        }

        final Uint8List? raw = item.payload;
        if (raw == null) continue;
        final int nRec = raw.length ~/ 12;
        final bd = ByteData.sublistView(raw);

        bool needMove = true;
        bool pendingDevOn = false;
        for (int i = 0; i < nRec; i++) {
          final int off = i * 12;
          final int rawX = bd.getInt32(off, Endian.little);
          final int rawY = bd.getInt32(off + 4, Endian.little);
          final int fl = bd.getUint32(off + 8, Endian.little);
          final int low = fl & 0xFF;

          if (low == 0x04) {
            // أمر تشغيل جهاز الخرز أو الترتر (D7 00 00) بدون إدخال قفزة وهمية
            if (stDev.length > 0) {
              stDev.setAt(stDev.length - 1, stDev.at(stDev.length - 1) | 0x10);
            } else {
              pendingDevOn = true;
            }
            continue;
          }
          if (low == 0x15) {
            // أمر إيقاف جهاز الخرز أو الترتر (D7 00 00)
            if (stDev.length > 0) {
              stDev.setAt(stDev.length - 1, stDev.at(stDev.length - 1) | 0x20);
            }
            continue;
          }

          int devCode = 0;
          int bType = 0;
          int sType = 0;
          if (low == 0x43 || (((fl & 0x01000000) != 0) && low == 0x45)) {
            devCode = 5;
            bType = 1;
          } else if (low == 0x53 || (((fl & 0x01000000) != 0) && low == 0x46)) {
            devCode = 6;
            bType = 2;
          } else if (low == 0x63 || (((fl & 0x01000000) != 0) && low == 0x47)) {
            devCode = 7;
            bType = 3;
          } else if (low == 0x06) {
            devCode = 1;
            sType = 1;
          } else if (low == 0x07) {
            devCode = 2;
            sType = 2;
          } else if (low == 0x09) {
            devCode = 3;
            sType = 3;
          } else if (low == 0x0D || (low >= 0x0A && low <= 0x0F)) {
            devCode = 4;
            sType = 4;
          }

          final bool isBead = bType > 0;
          final bool isSequin = sType > 0;
          final bool isNormalStitch = low == 0x00;

          if (isNormalStitch || isSequin || isBead) {
            final double px = rawX / 10.0;
            final double py = -rawY / 10.0;

            stX.add(px);
            stY.add(py);
            stMove.add(needMove ? 1 : 0);
            stColor.add(currentColorIdx);
            int dv = devCode;
            if (pendingDevOn) {
              dv |= 0x10;
              pendingDevOn = false;
            }
            stDev.add(dv);
            if (needMove) {
              jumpCount++;
              needMove = false;
            }
            stitchCount++;

            if (isSequin) {
              sequinCount++;
              seqX.add(px);
              seqY.add(py);
              seqCode.add(sType);
            } else if (isBead) {
              beadCount++;
              beadX.add(px);
              beadY.add(py);
              beadCode.add(bType);
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
          } else if (low == 0x17) {
            final int cIdx = (fl >> 16) - 1;
            if (cIdx >= 0) {
              currentColorIdx = cIdx % palLen;
              colorChangeCount++;
            }
            needMove = true;
          } else {
            needMove = true;
          }
        }
      }

      return VectorDesignData(
        stX: stX.finish(),
        stY: stY.finish(),
        stMove: stMove.finish(),
        stColor: stColor.finish(),
        stDev: stDev.finish(),
        seqX: seqX.finish(),
        seqY: seqY.finish(),
        seqCode: seqCode.finish(),
        beadX: beadX.finish(),
        beadY: beadY.finish(),
        beadCode: beadCode.finish(),
        paletteArgb: dhpPalette,
        stitches: stitchCount,
        colorCount: colors,
        stopsCount: colorChangeCount > 0 ? colorChangeCount : (stops > 0 ? stops : 0),
        jumpsCount: jumpCount,
        sequinsCount: sequinCount,
        beadsCount: beadCount,
        trimsCount: trims > 0 ? trims : 0,
        minX: minX,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        hasBounds: hasBounds,
        machineType: 'Dahao CAD (.DHP)',
      );
    } catch (_) {
      return null;
    } finally {
      raf?.closeSync();
    }
  }

  static int _findDhpChainTailSync(_BufferedFileReader reader, int fileLen) {
    final int scanLen = math.min(fileLen - 0x2000, 2 * 1024 * 1024);
    if (scanLen <= 24) return -1;

    final int scanStart = fileLen - scanLen;
    final Uint8List? tailBuf = reader.readBytes(scanStart, scanLen);
    if (tailBuf == null) return -1;
    final bd = ByteData.sublistView(tailBuf);

    for (int rel = (tailBuf.length - 24) & ~3; rel >= 0; rel -= 4) {
      final int absP = scanStart + rel;
      final int sz = bd.getUint32(rel, Endian.little);
      final int typ = bd.getUint32(rel + 4, Endian.little);
      final int prv = bd.getUint32(rel + 12, Endian.little);
      final int cnt = bd.getUint32(rel + 16, Endian.little);

      if ((typ == 0 || typ == 1 || typ == 2 || typ == 3 || typ == 7) &&
          sz >= 20 &&
          sz <= 2000000 &&
          prv >= 0x2000 &&
          prv < absP) {
        final bool validSz = (typ == 1 && sz == 44) ||
            ((sz - 20) % 12 == 0 && ((sz - 20) ~/ 12 == cnt || (sz - 20) ~/ 12 == cnt + 1));
        if (!validSz) continue;

        final Uint8List? pbuf = reader.readBytes(prv, 20);
        if (pbuf == null) continue;
        final pBd = ByteData.sublistView(pbuf);
        if (pBd.getUint32(8, Endian.little) == absP) {
          int cur = absP;
          while (true) {
            final Uint8List? cbuf = reader.readBytes(cur, 20);
            if (cbuf == null) return cur;
            final cBd = ByteData.sublistView(cbuf);
            final int nxt = cBd.getUint32(8, Endian.little);
            if (nxt == 0 || nxt + 20 > fileLen) return cur;
            final Uint8List? nbuf = reader.readBytes(nxt, 20);
            if (nbuf == null) return cur;
            final nBd = ByteData.sublistView(nbuf);
            if (nBd.getUint32(12, Endian.little) != cur) return cur;
            cur = nxt;
          }
        }
      }
    }
    return -1;
  }

  /// فك تشفير .DHE / .DHA بالكامل داخل الخيط الخلفي (Isolate)
  static VectorDesignData? _decodeDheDhaSync(String filePath, bool isDhe) {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    if (bytes.length < 32) return null;
    final bd = ByteData.sublistView(bytes);

    final int stops = bd.getUint16(4, Endian.little);
    final int rawColors = bd.getInt32(16, Endian.little);
    final int validColors = (rawColors > 0 && rawColors < 256) ? rawColors : 1;

    final Int32List paletteArgb = _extractHeaderPaletteArgb(bytes, validColors);

    // فك التشفير الرسمي الدقيق (3DES + 4-Ring) لاستخراج الغرز والخرز والترتر بدقة 100%
    final VectorDesignData? exactDecoded = _DahaoCrypto.decodeExactDheDha(
      bytes,
      isDhe,
      paletteArgb,
      validColors,
      stops,
    );
    if (exactDecoded != null && exactDecoded.stX.length >= 2) {
      return exactDecoded;
    }

    final detected = _detectStartAndKeys(bytes, isDhe);
    final int startPos = detected.$1;
    final int endPos = detected.$2;
    final int ky0 = detected.$3;
    final int kx0 = detected.$4;
    final int? endByte = detected.$5;

    final stX = _Float32Buf(16384);
    final stY = _Float32Buf(16384);
    final stMove = _Uint8Buf(16384);
    final stColor = _Uint8Buf(16384);

    final seqX = _Float32Buf(2048);
    final seqY = _Float32Buf(2048);
    final seqCode = _Uint8Buf(2048);

    if (startPos >= endPos - 3) {
      return VectorDesignData(
        stX: Float32List(0),
        stY: Float32List(0),
        stMove: Uint8List(0),
        stColor: Uint8List(0),
        seqX: Float32List(0),
        seqY: Float32List(0),
        seqCode: Uint8List(0),
        beadX: Float32List(0),
        beadY: Float32List(0),
        beadCode: Uint8List(0),
        paletteArgb: paletteArgb,
        stitches: 0,
        colorCount: validColors,
        stopsCount: stops,
        jumpsCount: 0,
        sequinsCount: 0,
        beadsCount: 0,
        trimsCount: 0,
        minX: 0,
        maxX: 0,
        minY: 0,
        maxY: 0,
        hasBounds: false,
        machineType: isDhe ? 'Dahao (.DHE)' : 'Dahao (.DHA)',
      );
    }

    final ring3 = _detectRing3Keys(bytes, startPos, endPos, ky0, kx0);
    final int r3A = ring3.$1;
    final int r3B = ring3.$2;

    final ring4 = _detectRing4Keys(bytes, startPos, endPos, ky0, kx0, endByte);
    final int r4A = ring4.$1;
    final int r4B = ring4.$2;

    final Map<int, (int, int)> stitchSignMap = {
      110 + r3A: (-1, 1),
      110 + r3B: (-1, 1),
      110 + (r3A + 32) % 83: (1, -1),
      110 + (r3B + 32) % 83: (1, -1),
      110 + (r3A + 51) % 83: (1, 1),
      110 + (r3B + 51) % 83: (1, 1),
      193 + r4A: (-1, -1),
      193 + r4B: (-1, -1),
    };

    final Map<int, (int, int)> jumpSignMap = {
      110 + (r3A + 1) % 83: (-1, 1),
      110 + (r3B + 1) % 83: (-1, 1),
      110 + (r3A + 52) % 83: (1, 1),
      110 + (r3B + 52) % 83: (1, 1),
      193 + (r4A + 1) % 63: (-1, -1),
      193 + (r4B + 1) % 63: (-1, -1),
      193 + (r4A + 32) % 63: (1, -1),
      193 + (r4B + 32) % 63: (1, -1),
    };

    final Set<int> specialCmds = {
      193 + _mod(r4A - 9, 63),
      193 + _mod(r4B - 9, 63),
    };

    final ring2 = _detectRing2Keys(
      bytes,
      startPos,
      endPos,
      ky0,
      kx0,
      r3A,
      r3B,
      stitchSignMap,
      jumpSignMap,
      specialCmds,
      endByte,
    );
    final int k2S0 = ring2.$1;
    final int k2S1 = ring2.$2;

    bool ring1Flipped = false;
    bool ring2Flipped = false;
    int x = 0, y = 0;
    double minX = 0, maxX = 0, minY = 0, maxY = 0;
    bool hasBounds = false;

    int stitches = 0, jumps = 0, sequins = 0;
    int currentColorIdx = 0;
    final int paletteSize = paletteArgb.length;
    bool sawRealStitchInColor = false;
    bool needMove = true;

    for (int p = startPos; p + 2 < endPos; p += 3) {
      final int cmd = bytes[p];
      final int b1 = bytes[p + 1];
      final int b2 = bytes[p + 2];

      if (endByte != null && cmd == endByte && ((b1 == ky0 && b2 == kx0) || (b1 == kx0 && b2 == ky0))) {
        break;
      }
      if (cmd == 0x00 && b1 == 0x00 && b2 == 0x00) break;

      int dy;
      bool flip1 = false;
      if (b1 < 61) {
        final int curKy = ring1Flipped ? kx0 : ky0;
        dy = _mod(b1 - curKy, 61);
      } else if (b1 <= 109) {
        final int curK2 = ring2Flipped ? k2S1 : k2S0;
        dy = 61 + _mod(b1 - 61 - curK2, 49);
        flip1 = true;
        ring1Flipped = !ring1Flipped;
        ring2Flipped = !ring2Flipped;
      } else if (b1 <= 192) {
        dy = _decodeRing3Coord(b1, r3A, r3B);
        flip1 = true;
        ring1Flipped = !ring1Flipped;
      } else {
        continue;
      }

      int dx;
      bool flip2 = false;
      if (b2 < 61) {
        final int curKx = ring1Flipped ? ky0 : kx0;
        dx = _mod(b2 - curKx, 61);
      } else if (b2 <= 109) {
        final int curK2 = ring2Flipped ? k2S1 : k2S0;
        dx = 61 + _mod(b2 - 61 - curK2, 49);
        flip2 = true;
        ring1Flipped = !ring1Flipped;
        ring2Flipped = !ring2Flipped;
      } else if (b2 <= 192) {
        dx = _decodeRing3Coord(b2, r3A, r3B);
        flip2 = true;
        ring1Flipped = !ring1Flipped;
      } else {
        continue;
      }

      final bool isSpecialPayload = _isSequinOrStopPayload(flip1, flip2, dy, dx);

      if (specialCmds.contains(cmd) &&
          (!stitchSignMap.containsKey(cmd) || isSpecialPayload) &&
          (!jumpSignMap.containsKey(cmd) || isSpecialPayload)) {
        if (dx == 0 && dy == 0) {
          if (sawRealStitchInColor && paletteSize > 1) {
            currentColorIdx = (currentColorIdx + 1) % paletteSize;
            sawRealStitchInColor = false;
          }
          needMove = true;
        } else {
          sequins++;
          final double px = x.toDouble();
          final double py = -y.toDouble();
          seqX.add(px);
          seqY.add(py);
          seqCode.add(dx);
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
      } else if (stitchSignMap.containsKey(cmd)) {
        final s = stitchSignMap[cmd]!;
        x += s.$1 * dx;
        y += s.$2 * dy;

        if (stitches == 0 && dx == 0 && dy == 0) {
          needMove = true;
          continue;
        }

        stitches++;
        sawRealStitchInColor = true;
        final double px = x.toDouble();
        final double py = -y.toDouble();
        stX.add(px);
        stY.add(py);
        stMove.add(needMove ? 1 : 0);
        stColor.add(currentColorIdx);
        needMove = false;

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
      } else if (jumpSignMap.containsKey(cmd)) {
        final s = jumpSignMap[cmd]!;
        x += s.$1 * dx;
        y += s.$2 * dy;
        jumps++;
        needMove = true;
      } else if (dx == 0 && dy == 0) {
        if (sawRealStitchInColor && paletteSize > 1) {
          currentColorIdx = (currentColorIdx + 1) % paletteSize;
          sawRealStitchInColor = false;
        }
        needMove = true;
      }
    }

    return VectorDesignData(
      stX: stX.finish(),
      stY: stY.finish(),
      stMove: stMove.finish(),
      stColor: stColor.finish(),
      seqX: seqX.finish(),
      seqY: seqY.finish(),
      seqCode: seqCode.finish(),
      beadX: Float32List(0),
      beadY: Float32List(0),
      beadCode: Uint8List(0),
      paletteArgb: paletteArgb,
      stitches: stitches,
      colorCount: validColors,
      stopsCount: stops,
      jumpsCount: jumps,
      sequinsCount: sequins,
      beadsCount: 0,
      trimsCount: 0,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      hasBounds: hasBounds,
      machineType: isDhe ? 'Dahao (.DHE)' : 'Dahao (.DHA)',
    );
  }

  static Int32List _extractHeaderPaletteArgb(Uint8List bytes, int count) {
    final List<int> colors = [];
    const fallbackPalette = [
      0xFF1E8E3E, 0xFF1E88E5, 0xFFE53935, 0xFF8E24AA,
      0xFFF57C00, 0xFF00897B, 0xFFD81B60, 0xFF3949AB,
    ];

    final int maxToRead = math.min(count, 64);
    for (int i = 0; i < maxToRead; i++) {
      final int off = 0x1C + i * 3;
      if (off + 2 >= bytes.length || off >= 0x160) break;
      int r = bytes[off];
      int g = bytes[off + 1];
      int b = bytes[off + 2];
      if (r > 240 && g > 240 && b > 240) {
        r = 180;
        g = 180;
        b = 180;
      }
      if (r == 0 && g == 0 && b == 0 && i > 0) {
        colors.add(fallbackPalette[i % fallbackPalette.length]);
      } else {
        colors.add(0xFF000000 | (r << 16) | (g << 8) | b);
      }
    }
    if (colors.isEmpty) {
      return Int32List.fromList(fallbackPalette);
    }
    return Int32List.fromList(colors);
  }

  static (int, int, int, int, int?) _detectStartAndKeys(Uint8List bytes, bool isDhe) {
    int stitchEndPos = math.max(0, bytes.length - 24);
    int? endByte;
    int? tailA;
    int? tailB;

    if (bytes.length > 64) {
      final int tailStart = math.max(32, bytes.length - 64);
      final int tailLimit = bytes.length - 8;
      for (int p = tailLimit - 4; p >= tailStart; p--) {
        final int a = bytes[p];
        final int b = bytes[p + 1];
        if (a < 61 && b < 61 && a != b && bytes[p + 2] == a && bytes[p + 3] == b) {
          int q = p;
          while (q >= tailStart + 2 && bytes[q - 2] == a && bytes[q - 1] == b) {
            q -= 2;
          }
          if (q - 1 > 32 && bytes[q - 1] >= 193) {
            tailA = a;
            tailB = b;
            endByte = bytes[q - 1];
            stitchEndPos = q - 1;
            break;
          }
        }
      }
    }

    final int searchLimit = math.min(bytes.length - 18, 0x900);
    int firstMarker = -1;
    int lastMarkerEnd = -1;
    for (int i = 0x1B0; i + 3 < searchLimit; i++) {
      if (bytes[i] == 0x32 && bytes[i + 1] == 0x23 && bytes[i + 2] == 0x32 && bytes[i + 3] == 0x23) {
        if (firstMarker == -1) firstMarker = i;
        int p = i + 4;
        while (p + 1 < searchLimit && bytes[p] == 0x32 && bytes[p + 1] == 0x23) {
          p += 2;
        }
        lastMarkerEnd = p;
        i = p - 1;
      }
    }

    int startPos = 0x538;
    int ky0 = isDhe ? 0x21 : 0x0C;
    int kx0 = isDhe ? 0x33 : 0x25;

    final int winStart = firstMarker != -1 ? math.max(0x1B0, firstMarker - 8) : 0x1B0;
    final int winEnd = math.min(
      bytes.length - 9,
      firstMarker != -1 ? firstMarker + 56 : math.min(bytes.length - 9, 0x900),
    );

    bool foundExact = false;

    if (tailA != null && tailB != null) {
      for (int p = winStart; p + 5 < winEnd; p++) {
        final int c0 = bytes[p];
        final int b1 = bytes[p + 1];
        final int b2 = bytes[p + 2];
        final int c1 = bytes[p + 3];
        final int b4 = bytes[p + 4];
        final int b5 = bytes[p + 5];
        final bool matchPair = (b1 == tailA && b2 == tailB) || (b1 == tailB && b2 == tailA);
        if (c0 >= 110 && c1 >= 110 && matchPair && b4 == b1 && b5 == b2) {
          startPos = p;
          ky0 = b1;
          kx0 = b2;
          foundExact = true;
          break;
        }
      }
      if (!foundExact) {
        for (int p = (lastMarkerEnd != -1 ? lastMarkerEnd : winStart); p + 2 < winEnd; p++) {
          final int c0 = bytes[p];
          final int b1 = bytes[p + 1];
          final int b2 = bytes[p + 2];
          final bool matchPair = (b1 == tailA && b2 == tailB) || (b1 == tailB && b2 == tailA);
          if (c0 >= 110 && matchPair) {
            startPos = p;
            ky0 = b1;
            kx0 = b2;
            foundExact = true;
            break;
          }
        }
      }
    }

    if (!foundExact && firstMarker != -1) {
      for (int p = firstMarker + 2; p + 5 < winEnd; p++) {
        final int c0 = bytes[p];
        final int b1 = bytes[p + 1];
        final int b2 = bytes[p + 2];
        final int c1 = bytes[p + 3];
        if (c0 >= 110 && c1 >= 110 && b1 < 61 && b2 < 61 && b1 != b2 && bytes[p + 4] == b1 && bytes[p + 5] == b2) {
          startPos = p;
          ky0 = b1;
          kx0 = b2;
          foundExact = true;
          break;
        }
      }
    }

    if (!foundExact) {
      if (firstMarker != -1 && firstMarker + 18 < bytes.length) {
        startPos = firstMarker + 16;
      } else if (lastMarkerEnd != -1 && lastMarkerEnd + 6 < bytes.length) {
        startPos = lastMarkerEnd;
      } else if (bytes.length > 0x1B2 && bytes[0x1B0] == 0x06 && bytes[0x1B1] == 0x35) {
        int pos = 0x1B0;
        while (pos + 2 <= bytes.length && bytes[pos] == 0x06 && bytes[pos + 1] == 0x35) {
          pos += 2;
        }
        startPos = pos + 16;
      }
      if (startPos + 2 < bytes.length && bytes[startPos + 1] < 61 && bytes[startPos + 2] < 61) {
        ky0 = bytes[startPos + 1];
        kx0 = bytes[startPos + 2];
      }
    }

    if (stitchEndPos <= startPos) {
      stitchEndPos = math.max(startPos, bytes.length - 24);
    }

    return (startPos, stitchEndPos, ky0, kx0, endByte);
  }

  static (int, int) _detectRing3Keys(Uint8List bytes, int startPos, int endPos, int ky0, int kx0) {
    final List<int> freq = List<int>.filled(83, 0);
    final List<int> zeroFreq = List<int>.filled(83, 0);
    bool ring1Flipped = false;

    for (int p = startPos; p + 2 < endPos; p += 3) {
      final int c = bytes[p];
      final int b1 = bytes[p + 1];
      final int b2 = bytes[p + 2];
      final int curKy = ring1Flipped ? kx0 : ky0;
      final int curKx = ring1Flipped ? ky0 : kx0;

      if (c >= 110 && c <= 192) {
        final int r = c - 110;
        if (b1 == curKy && b2 == curKx) {
          zeroFreq[r]++;
        } else {
          freq[r]++;
        }
      }

      if (b1 >= 61 && b1 <= 192) ring1Flipped = !ring1Flipped;
      if (b2 >= 61 && b2 <= 192) ring1Flipped = !ring1Flipped;
    }

    final int firstCmd = (startPos < bytes.length) ? bytes[startPos] : -1;
    final int firstR = (firstCmd >= 110 && firstCmd <= 192) ? _mod(firstCmd - 110 - 51, 83) : -1;

    double bestScore = -1e9;
    int bestA = 20;
    int bestB = 30;

    for (int a = 0; a < 83; a++) {
      final int a1 = a;
      final int a2 = (a + 32) % 83;
      final int a3 = (a + 51) % 83;
      final int sA = freq[a1] + freq[a2] + freq[a3];
      if (sA == 0 && a != firstR) continue;

      for (int b = a + 1; b < 83; b++) {
        final int b1 = b;
        final int b2 = (b + 32) % 83;
        final int b3 = (b + 51) % 83;
        if (b1 == a1 || b1 == a2 || b1 == a3 || b2 == a1 || b2 == a2 || b2 == a3 || b3 == a1 || b3 == a2 || b3 == a3) {
          continue;
        }
        final int sB = freq[b1] + freq[b2] + freq[b3];
        double score = (sA + sB).toDouble();

        final jSet = {
          (a1 + 1) % 83, (a3 + 1) % 83,
          (b1 + 1) % 83, (b3 + 1) % 83,
        };
        for (final j in jSet) {
          if (j != a1 && j != a2 && j != a3 && j != b1 && j != b2 && j != b3) {
            score += freq[j] * 0.25;
          }
        }

        for (final slot in [a1, a2, a3, b1, b2, b3]) {
          if (zeroFreq[slot] > 2 && freq[slot] == 0) {
            score -= 50.0;
          }
        }

        if (firstR != -1 && (a == firstR || b == firstR)) {
          score += 2.5;
        }

        if (score > bestScore) {
          bestScore = score;
          bestA = a;
          bestB = b;
        }
      }
    }

    return (bestA, bestB);
  }

  static (int, int) _detectRing4Keys(
    Uint8List bytes,
    int startPos,
    int endPos,
    int ky0,
    int kx0,
    int? endByte,
  ) {
    final List<int> stitchCnt = List<int>.filled(63, 0);
    final List<int> zeroCnt = List<int>.filled(63, 0);
    final List<int> seqCnt = List<int>.filled(63, 0);
    final List<int> jumpCnt = List<int>.filled(63, 0);

    bool ring1Flipped = false;

    for (int p = startPos; p + 2 < endPos; p += 3) {
      final int c = bytes[p];
      final int b1 = bytes[p + 1];
      final int b2 = bytes[p + 2];

      final int ky = ring1Flipped ? kx0 : ky0;
      int kx = ring1Flipped ? ky0 : kx0;

      final bool f1 = b1 >= 61 && b1 <= 192;
      if (f1) {
        ring1Flipped = !ring1Flipped;
        kx = ring1Flipped ? ky0 : kx0;
      }
      final bool f2 = b2 >= 61 && b2 <= 192;
      if (f2) {
        ring1Flipped = !ring1Flipped;
      }

      if (c >= 193 && c <= 255) {
        final int r = c - 193;
        if (f1 || f2) {
          jumpCnt[r]++;
        } else if (b1 < 61 && b2 < 61) {
          final int dy = _mod(b1 - ky, 61);
          final int dx = _mod(b2 - kx, 61);
          if (dy == 0 && dx == 0) {
            zeroCnt[r]++;
          } else if (_isSequinOrStopPayload(false, false, dy, dx)) {
            seqCnt[r]++;
          } else {
            stitchCnt[r]++;
          }
        }
      }
    }

    final int? knownFromEnd = (endByte != null && endByte >= 193) ? _mod(endByte - 193 - 24, 63) : null;

    double bestPairScore = -1e18;
    int bestA = knownFromEnd ?? 20;
    int bestB = (bestA + 10) % 63;

    for (int a = 0; a < 63; a++) {
      for (int b = a + 1; b < 63; b++) {
        final int seqA = _mod(a - 9, 63);
        final int seqB = _mod(b - 9, 63);
        final int j1A = (a + 1) % 63;
        final int j1B = (b + 1) % 63;
        final int j2A = (a + 32) % 63;
        final int j2B = (b + 32) % 63;

        final int act = stitchCnt[a] + stitchCnt[b] + jumpCnt[a] + jumpCnt[b] +
            seqCnt[seqA] + seqCnt[seqB] + zeroCnt[seqA] + zeroCnt[seqB] +
            jumpCnt[j1A] + jumpCnt[j1B] + jumpCnt[j2A] + jumpCnt[j2B];
        if (act == 0 && a != knownFromEnd && b != knownFromEnd) continue;

        double score = 0.0;

        if (knownFromEnd != null && (a == knownFromEnd || b == knownFromEnd)) {
          score += 100000.0;
        }

        score += (stitchCnt[a] + stitchCnt[b]) * 5.0;
        if (stitchCnt[a] == 0 && jumpCnt[a] == 0) score -= 10000.0;
        if (stitchCnt[b] == 0 && jumpCnt[b] == 0) score -= 10000.0;

        score += (seqCnt[seqA] + seqCnt[seqB]) * 4.0 + (zeroCnt[seqA] + zeroCnt[seqB]) * 50.0;
        score += (jumpCnt[j1A] + jumpCnt[j1B]) * 3.0 + (jumpCnt[j2A] + jumpCnt[j2B]) * 6.0;

        if (zeroCnt[a] > 0 && a != seqB) score -= zeroCnt[a] * 80.0;
        if (zeroCnt[b] > 0 && b != seqA) score -= zeroCnt[b] * 80.0;

        if (stitchCnt[a] > 0 && stitchCnt[b] > 0) {
          final double ratio = math.min(stitchCnt[a], stitchCnt[b]) / math.max(stitchCnt[a], stitchCnt[b]);
          score += ratio * 500.0;
        }

        if (score > bestPairScore) {
          bestPairScore = score;
          bestA = a;
          bestB = b;
        }
      }
    }

    return (bestA, bestB);
  }

  static int _decodeRing3Coord(int b, int r3A, int r3B) {
    final int k3A = _mod(r3A - 18, 83);
    final int k3B = _mod(r3B - 18, 83);
    final int dA = _mod(b - 110 - k3A, 83);
    final int dB = _mod(b - 110 - k3B, 83);
    final int d = math.min(dA, dB);
    return 110 + (d <= 17 ? d : 11);
  }

  static (int, int) _detectRing2Keys(
    Uint8List bytes,
    int startPos,
    int endPos,
    int ky0,
    int kx0,
    int r3A,
    int r3B,
    Map<int, (int, int)> stitchSignMap,
    Map<int, (int, int)> jumpSignMap,
    Set<int> specialCmds,
    int? endByte,
  ) {
    if (ky0 == 0x21 && kx0 == 0x33) return (45, 37);

    final List<int> histS0 = List<int>.filled(49, 0);
    final List<int> histS1 = List<int>.filled(49, 0);
    final List<double> diffVotes = List<double>.filled(49, 0.0);
    bool hasDiffVotes = false;

    final List<_R2Coord> r2X = [];
    final List<_R2Coord> r2Y = [];
    int xR1 = 0;
    int yR1 = 0;

    bool ring1Flipped = false;
    bool ring2Flipped = false;
    int lastYState = -1, lastYVal = -1, lastYIdx = -10;
    int lastXState = -1, lastXVal = -1, lastXIdx = -10;
    int stitchIdx = 0;

    for (int p = startPos; p + 2 < endPos; p += 3) {
      final int cmd = bytes[p];
      final int b1 = bytes[p + 1];
      final int b2 = bytes[p + 2];

      if (endByte != null && cmd == endByte && ((b1 == ky0 && b2 == kx0) || (b1 == kx0 && b2 == ky0))) {
        break;
      }
      if (cmd == 0x00 && b1 == 0x00 && b2 == 0x00) break;

      int? dyR1;
      int? yR2St;
      int? yR2Val;
      bool flip1 = false;

      if (b1 < 61) {
        final int curKy = ring1Flipped ? kx0 : ky0;
        dyR1 = _mod(b1 - curKy, 61);
      } else if (b1 <= 109) {
        final int v = b1 - 61;
        final int st = ring2Flipped ? 1 : 0;
        if (st == 0) {
          histS0[v]++;
        } else {
          histS1[v]++;
        }
        if (lastYState != -1 && lastYState != st && (stitchIdx - lastYIdx) <= 2) {
          final int d = st == 1 ? _mod(v - lastYVal, 49) : _mod(lastYVal - v, 49);
          diffVotes[d] += 2.0;
          diffVotes[_mod(d - 1, 49)] += 0.6;
          diffVotes[_mod(d + 1, 49)] += 0.6;
          hasDiffVotes = true;
        }
        lastYState = st;
        lastYVal = v;
        lastYIdx = stitchIdx;
        yR2St = st;
        yR2Val = v;
        flip1 = true;
        ring1Flipped = !ring1Flipped;
        ring2Flipped = !ring2Flipped;
      } else if (b1 <= 192) {
        dyR1 = _decodeRing3Coord(b1, r3A, r3B);
        flip1 = true;
        ring1Flipped = !ring1Flipped;
      } else {
        stitchIdx++;
        continue;
      }

      int? dxR1;
      int? xR2St;
      int? xR2Val;
      bool flip2 = false;

      if (b2 < 61) {
        final int curKx = ring1Flipped ? ky0 : kx0;
        dxR1 = _mod(b2 - curKx, 61);
      } else if (b2 <= 109) {
        final int v = b2 - 61;
        final int st = ring2Flipped ? 1 : 0;
        if (st == 0) {
          histS0[v]++;
        } else {
          histS1[v]++;
        }
        if (lastXState != -1 && lastXState != st && (stitchIdx - lastXIdx) <= 2) {
          final int d = st == 1 ? _mod(v - lastXVal, 49) : _mod(lastXVal - v, 49);
          diffVotes[d] += 2.0;
          diffVotes[_mod(d - 1, 49)] += 0.6;
          diffVotes[_mod(d + 1, 49)] += 0.6;
          hasDiffVotes = true;
        }
        lastXState = st;
        lastXVal = v;
        lastXIdx = stitchIdx;
        xR2St = st;
        xR2Val = v;
        flip2 = true;
        ring1Flipped = !ring1Flipped;
        ring2Flipped = !ring2Flipped;
      } else if (b2 <= 192) {
        dxR1 = _decodeRing3Coord(b2, r3A, r3B);
        flip2 = true;
        ring1Flipped = !ring1Flipped;
      } else {
        stitchIdx++;
        continue;
      }

      final bool isSpecial = _isSequinOrStopPayload(flip1, flip2, dyR1 ?? 99, dxR1 ?? 99);
      final bool isSpecialCmd = specialCmds.contains(cmd) &&
          (!stitchSignMap.containsKey(cmd) || isSpecial) &&
          (!jumpSignMap.containsKey(cmd) || isSpecial);

      if (!isSpecialCmd) {
        final (int, int)? s = stitchSignMap[cmd] ?? jumpSignMap[cmd];
        if (s != null) {
          if (dyR1 != null) {
            yR1 += s.$2 * dyR1;
          } else if (yR2St != null && yR2Val != null) {
            r2Y.add(_R2Coord(s.$2, yR2St, yR2Val));
          }
          if (dxR1 != null) {
            xR1 += s.$1 * dxR1;
          } else if (xR2St != null && xR2Val != null) {
            r2X.add(_R2Coord(s.$1, xR2St, xR2Val));
          }
        }
      }

      stitchIdx++;
    }

    int fitSingle(List<int> hist) {
      int total = 0;
      for (final v in hist) {
        total += v;
      }
      if (total == 0) return 0;

      int bestK = 0;
      int minCost = 1 << 60;
      for (int k = 0; k < 49; k++) {
        int cost = 0;
        for (int b = 0; b < 49; b++) {
          if (hist[b] > 0) {
            final int d = _mod(b - k, 49);
            cost += hist[b] * (d + (d > 25 ? d * d : 0));
          }
        }
        if (cost < minCost) {
          minCost = cost;
          bestK = k;
        }
      }
      return bestK;
    }

    if (r2X.isEmpty && r2Y.isEmpty) {
      return (0, 0);
    }

    if (hasDiffVotes) {
      int bestDiff = 0;
      double maxVote = -1.0;
      for (int d = 0; d < 49; d++) {
        if (diffVotes[d] > maxVote) {
          maxVote = diffVotes[d];
          bestDiff = d;
        }
      }

      int bestK0 = 0;
      double bestObj = 1e18;

      for (int k0 = 0; k0 < 49; k0++) {
        final int k1 = (k0 + bestDiff) % 49;
        int fx = xR1;
        for (final ev in r2X) {
          final int k = ev.state == 0 ? k0 : k1;
          fx += ev.sign * (61 + _mod(ev.val - k, 49));
        }
        int fy = yR1;
        for (final ev in r2Y) {
          final int k = ev.state == 0 ? k0 : k1;
          fy += ev.sign * (61 + _mod(ev.val - k, 49));
        }
        final double closure = (fx.abs() + fy.abs()).toDouble();

        double tieBreak = 0.0;
        for (int b = 0; b < 49; b++) {
          if (histS0[b] > 0) {
            final int d = _mod(b - k0, 49);
            if (d > 30) tieBreak += histS0[b] * (d - 30) * 0.02;
          }
          if (histS1[b] > 0) {
            final int d = _mod(b - k1, 49);
            if (d > 30) tieBreak += histS1[b] * (d - 30) * 0.02;
          }
        }

        final double obj = closure + tieBreak;
        if (obj < bestObj) {
          bestObj = obj;
          bestK0 = k0;
        }
      }

      return (bestK0, (bestK0 + bestDiff) % 49);
    }

    return (fitSingle(histS0), fitSingle(histS1));
  }
}


// ---------------------------------------------------------------------------
// محرك الصيغ القياسية الإضافية (.EXP, .DSB, .JEF, .PES, .PEC, .TBF) + التصدير إلى .DST
// ---------------------------------------------------------------------------

class UniversalFormatParser {
  static bool isSupported(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.exp') ||
        lower.endsWith('.dsb') ||
        lower.endsWith('.jef') ||
        lower.endsWith('.pes') ||
        lower.endsWith('.pec') ||
        lower.endsWith('.tbf') ||
        lower.endsWith('.xxx');
  }

  static Future<EmbDesignInfo?> parseFile(String filePath, {double maxCanvas = 1200.0}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final VectorDesignData? vec = await Isolate.run(() => _decodeAnySync(filePath));
      if (vec == null) return null;

      Uint8List? previewPng;
      if (vec.stX.length > 2) {
        previewPng = await _renderVectorDesignToImage(vec, maxCanvas: maxCanvas);
      }

      final fileName = filePath.split(Platform.pathSeparator).last;
      return EmbDesignInfo(
        filePath: filePath,
        fileName: fileName,
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
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> renderHighResPreview(String filePath, {double maxCanvas = 2200.0, bool is3D = false}) async {
    try {
      final VectorDesignData? vec = await Isolate.run(() => _decodeAnySync(filePath));
      if (vec == null || vec.stX.length <= 2) return null;
      return await _renderVectorDesignToImage(vec, maxCanvas: maxCanvas, is3D: is3D, transparentBg: true);
    } catch (_) {
      return null;
    }
  }

  /// كشف الصيغة الحقيقية من البايتات الداخلية للملف (يحل مشكلة ملفات واتساب .BIN بشكل جذري)
  static String detectFormatByContent(Uint8List bytes) {
    final int len = bytes.length;
    if (len < 16) return '';
    final bd = ByteData.sublistView(bytes);

    // 1) Wilcom OLE2 (.EMB)
    if (bytes[0] == 0xD0 && bytes[1] == 0xCF && bytes[2] == 0x11 && bytes[3] == 0xE0) {
      return '.emb';
    }
    // 2) Tajima (.DST)
    if (len >= 512) {
      final hdr = latin1.decode(bytes.sublist(0, 512), allowInvalid: true);
      if (hdr.startsWith('LA:') || (hdr.contains('ST:') && hdr.contains('+X:') && hdr.contains('-X:'))) {
        return '.dst';
      }
    }
    // 3) Brother (.PES / .PEC)
    if (bytes[0] == 0x23 && bytes[1] == 0x50 && bytes[2] == 0x45) {
      if (bytes[3] == 0x53) return '.pes';
      if (bytes[3] == 0x43) return '.pec';
    }
    // 4) Dahao (.DHP): UTF-16LE "Default" in emCAD header
    if (len >= 0x2000) {
      const defUtf16 = [0x44, 0x00, 0x65, 0x00, 0x66, 0x00, 0x61, 0x00, 0x75, 0x00, 0x6C, 0x00, 0x74, 0x00];
      final int lim = math.min(len - defUtf16.length, 0x1F00);
      for (int i = 0x1000; i <= lim; i++) {
        bool ok = true;
        for (int j = 0; j < defUtf16.length; j++) {
          if (bytes[i + j] != defUtf16[j]) {
            ok = false;
            break;
          }
        }
        if (ok) return '.dhp';
      }
    }
    // 5) Dahao (.DHE / .DHA): sync markers 0x32 0x23 or 0x06 0x35
    if (len > 0x200) {
      final int lim = math.min(len - 4, 0x900);
      for (int i = 0x1B0; i < lim; i++) {
        if ((bytes[i] == 0x32 && bytes[i + 1] == 0x23 && bytes[i + 2] == 0x32 && bytes[i + 3] == 0x23) ||
            (bytes[i] == 0x06 && bytes[i + 1] == 0x35 && bytes[i + 2] == 0x06 && bytes[i + 3] == 0x35)) {
          return '.dhe';
        }
      }
    }
    // 6) Janome (.JEF)
    if (len >= 120) {
      final int stOff = bd.getUint32(0, Endian.little);
      final int flg = bd.getUint32(4, Endian.little);
      final int cols = bd.getUint32(24, Endian.little);
      if (stOff >= 116 && stOff < len - 4 && cols >= 1 && cols <= 127) {
        if (stOff == 116 + cols * 8 || flg == 0x0A) {
          return '.jef';
        }
      }
    }
    // 7) Singer (.XXX): 256-byte zero-padded header + 0x7F 0x7F end marker or stitch/color fields
    if (len >= 260) {
      int zeroHdr = 0;
      for (int i = 0; i < 24; i++) {
        if (bytes[i] == 0) zeroHdr++;
      }
      final int xxxStitches = bd.getUint32(0x1B, Endian.little);
      final int xxxColors = bd.getUint16(0x27, Endian.little);
      bool hasXxxEnd = false;
      final int tailStart = math.max(256, len - 1024);
      for (int i = tailStart; i < len - 1; i++) {
        if (bytes[i] == 0x7F && bytes[i + 1] == 0x7F) {
          hasXxxEnd = true;
          break;
        }
      }
      if (zeroHdr >= 18 && (hasXxxEnd || (xxxStitches >= 1 && xxxStitches <= 5000000 && xxxColors >= 1 && xxxColors <= 128))) {
        return '.xxx';
      }
    }
    // 8) Tajima Modern (.TBF): 0x600 header + 0x8F end control byte
    if (len >= 0x606) {
      int hdrZeroOrAscii = 0;
      for (int i = 0; i < 256; i++) {
        final int v = bytes[i];
        if (v == 0 || (v >= 0x20 && v <= 0x7E)) hdrZeroOrAscii++;
      }
      if (hdrZeroOrAscii >= 245 && (bytes[len - 1] == 0x8F || bytes[len - 3] == 0x8F)) {
        return '.tbf';
      }
    }
    // 9) Barudan (.DSB): 512-byte space/ASCII header + 0x80+ ctrl bytes
    if (len >= 518) {
      int asciiHdr = 0;
      for (int i = 0; i < 512; i++) {
        final int v = bytes[i];
        if (v == 0x20 || v == 0x00 || (v >= 0x21 && v <= 0x7E)) asciiHdr++;
      }
      int ctrlOk = 0, checked = 0;
      for (int p = 512; p + 2 < len && checked < 20; p += 3) {
        if ((bytes[p] & 0x80) != 0) ctrlOk++;
        checked++;
      }
      if (asciiHdr >= 500 && checked > 5 && ctrlOk == checked) {
        return '.dsb';
      }
    }
    // 10) Melco (.EXP) — الملاذ الأخير لأن EXP لا يحتوي على ترويسة
    return '.exp';
  }

  /// فحص ذكي لمحتوى الملف عند فتحه من واتساب بلاحقة مختلفة أو .bin
  static Future<EmbDesignInfo?> parseByContentFallback(String filePath, {double maxCanvas = 640.0}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length < 16) return null;

      final String detected = detectFormatByContent(bytes);
      if (detected == '.emb') {
        return await EmbParser.parseFile(filePath);
      }
      if (detected == '.dst') {
        return await DstParser.parseFile(filePath, maxCanvas: maxCanvas);
      }
      if (detected == '.dhp' || detected == '.dhe') {
        final vec = await Isolate.run(() {
          if (detected == '.dhp') return DahaoParser._decodeDhpSync(filePath);
          return DahaoParser._decodeDheDhaSync(filePath, true);
        });
        if (vec != null && vec.stX.length > 2) return await _vecToInfo(filePath, vec, maxCanvas);
      }

      final VectorDesignData? vec = await Isolate.run(() {
        switch (detected) {
          case '.pes':
            return _decodePesSync(bytes);
          case '.pec':
            return _decodePecSync(bytes, 8, 'Brother (PEC)');
          case '.jef':
            return _decodeJefSync(bytes);
          case '.xxx':
            return _decodeXxxSync(bytes);
          case '.tbf':
            return _decodeTbfSync(bytes);
          case '.dsb':
            return _decodeDsbSync(bytes);
          case '.exp':
            return _decodeExpSync(bytes);
          default:
            return null;
        }
      });
      if (vec != null && vec.stX.length > 2) {
        return await _vecToInfo(filePath, vec, maxCanvas);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<EmbDesignInfo> _vecToInfo(String filePath, VectorDesignData vec, double maxCanvas) async {
    final previewPng = await _renderVectorDesignToImage(vec, maxCanvas: maxCanvas);
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

  static VectorDesignData? _decodeAnySync(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    final lower = filePath.toLowerCase();

    if (lower.endsWith('.exp')) return _decodeExpSync(bytes);
    if (lower.endsWith('.dsb')) return _decodeDsbSync(bytes);
    if (lower.endsWith('.jef')) return _decodeJefSync(bytes);
    if (lower.endsWith('.pes')) return _decodePesSync(bytes);
    if (lower.endsWith('.pec')) return _decodePecSync(bytes, 0, 'Brother (PEC)');
    if (lower.endsWith('.tbf')) return _decodeTbfSync(bytes);
    if (lower.endsWith('.xxx')) return _decodeXxxSync(bytes);
    return null;
  }

  static int _s8(int b) => b >= 128 ? b - 256 : b;

  static final Int32List _defaultPalette = Int32List.fromList(const [
    0xFF007BFF, 0xFFFF1744, 0xFF00C853, 0xFFFFB300, 0xFFD500F9,
    0xFFFF5722, 0xFF00E5FF, 0xFFFF007F, 0xFF76FF03, 0xFF3D5AFE,
    0xFF00BFA5, 0xFFFF6D00, 0xFF651FFF, 0xFFFFD600,
  ]);

  static final Int32List _pecPalette = Int32List.fromList(const [
    0xFF000000, 0xFF0E1F7C, 0xFF0A55A3, 0xFF008777, 0xFF4B6BAF, 0xFFED171F,
    0xFFD15C00, 0xFF913697, 0xFFE4995A, 0xFF915C96, 0xFF9ED67D, 0xFF77431E,
    0xFF000000, 0xFFFFF000, 0xFF009900, 0xFF0000FF, 0xFFFF0000, 0xFFFF7F00,
    0xFF800080, 0xFF00FFFF, 0xFFFF00FF, 0xFF808080, 0xFF336699, 0xFFCC3366,
    0xFF669933, 0xFFCC9900, 0xFF993333, 0xFF339966, 0xFF663399, 0xFFCC6633,
    0xFF3366CC, 0xFF996633, 0xFF3399CC, 0xFFCC3399, 0xFF66CC33, 0xFFCC3333,
    0xFF33CC99, 0xFF9933CC, 0xFFCCCC33, 0xFF3333CC, 0xFFCC9966, 0xFF6699CC,
    0xFF99CC66, 0xFFCC6699, 0xFF66CC99, 0xFF9966CC, 0xFFCC9933, 0xFF339999,
    0xFF993399, 0xFF999933, 0xFF666699, 0xFF996666, 0xFF669966, 0xFF333366,
    0xFF663333, 0xFF336633, 0xFF999999, 0xFF666666, 0xFF333333, 0xFFCCCCCC,
    0xFFFF9999, 0xFF99FF99, 0xFF9999FF, 0xFFFFFF99, 0xFFFF99FF,
  ]);

  /// Melco / Bernina (.EXP)
  static VectorDesignData? _decodeExpSync(Uint8List bytes) {
    if (bytes.length < 4) return null;
    final stX = _Float32Buf(8192);
    final stY = _Float32Buf(8192);
    final stMove = _Uint8Buf(8192);
    final stColor = _Uint8Buf(8192);

    int x = 0, y = 0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int colorIdx = 0;
    int colorCount = 1;
    int stitchCount = 0;
    int jumpCount = 0;
    bool needMove = true;

    int i = 0;
    while (i + 1 < bytes.length) {
      final int b0 = bytes[i];
      final int b1 = bytes[i + 1];
      i += 2;

      if (b0 == 0x80) {
        if (b1 == 0x01) {
          colorIdx = (colorIdx + 1) % _defaultPalette.length;
          colorCount++;
          needMove = true;
          if (i + 1 < bytes.length) i += 2;
        } else if (b1 == 0x04) {
          if (i + 1 < bytes.length) {
            x += _s8(bytes[i]);
            y += _s8(bytes[i + 1]);
            i += 2;
          }
          jumpCount++;
          needMove = true;
        } else if (b1 == 0x80 || b1 == 0x00) {
          break;
        } else {
          needMove = true;
        }
      } else {
        x += _s8(b0);
        y += _s8(b1);
        final double px = x.toDouble();
        final double py = -y.toDouble();
        stX.add(px);
        stY.add(py);
        stMove.add(needMove ? 1 : 0);
        stColor.add(colorIdx);
        needMove = false;
        stitchCount++;
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
      paletteArgb: _defaultPalette,
      stitches: stitchCount,
      colorCount: colorCount,
      stopsCount: colorCount > 1 ? colorCount - 1 : 0,
      jumpsCount: jumpCount,
      sequinsCount: 0,
      beadsCount: 0,
      trimsCount: 0,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      hasBounds: hasBounds,
      machineType: 'Melco (EXP)',
    );
  }

  /// Barudan (.DSB)
  static VectorDesignData? _decodeDsbSync(Uint8List bytes) {
    if (bytes.length < 515) return null;
    final stX = _Float32Buf(8192);
    final stY = _Float32Buf(8192);
    final stMove = _Uint8Buf(8192);
    final stColor = _Uint8Buf(8192);

    int x = 0, y = 0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int colorIdx = 0;
    int colorCount = 1;
    int stitchCount = 0;
    int jumpCount = 0;
    bool needMove = true;

    for (int i = 512; i + 2 < bytes.length; i += 3) {
      final int ctrl = bytes[i];
      int dy = bytes[i + 1];
      int dx = bytes[i + 2];

      if (ctrl == 0xF8) break;
      if ((ctrl & 0x40) != 0) dy = -dy;
      if ((ctrl & 0x20) != 0) dx = -dx;

      x += dx;
      y += dy;

      final int cmd = ctrl & 0x1F;
      if (cmd == 0x08 || cmd == 0x09 || cmd == 0x0A) {
        colorIdx = (colorIdx + 1) % _defaultPalette.length;
        colorCount++;
        needMove = true;
      } else if (cmd == 0x01 || cmd == 0x04) {
        jumpCount++;
        needMove = true;
      } else {
        final double px = x.toDouble();
        final double py = -y.toDouble();
        stX.add(px);
        stY.add(py);
        stMove.add(needMove ? 1 : 0);
        stColor.add(colorIdx);
        needMove = false;
        stitchCount++;
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
      paletteArgb: _defaultPalette,
      stitches: stitchCount,
      colorCount: colorCount,
      stopsCount: colorCount > 1 ? colorCount - 1 : 0,
      jumpsCount: jumpCount,
      sequinsCount: 0,
      beadsCount: 0,
      trimsCount: 0,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      hasBounds: hasBounds,
      machineType: 'Barudan (DSB)',
    );
  }

  /// Janome (.JEF)
  static VectorDesignData? _decodeJefSync(Uint8List bytes) {
    if (bytes.length < 120) return null;
    final bd = ByteData.sublistView(bytes);
    final int stitchOffset = bd.getUint32(0, Endian.little);
    final int rawColors = bd.getUint32(24, Endian.little);
    if (stitchOffset < 116 || stitchOffset >= bytes.length) return null;

    final stX = _Float32Buf(8192);
    final stY = _Float32Buf(8192);
    final stMove = _Uint8Buf(8192);
    final stColor = _Uint8Buf(8192);

    int x = 0, y = 0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int colorIdx = 0;
    int colorCount = 1;
    int stitchCount = 0;
    int jumpCount = 0;
    bool needMove = true;

    int i = stitchOffset;
    while (i + 1 < bytes.length) {
      final int b0 = bytes[i];
      final int b1 = bytes[i + 1];
      i += 2;

      if (b0 == 0x80) {
        if (b1 == 0x01) {
          colorIdx = (colorIdx + 1) % _defaultPalette.length;
          colorCount++;
          needMove = true;
        } else if (b1 == 0x02 || b1 == 0x04) {
          if (i + 1 < bytes.length) {
            x += _s8(bytes[i]);
            y += _s8(bytes[i + 1]);
            i += 2;
          }
          jumpCount++;
          needMove = true;
        } else if (b1 == 0x10) {
          break;
        } else {
          needMove = true;
        }
      } else {
        x += _s8(b0);
        y += _s8(b1);
        final double px = x.toDouble();
        final double py = -y.toDouble();
        stX.add(px);
        stY.add(py);
        stMove.add(needMove ? 1 : 0);
        stColor.add(colorIdx);
        needMove = false;
        stitchCount++;
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

    final int validColors = (rawColors > 0 && rawColors < 128) ? rawColors : colorCount;
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
      paletteArgb: _defaultPalette,
      stitches: stitchCount,
      colorCount: validColors,
      stopsCount: validColors > 1 ? validColors - 1 : 0,
      jumpsCount: jumpCount,
      sequinsCount: 0,
      beadsCount: 0,
      trimsCount: 0,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      hasBounds: hasBounds,
      machineType: 'Janome (JEF)',
    );
  }

  /// Brother (.PES -> يستخرج قسم PEC المدمج)
  static VectorDesignData? _decodePesSync(Uint8List bytes) {
    if (bytes.length < 32) return null;
    final bd = ByteData.sublistView(bytes);
    int pecStart = -1;
    if (bytes[0] == 0x23 && bytes[1] == 0x50 && bytes[2] == 0x45 && bytes[3] == 0x53) {
      final int off = bd.getUint32(8, Endian.little);
      if (off > 0 && off + 512 < bytes.length) {
        pecStart = off;
      }
    }
    if (pecStart == -1) {
      // بحث عن علامة #PEC0001
      for (int i = 0; i + 8 < bytes.length; i++) {
        if (bytes[i] == 0x23 && bytes[i + 1] == 0x50 && bytes[i + 2] == 0x45 && bytes[i + 3] == 0x43) {
          pecStart = i + 8;
          break;
        }
      }
    }
    if (pecStart == -1) return null;
    return _decodePecSync(bytes, pecStart, 'Brother (PES)');
  }

  /// Brother (.PEC)
  static VectorDesignData? _decodePecSync(Uint8List bytes, int baseOff, String machineLabel) {
    if (baseOff + 532 >= bytes.length) return null;
    final int colorChanges = bytes[baseOff + 48];
    final int numColors = colorChanges + 1;

    final List<int> paletteList = [];
    for (int c = 0; c < numColors && (baseOff + 49 + c) < bytes.length; c++) {
      final int idx = bytes[baseOff + 49 + c];
      paletteList.add(_pecPalette[idx % _pecPalette.length]);
    }
    final Int32List palette = paletteList.isNotEmpty ? Int32List.fromList(paletteList) : _defaultPalette;

    int i = baseOff + 532;
    // تجاوز ترويسة PEC الفرعية (0x00, 0x00, ... حتى بداية الغرز)
    if (baseOff + 512 + 2 < bytes.length) {
      final int graphicOff = bytes[baseOff + 514] | (bytes[baseOff + 515] << 8) | (bytes[baseOff + 516] << 16);
      if (graphicOff <= 0) {
        i = baseOff + 532;
      }
    }

    final stX = _Float32Buf(8192);
    final stY = _Float32Buf(8192);
    final stMove = _Uint8Buf(8192);
    final stColor = _Uint8Buf(8192);

    int x = 0, y = 0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int colorIdx = 0;
    int stitchCount = 0;
    int jumpCount = 0;
    bool needMove = true;

    while (i + 1 < bytes.length) {
      final int b0 = bytes[i];
      if (b0 == 0xFF) break;
      if (b0 == 0xFE && bytes[i + 1] == 0xB0) {
        i += 3;
        colorIdx = (colorIdx + 1) % palette.length;
        needMove = true;
        continue;
      }

      bool isJump = false;
      int dx;
      if ((b0 & 0x80) != 0) {
        if ((b0 & 0x20) != 0 || (b0 & 0x10) != 0) isJump = true;
        if (i + 1 >= bytes.length) break;
        int val = ((b0 & 0x0F) << 8) | bytes[i + 1];
        if (val >= 2048) val -= 4096;
        dx = val;
        i += 2;
      } else {
        dx = b0 >= 64 ? b0 - 128 : b0;
        i += 1;
      }

      if (i >= bytes.length) break;
      final int b1 = bytes[i];
      int dy;
      if ((b1 & 0x80) != 0) {
        if ((b1 & 0x20) != 0 || (b1 & 0x10) != 0) isJump = true;
        if (i + 1 >= bytes.length) break;
        int val = ((b1 & 0x0F) << 8) | bytes[i + 1];
        if (val >= 2048) val -= 4096;
        dy = val;
        i += 2;
      } else {
        dy = b1 >= 64 ? b1 - 128 : b1;
        i += 1;
      }

      x += dx;
      y += dy;
      final double px = x.toDouble();
      final double py = y.toDouble(); // PEC Y لأسفل بالفعل

      if (isJump) {
        jumpCount++;
        needMove = true;
      } else {
        stX.add(px);
        stY.add(py);
        stMove.add(needMove ? 1 : 0);
        stColor.add(colorIdx);
        needMove = false;
        stitchCount++;
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
      paletteArgb: palette,
      stitches: stitchCount,
      colorCount: numColors,
      stopsCount: colorChanges,
      jumpsCount: jumpCount,
      sequinsCount: 0,
      beadsCount: 0,
      trimsCount: 0,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      hasBounds: hasBounds,
      machineType: machineLabel,
    );
  }

  /// Tajima Modern (.TBF)
  static VectorDesignData? _decodeTbfSync(Uint8List bytes) {
    if (bytes.length < 0x603) return null;
    final stX = _Float32Buf(8192);
    final stY = _Float32Buf(8192);
    final stMove = _Uint8Buf(8192);
    final stColor = _Uint8Buf(8192);

    int x = 0, y = 0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int colorIdx = 0;
    int colorCount = 1;
    int stitchCount = 0;
    int jumpCount = 0;
    bool needMove = true;

    for (int i = 0x600; i + 2 < bytes.length; i += 3) {
      final int dx = _s8(bytes[i]);
      final int dy = _s8(bytes[i + 1]);
      final int ctrl = bytes[i + 2];

      if (ctrl == 0x8F) break;
      x += dx;
      y += dy;

      if (ctrl == 0x40 || ctrl == 0x86 || ctrl == 0x87) {
        colorIdx = (colorIdx + 1) % _defaultPalette.length;
        colorCount++;
        needMove = true;
      } else if (ctrl == 0x81 || ctrl == 0x82 || ctrl == 0x84) {
        jumpCount++;
        needMove = true;
      } else {
        final double px = x.toDouble();
        final double py = -y.toDouble();
        stX.add(px);
        stY.add(py);
        stMove.add(needMove ? 1 : 0);
        stColor.add(colorIdx);
        needMove = false;
        stitchCount++;
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
      paletteArgb: _defaultPalette,
      stitches: stitchCount,
      colorCount: colorCount,
      stopsCount: colorCount > 1 ? colorCount - 1 : 0,
      jumpsCount: jumpCount,
      sequinsCount: 0,
      beadsCount: 0,
      trimsCount: 0,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      hasBounds: hasBounds,
      machineType: 'Tajima (TBF)',
    );
  }

  /// Singer (.XXX)
  static VectorDesignData? _decodeXxxSync(Uint8List bytes) {
    if (bytes.length < 260) return null;
    final stX = _Float32Buf(8192);
    final stY = _Float32Buf(8192);
    final stMove = _Uint8Buf(8192);
    final stColor = _Uint8Buf(8192);

    int x = 0, y = 0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int colorIdx = 0;
    int colorCount = 1;
    int stitchCount = 0;
    int jumpCount = 0;
    bool needMove = true;

    int i = 256;
    while (i + 1 < bytes.length) {
      final int b0 = bytes[i];
      final int b1 = bytes[i + 1];
      i += 2;

      if (b0 == 0x7F) {
        if (b1 == 0x7F) {
          break;
        } else if (b1 == 0x08) {
          colorIdx = (colorIdx + 1) % _defaultPalette.length;
          colorCount++;
          needMove = true;
          if (i + 1 < bytes.length && bytes[i] == 0x00 && bytes[i + 1] == 0x00) {
            i += 2;
          }
        } else if (b1 == 0x01 || b1 == 0x03) {
          if (i + 1 < bytes.length) {
            x += _s8(bytes[i]);
            y += _s8(bytes[i + 1]);
            i += 2;
          }
          jumpCount++;
          needMove = true;
        } else {
          needMove = true;
        }
      } else if (b0 == 0x7D || b0 == 0x7E) {
        if (i < bytes.length) {
          x += _s8(b1);
          y += _s8(bytes[i]);
          i += 1;
        }
        jumpCount++;
        needMove = true;
      } else {
        x += _s8(b0);
        y += _s8(b1);
        final double px = x.toDouble();
        final double py = -y.toDouble();
        stX.add(px);
        stY.add(py);
        stMove.add(needMove ? 1 : 0);
        stColor.add(colorIdx);
        needMove = false;
        stitchCount++;
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
      paletteArgb: _defaultPalette,
      stitches: stitchCount,
      colorCount: colorCount,
      stopsCount: colorCount > 1 ? colorCount - 1 : 0,
      jumpsCount: jumpCount,
      sequinsCount: 0,
      beadsCount: 0,
      trimsCount: 0,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      hasBounds: hasBounds,
      machineType: 'Singer (XXX)',
    );
  }
}

/// محرك التصدير إلى صيغة تاجيما القياسية (.DST) من أي ملف داهوا أو صيغة متجهية

/// محرك تشفير وفك تشفير ماكينات داهوا الأصلي (3DES + خوارزمية الحلقات الأربع)
/// متوافق 100% مع صيغتي .DHE و .DHA ومع الحفاظ الكامل على أوامر الخرز والترتر
class _DahaoCrypto {
  static const List<int> _keyDhe = [
    0x08, 0x50, 0x18, 0xFF, 0x05, 0x57, 0x10, 0x5E,
    0x1B, 0x10, 0x02, 0x16, 0x14, 0x0D, 0xFA, 0x68,
    0x18, 0x5F, 0x1E, 0x6D, 0x18, 0x76, 0x26, 0x69,
  ];
  static const List<int> _keyDha = [
    0x59, 0x24, 0x5B, 0x26, 0x5D, 0x20, 0x5F, 0x22,
    0x51, 0x2C, 0x59, 0x24, 0x5B, 0x26, 0x5D, 0x20,
    0x5F, 0x22, 0x51, 0x2C, 0x59, 0x24, 0x5B, 0x26,
  ];

  static const List<int> _ip = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8, 57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3, 61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7];
  static const List<int> _ipr = [40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27, 34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25];
  static const List<int> _e = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1];
  static const List<int> _p = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25];
  static const List<int> _pc1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36, 63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4];
  static const List<int> _pc2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2, 41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32];
  static const List<int> _shifts = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
  static const List<int> _sbox = [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13, 15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9, 10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12, 7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14, 2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3, 12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13, 4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12, 13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11];

  static List<Uint8List> _desSubkeys(List<int> key8) {
    final kb = Uint8List(64);
    for (int i = 0; i < 8; i++) {
      final int b = key8[i];
      for (int j = 0; j < 8; j++) {
        kb[i * 8 + j] = (b >> (7 - j)) & 1;
      }
    }
    final c = Uint8List(28);
    final d = Uint8List(28);
    for (int i = 0; i < 28; i++) {
      c[i] = kb[_pc1[i] - 1];
      d[i] = kb[_pc1[i + 28] - 1];
    }
    final List<Uint8List> subs = [];
    for (int r = 0; r < 16; r++) {
      final int sh = _shifts[r];
      final nc = Uint8List(28);
      final nd = Uint8List(28);
      for (int i = 0; i < 28; i++) {
        nc[i] = c[(i + sh) % 28];
        nd[i] = d[(i + sh) % 28];
      }
      for (int i = 0; i < 28; i++) {
        c[i] = nc[i];
        d[i] = nd[i];
      }
      final k48 = Uint8List(48);
      for (int i = 0; i < 48; i++) {
        final int idx = _pc2[i] - 1;
        k48[i] = idx < 28 ? c[idx] : d[idx - 28];
      }
      subs.add(k48);
    }
    return subs;
  }

  static Uint8List _desBlock(Uint8List blk8, List<Uint8List> subs, bool decrypt) {
    final bits = Uint8List(64);
    for (int i = 0; i < 8; i++) {
      final int b = blk8[i];
      for (int j = 0; j < 8; j++) {
        bits[i * 8 + j] = (b >> (7 - j)) & 1;
      }
    }
    final L = Uint8List(32);
    final R = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      L[i] = bits[_ip[i] - 1];
      R[i] = bits[_ip[i + 32] - 1];
    }
    final x = Uint8List(48);
    final sout = Uint8List(32);
    final nextR = Uint8List(32);
    for (int r = 0; r < 16; r++) {
      final Uint8List k = subs[decrypt ? (15 - r) : r];
      for (int i = 0; i < 48; i++) {
        x[i] = R[_e[i] - 1] ^ k[i];
      }
      for (int s = 0; s < 8; s++) {
        final int o = s * 6;
        final int row = (x[o] << 1) | x[o + 5];
        final int col = (x[o + 1] << 3) | (x[o + 2] << 2) | (x[o + 3] << 1) | x[o + 4];
        final int val = _sbox[s * 64 + row * 16 + col];
        final int so = s * 4;
        sout[so] = (val >> 3) & 1;
        sout[so + 1] = (val >> 2) & 1;
        sout[so + 2] = (val >> 1) & 1;
        sout[so + 3] = val & 1;
      }
      for (int i = 0; i < 32; i++) {
        nextR[i] = L[i] ^ sout[_p[i] - 1];
      }
      for (int i = 0; i < 32; i++) {
        L[i] = R[i];
        R[i] = nextR[i];
      }
    }
    final rl = Uint8List(64);
    for (int i = 0; i < 32; i++) {
      rl[i] = R[i];
      rl[i + 32] = L[i];
    }
    final out = Uint8List(8);
    for (int i = 0; i < 64; i++) {
      if (rl[_ipr[i] - 1] != 0) {
        out[i >> 3] |= (1 << (7 - (i & 7)));
      }
    }
    return out;
  }

  static Uint8List des3Crypt(Uint8List data, bool isDheKey, bool encrypt) {
    final List<int> key = isDheKey ? _keyDhe : _keyDha;
    final k0 = _desSubkeys(key.sublist(0, 8));
    final k1 = _desSubkeys(key.sublist(8, 16));
    final k2 = _desSubkeys(key.sublist(16, 24));
    final int n = data.length & ~7;
    final out = Uint8List(n);
    for (int i = 0; i < n; i += 8) {
      Uint8List b = Uint8List.sublistView(data, i, i + 8);
      if (encrypt) {
        b = _desBlock(_desBlock(_desBlock(b, k2, true), k1, false), k0, true);
      } else {
        b = _desBlock(_desBlock(_desBlock(b, k0, false), k1, true), k2, false);
      }
      out.setRange(i, i + 8, b);
    }
    return out;
  }

  static Uint8List ringCrypt(Uint8List input, int seed16, bool encrypt) {
    int c = seed16 & 0xFFFF;
    if (c < 0x6E) c += 0x6E;
    final k = Int32List(8);
    k[0] = c % 0x61;
    k[1] = (5 * c) % 0x1B;
    if (((k[0] % 0x3D) - (k[1] % 0x3D)).abs() < 6) k[1] += 0x11;
    k[2] = (8 * c) % 0x13;
    k[3] = c % 0x49;
    k[4] = c % 0x21;
    k[5] = (3 * c) % 0x39;
    k[6] = (5 * c) % 0x27;
    k[7] = c % 0x12;
    if (((k[6] % 0x3F) - (k[7] % 0x3F)).abs() < 7) k[7] += 0x11;

    if (encrypt) {
      k[0] = 0x3D - (k[0] % 0x3D);
      k[1] = 0x3D - (k[1] % 0x3D);
      k[2] = 0x31 - (k[2] % 0x31);
      k[3] = 0x31 - (k[3] % 0x31);
      k[4] = 0x53 - (k[4] % 0x53);
      k[5] = 0x53 - (k[5] % 0x53);
      k[6] = 0x3F - (k[6] % 0x3F);
      k[7] = 0x3F - (k[7] % 0x3F);
    }

    int i0 = 0, i1 = 2, i2 = 4, i3 = 6;
    final out = Uint8List(input.length);
    for (int i = 0; i < input.length; i++) {
      final int b = input[i];
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

  /// فك تشفير مباشر ودقيق لملفات .DHE و .DHA باستخراج جدول الأقسام عبر 3DES
  static VectorDesignData? decodeExactDheDha(Uint8List bytes, bool preferDhe, Int32List paletteArgb, int validColors, int hdrStops) {
    if (bytes.length < 0x140) return null;

    // تجربة المفتاح الموافق أولاً ثم البديل (أحياناً يُغيّر المستخدم لاحقة الملف)
    final List<bool> keyOrder = preferDhe ? [true, false] : [false, true];
    int sec6Off = -1;
    int sec6NextOff = -1;
    int sec6Param = 0;
    bool matchedDheKey = preferDhe;
    int sec6HdrXor = 0;

    for (final bool useDheKey in keyOrder) {
      int hdrXor = 0;
      bool hasH8 = false;
      for (int i = 8; i < 16; i++) {
        if (bytes[i] != 0) { hasH8 = true; break; }
      }
      if (hasH8) {
        final decH8 = des3Crypt(Uint8List.sublistView(bytes, 8, 16), useDheKey, false);
        hdrXor = ByteData.sublistView(decH8).getUint16(0, Endian.little);
      }

      final List<(int, int, int)> secs = [];
      int pos = 0x100;
      bool validDir = false;
      for (int e = 0; e < 12 && pos + 16 <= bytes.length; e++, pos += 16) {
        final dec = des3Crypt(Uint8List.sublistView(bytes, pos, pos + 16), useDheKey, false);
        final dbd = ByteData.sublistView(dec);
        final int styp = dbd.getUint32(0, Endian.little);
        final int soff = dbd.getUint32(4, Endian.little);
        final int sparam = dbd.getUint32(8, Endian.little);
        if (styp > 20 || soff < 0x110 || soff > bytes.length) {
          secs.clear();
          break;
        }
        secs.add((styp, soff, sparam));
        if (styp == 0) {
          validDir = secs.length >= 2;
          break;
        }
      }
      if (!validDir) continue;

      for (int i = 0; i < secs.length - 1; i++) {
        if (secs[i].$1 == 6) {
          sec6Off = secs[i].$2;
          sec6NextOff = secs[i + 1].$2;
          sec6Param = secs[i].$3;
          matchedDheKey = useDheKey;
          break;
        }
      }
      if (sec6Off >= 0 && sec6NextOff > sec6Off && sec6NextOff <= bytes.length) {
        sec6HdrXor = hdrXor;
        break;
      }
    }

    if (sec6Off < 0 || sec6NextOff <= sec6Off) return null;

    final int seed = (sec6Param ^ sec6HdrXor ^ 0x3028) & 0xFFFF;
    final Uint8List plain = ringCrypt(Uint8List.sublistView(bytes, sec6Off, sec6NextOff), seed, false);
    final int limitBytes = (sec6Param > 0 && sec6Param <= plain.length) ? sec6Param : plain.length;

    final stX = _Float32Buf(16384);
    final stY = _Float32Buf(16384);
    final stMove = _Uint8Buf(16384);
    final stColor = _Uint8Buf(16384);
    final stDev = _Uint8Buf(16384);

    final seqX = _Float32Buf(2048);
    final seqY = _Float32Buf(2048);
    final seqCode = _Uint8Buf(2048);

    final beadX = _Float32Buf(2048);
    final beadY = _Float32Buf(2048);
    final beadCode = _Uint8Buf(2048);

    double curX = 0.0, curY = 0.0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int stitchCount = 0;
    int jumpCount = 0;
    int stopCount = 0;
    int sequinCount = 0;
    int beadCount = 0;
    int currentColorIdx = 0;
    final int palLen = paletteArgb.length;

    bool needMove = true;
    bool inDevMode = false;
    bool pendingDevOn = false;
    int devJumpPulse = 0;
    double lastJumpX = 0.0, lastJumpY = 0.0;

    void recordPoint(double px, double py, int devCode) {
      stX.add(px);
      stY.add(py);
      stMove.add(needMove ? 1 : 0);
      stColor.add(currentColorIdx);
      int d = devCode;
      if (pendingDevOn) {
        d |= 0x10;
        pendingDevOn = false;
      }
      stDev.add(d);
      needMove = false;
      stitchCount++;
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

    for (int p = 0; p + 2 < limitBytes; p += 3) {
      final int cmd = plain[p];
      final int b1 = plain[p + 1];
      final int b2 = plain[p + 2];

      if (cmd == 0xF8) break;

      if (cmd == 0xD7) {
        if (b1 == 0 && b2 == 0) {
          // تشغيل أو إيقاف جهاز الترتر / الخرز
          if (!inDevMode) {
            inDevMode = true;
            if (stDev.length > 0) {
              stDev.setAt(stDev.length - 1, stDev.at(stDev.length - 1) | 0x10);
            } else {
              pendingDevOn = true;
            }
          } else {
            inDevMode = false;
            devJumpPulse = 0;
            if (stDev.length > 0) {
              stDev.setAt(stDev.length - 1, stDev.at(stDev.length - 1) | 0x20);
            }
          }
        } else if (b1 == 6 || b1 == 10) {
          // إسقاط خرز أو ترتر بعد الغرزة الأخيرة
          if (b2 == 16 || b2 == 32 || b2 == 48) {
            final int bCode = b2 == 16 ? 1 : (b2 == 32 ? 2 : 3);
            final int devCode = b2 == 16 ? 5 : (b2 == 32 ? 6 : 7);
            beadCount++;
            beadX.add(curX);
            beadY.add(curY);
            beadCode.add(bCode);
            if (stDev.length > 0) {
              stDev.setAt(stDev.length - 1, (stDev.at(stDev.length - 1) & 0xF0) | devCode);
            }
          } else if (b2 == 1 || b2 == 2 || b2 == 4 || b2 == 8 || b2 == 3 || b2 == 5 || b2 == 6 || b2 == 12) {
            final int sCode = (b2 & 0x01) != 0 ? 1 : ((b2 & 0x02) != 0 ? 2 : ((b2 & 0x04) != 0 ? 3 : 4));
            sequinCount++;
            seqX.add(curX);
            seqY.add(curY);
            seqCode.add(sCode);
            if (stDev.length > 0) {
              stDev.setAt(stDev.length - 1, (stDev.at(stDev.length - 1) & 0xF0) | sCode);
            }
          }
        }
        continue;
      }

      // أوامر تغيير اللون (0x88..0x9F)
      if (cmd >= 0x88 && cmd <= 0x9F) {
        stopCount++;
        currentColorIdx = (currentColorIdx + 1) % palLen;
        needMove = true;
        devJumpPulse = 0;
        continue;
      }

      final int kind = cmd & 0x9F;
      final int dySigned = (cmd & 0x40) != 0 ? -b1 : b1;
      final int dxSigned = (cmd & 0x20) != 0 ? -b2 : b2;
      // في داهوا Y موجب للأعلى، وفي الشاشة Y موجب للأسفل -> نعكس Y
      final double ddx = dxSigned.toDouble();
      final double ddy = (-dySigned).toDouble();

      if (kind == 0x81) {
        // قفزة (أو أمر إسقاط ترتر داخل وضع الجهاز في .DHA)
        curX += ddx;
        curY += ddy;
        jumpCount++;
        if (inDevMode && !matchedDheKey) {
          devJumpPulse++;
          lastJumpX = curX;
          lastJumpY = curY;
        } else {
          needMove = true;
        }
      } else if (kind == 0x80) {
        if (inDevMode && !matchedDheKey && devJumpPulse > 0) {
          // نبضات قفزات الترتر في .DHA (1 -> ترتر 1، 2 -> ترتر 2، 4 -> ترتر 3، 8 -> ترتر 4)
          final int sCode = devJumpPulse <= 1 ? 1 : (devJumpPulse == 2 ? 2 : (devJumpPulse <= 4 ? 3 : 4));
          sequinCount++;
          seqX.add(lastJumpX);
          seqY.add(lastJumpY);
          seqCode.add(sCode);
          // نسجّل نقطة إسقاط الترتر كغرزة مع كود الترتر لحفظه عند إعادة التصدير
          recordPoint(lastJumpX, lastJumpY, sCode);
          devJumpPulse = 0;
        }
        curX += ddx;
        curY += ddy;
        recordPoint(curX, curY, 0);
      }
    }

    if (stitchCount < 2) return null;

    return VectorDesignData(
      stX: stX.finish(),
      stY: stY.finish(),
      stMove: stMove.finish(),
      stColor: stColor.finish(),
      stDev: stDev.finish(),
      seqX: seqX.finish(),
      seqY: seqY.finish(),
      seqCode: seqCode.finish(),
      beadX: beadX.finish(),
      beadY: beadY.finish(),
      beadCode: beadCode.finish(),
      paletteArgb: paletteArgb,
      stitches: stitchCount,
      colorCount: math.max(validColors, stopCount + 1),
      stopsCount: stopCount > 0 ? stopCount : hdrStops,
      jumpsCount: jumpCount,
      sequinsCount: sequinCount,
      beadsCount: beadCount,
      trimsCount: 0,
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      hasBounds: hasBounds,
      machineType: preferDhe ? 'Dahao (.DHE)' : 'Dahao (.DHA)',
    );
  }
}

/// مُصدِّر أصلي لصيغتي داهوا (.DHE و .DHA) يحافظ على جميع إعدادات الخرز والترتر 100%
class DahaoExporter {
  static Uint8List encode(VectorDesignData vec, {required bool isDhe}) {
    final Float32List stX = vec.stX;
    final Float32List stY = vec.stY;
    final Uint8List stMove = vec.stMove;
    final Uint8List stColor = vec.stColor;
    final Uint8List? stDev = vec.stDev;
    final int n = stX.length;

    // 1) بناء سيل الغرز والأوامر الخام (Plaintext Dahao Triplets)
    final stream = BytesBuilder(copy: false);
    int curX = n > 0 ? stX[0].round() : 0;
    int curY = n > 0 ? (-stY[0]).round() : 0;
    int activeColor = n > 0 ? stColor[0] : 0;
    int stopsCount = 0;
    bool inDev = false;

    // نقطة البداية الأصلية لماكينة داهوا
    stream.add(const [0x80, 0x00, 0x00]);

    void emitStep(int dx, int dy, bool isJump) {
      int rx = dx, ry = dy;
      while (rx.abs() > 60 || ry.abs() > 60) {
        final int sx = rx.clamp(-60, 60);
        final int sy = ry.clamp(-60, 60);
        final int cmd = 0x81 | (sy < 0 ? 0x40 : 0) | (sx < 0 ? 0x20 : 0);
        stream.add([cmd, sy.abs(), sx.abs()]);
        rx -= sx;
        ry -= sy;
      }
      final int cmd = (isJump ? 0x81 : 0x80) | (ry < 0 ? 0x40 : 0) | (rx < 0 ? 0x20 : 0);
      stream.add([cmd, ry.abs(), rx.abs()]);
    }

    for (int i = 0; i < n; i++) {
      final int tx = stX[i].round();
      final int ty = (-stY[i]).round();
      final int c = stColor[i];
      final bool isMv = stMove[i] != 0;
      final int dev = (stDev != null && i < stDev.length) ? stDev[i] : 0;
      final int dtype = dev & 0x0F;
      final bool devOn = (dev & 0x10) != 0;
      final bool devOff = (dev & 0x20) != 0;

      if (i > 0 && c != activeColor) {
        if (inDev) {
          stream.add(const [0xD7, 0x00, 0x00]);
          inDev = false;
        }
        stream.add([0x88 + ((c % 15) + 1), 0x00, 0x00]);
        activeColor = c;
        stopsCount++;
      }

      final int dx = tx - curX;
      final int dy = ty - curY;

      if (i > 0) {
        if (!isDhe && dtype >= 1 && dtype <= 4) {
          // في صيغة .DHA يتم ترميز الترتر الأربعة بنبضات قفز (1 / 2 / 4 / 8) داخل وضع الجهاز
          if (!inDev) {
            stream.add(const [0xD7, 0x00, 0x00]);
            inDev = true;
          }
          emitStep(dx, dy, true);
          final int extraJumps = dtype == 1 ? 0 : (dtype == 2 ? 1 : (dtype == 3 ? 3 : 7));
          for (int k = 0; k < extraJumps; k++) {
            stream.add(const [0x81, 0x00, 0x00]);
          }
        } else if (isMv && (dx != 0 || dy != 0)) {
          if (dx.abs() > 60 || dy.abs() > 60) {
            int rx = dx, ry = dy;
            while (rx.abs() > 60 || ry.abs() > 60) {
              final int sx = rx.clamp(-60, 60);
              final int sy = ry.clamp(-60, 60);
              final int cmd = 0x81 | (sy < 0 ? 0x40 : 0) | (sx < 0 ? 0x20 : 0);
              stream.add([cmd, sy.abs(), sx.abs()]);
              rx -= sx;
              ry -= sy;
            }
            emitStep(rx, ry, false);
          } else {
            emitStep(dx, dy, false);
          }
        } else {
          emitStep(dx, dy, false);
        }
        curX = tx;
        curY = ty;
      }

      if (devOn && !inDev) {
        stream.add(const [0xD7, 0x00, 0x00]);
        inDev = true;
      }

      // أوامر إسقاط الخرز (متطابقة تماماً في .DHE و .DHA بدون أي تغيير في الإعدادات)
      if (dtype >= 5 && dtype <= 7) {
        if (!inDev) {
          stream.add(const [0xD7, 0x00, 0x00]);
          inDev = true;
        }
        final int bMask = dtype == 5 ? 0x10 : (dtype == 6 ? 0x20 : 0x30);
        stream.add([0xD7, 0x06, bMask]);
      } else if (isDhe && dtype >= 1 && dtype <= 4) {
        if (!inDev) {
          stream.add(const [0xD7, 0x00, 0x00]);
          inDev = true;
        }
        final int sMask = dtype == 1 ? 0x01 : (dtype == 2 ? 0x02 : (dtype == 3 ? 0x04 : 0x08));
        stream.add([0xD7, 0x06, sMask]);
      }

      if (devOff && inDev) {
        stream.add(const [0xD7, 0x00, 0x00]);
        inDev = false;
      }
    }

    if (inDev) {
      stream.add(const [0xD7, 0x00, 0x00]);
    }
    stream.add(const [0xF8, 0x00, 0x00]);

    final Uint8List rawStream = stream.takeBytes();
    final int exactLen = rawStream.length;
    final int paddedLen = ((exactLen + 15) ~/ 16) * 16;
    final Uint8List sec6Plain = Uint8List(paddedLen);
    sec6Plain.setRange(0, exactLen, rawStream);

    // 2) القسم 1 (1000 بايت: جدول الإبر القياسي لداهوا)
    final Uint8List sec1Plain = Uint8List(1000);
    for (int i = 0; i < 1000; i++) {
      final int r = i % 3;
      sec1Plain[i] = r == 1 ? 0x0F : 0x01;
    }

    // 3) القسم 2 (16 بايت: بيانات ترويسة مساعدة)
    final Uint8List sec2Plain = Uint8List(16);
    sec2Plain[2] = isDhe ? 0x01 : 0x75;
    sec2Plain[4] = isDhe ? 0x77 : 0x74;

    // 4) الترويسة 256 بايت
    final Uint8List header = Uint8List(256);
    final hbd = ByteData.sublistView(header);
    header[0] = 0x02;
    header[1] = 0x0A;
    hbd.setUint16(2, 0x1B9E, Endian.little);
    hbd.setUint16(4, math.max(1, stopsCount + 1), Endian.little);
    hbd.setUint16(6, isDhe ? 0x0003 : 0x0000, Endian.little);
    hbd.setUint32(16, 20, Endian.little);
    for (int i = 0; i < 20; i++) {
      final int argb = vec.paletteArgb.isNotEmpty
          ? vec.paletteArgb[i % vec.paletteArgb.length]
          : 0xFFFF0000;
      header[28 + i * 3] = (argb >> 16) & 0xFF;
      header[28 + i * 3 + 1] = (argb >> 8) & 0xFF;
      header[28 + i * 3 + 2] = argb & 0xFF;
    }

    // 5) جدول الأقسام (4 مداخل × 16 بايت = 64 بايت عند 0x100..0x140) مشفر بـ 3DES
    const int offSec1 = 0x140;
    const int offSec2 = offSec1 + 1000; // 0x528
    const int offSec6 = offSec2 + 16;   // 0x538
    final int offEnd = offSec6 + paddedLen;

    final Uint8List dirPlain = Uint8List(64);
    final dbd = ByteData.sublistView(dirPlain);
    // Entry 0: Type 1
    dbd.setUint32(0, 1, Endian.little);
    dbd.setUint32(4, offSec1, Endian.little);
    dbd.setUint32(8, 1000, Endian.little);
    // Entry 1: Type 2
    dbd.setUint32(16, 2, Endian.little);
    dbd.setUint32(20, offSec2, Endian.little);
    dbd.setUint32(24, 2, Endian.little);
    // Entry 2: Type 6
    dbd.setUint32(32, 6, Endian.little);
    dbd.setUint32(36, offSec6, Endian.little);
    dbd.setUint32(40, exactLen, Endian.little);
    // Entry 3: Terminator Type 0
    dbd.setUint32(48, 0, Endian.little);
    dbd.setUint32(52, offEnd, Endian.little);
    dbd.setUint32(56, 0, Endian.little);

    final Uint8List dirEnc = _DahaoCrypto.des3Crypt(dirPlain, isDhe, true);
    final Uint8List sec1Enc = _DahaoCrypto.ringCrypt(sec1Plain, (1000 ^ 0x3028) & 0xFFFF, true);
    final Uint8List sec2Enc = _DahaoCrypto.ringCrypt(sec2Plain, (2 ^ 0x3028) & 0xFFFF, true);
    final Uint8List sec6Enc = _DahaoCrypto.ringCrypt(sec6Plain, (exactLen ^ 0x3028) & 0xFFFF, true);

    final out = BytesBuilder(copy: false);
    out.add(header);
    out.add(dirEnc);
    out.add(sec1Enc);
    out.add(sec2Enc);
    out.add(sec6Enc);
    return out.takeBytes();
  }
}


class DstExporter {
  static bool canExportToDst(String filePath) {
    final lower = filePath.toLowerCase();
    return lower.endsWith('.dhp') ||
        lower.endsWith('.dha') ||
        lower.endsWith('.dhe') ||
        lower.endsWith('.dst') ||
        UniversalFormatParser.isSupported(lower);
  }

  static Future<String?> exportToDstFile(String sourcePath, String outputPath) async {
    try {
      final Uint8List? dstBytes = await Isolate.run(() => _convertFileToDstSync(sourcePath));
      if (dstBytes == null || dstBytes.isEmpty) return null;
      final outFile = File(outputPath);
      await outFile.writeAsBytes(dstBytes, flush: true);
      return outFile.path;
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _convertFileToDstSync(String sourcePath) {
    final lower = sourcePath.toLowerCase();
    VectorDesignData? vec;
    if (lower.endsWith('.dhp')) {
      vec = DahaoParser._decodeDhpSync(sourcePath);
    } else if (lower.endsWith('.dhe') || lower.endsWith('.dha')) {
      vec = DahaoParser._decodeDheDhaSync(sourcePath, lower.endsWith('.dhe'));
    } else if (lower.endsWith('.dst')) {
      vec = DstParser._decodeDstSync(sourcePath)?.$1;
    } else {
      vec = UniversalFormatParser._decodeAnySync(sourcePath);
    }
    if (vec == null || vec.stX.length < 2) return null;

    final String baseName = sourcePath
        .split(Platform.pathSeparator)
        .last
        .replaceAll(RegExp(r'\.[^.]+$'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return _encodeDstFromVector(vec, baseName);
  }

  static Uint8List _encodeDstFromVector(VectorDesignData vec, String rawBaseName) {
    final String baseName = rawBaseName.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    final String label = (baseName.isEmpty ? 'TARIK_EMB' : baseName).padRight(16).substring(0, 16);

    final body = BytesBuilder(copy: false);
    final Float32List stX = vec.stX;
    final Float32List stY = vec.stY;
    final Uint8List stMove = vec.stMove;
    final Uint8List stColor = vec.stColor;
    final Uint8List? stDev = vec.stDev;
    final int n = stX.length;

    int curX = 0;
    int curY = 0;
    int minX = 0, maxX = 0, minY = 0, maxY = 0;
    int totalRecords = 0;
    int colorChanges = 0;
    int activeColor = stColor[0];
    bool inSeqMode = false;

    void emitSeqToggle() {
      body.add(const [0x00, 0x00, 0x43]);
      totalRecords++;
      inSeqMode = !inSeqMode;
    }

    void emitDelta(int dx, int dy, bool isJump, bool isStop) {
      // تقسيم القفزات أو الغرز الطويلة (> 121 وحدة = 12.1 مم) تلقائياً وفق معيار تاجيما
      int remX = dx;
      int remY = dy;
      while (remX.abs() > 121 || remY.abs() > 121) {
        final int stepX = remX.clamp(-121, 121);
        final int stepY = remY.clamp(-121, 121);
        _writeDstTriplet(body, stepX, stepY, true, false);
        curX += stepX;
        curY += stepY;
        if (curX < minX) minX = curX;
        if (curX > maxX) maxX = curX;
        if (curY < minY) minY = curY;
        if (curY > maxY) maxY = curY;
        totalRecords++;
        remX -= stepX;
        remY -= stepY;
      }
      _writeDstTriplet(body, remX, remY, isJump, isStop);
      curX += remX;
      curY += remY;
      if (curX < minX) minX = curX;
      if (curX > maxX) maxX = curX;
      if (curY < minY) minY = curY;
      if (curY > maxY) maxY = curY;
      totalRecords++;
    }

    for (int i = 0; i < n; i++) {
      final int tx = stX[i].round();
      final int ty = (-stY[i]).round(); // عكس Y لنظام تاجيما القياسي (أعلى موجب)
      final int c = stColor[i];
      final int dev = (stDev != null && i < stDev.length) ? stDev[i] : 0;
      final int dtype = dev & 0x0F;
      final bool devOn = (dev & 0x10) != 0;
      final bool devOff = (dev & 0x20) != 0;

      if (i > 0 && c != activeColor) {
        if (inSeqMode) emitSeqToggle();
        emitDelta(0, 0, false, true);
        colorChanges++;
        activeColor = c;
      }

      final int dx = tx - curX;
      final int dy = ty - curY;
      final int mv = stMove[i];

      if (dtype >= 1 && dtype <= 4) {
        // حفظ أوامر الترتر الأربعة في .DST بنفس معيار تاجيما/emCAD (00 00 43 + نبضات قفز 0x83)
        if (!inSeqMode) emitSeqToggle();
        emitDelta(dx, dy, true, false);
        final int extraJumps = dtype == 1 ? 0 : (dtype == 2 ? 1 : (dtype == 3 ? 3 : 7));
        for (int k = 0; k < extraJumps; k++) {
          emitDelta(0, 0, true, false);
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

    // علامة نهاية ملف DST
    body.add(const [0x00, 0x00, 0xF3]);

    final int px = maxX.abs().clamp(0, 99999);
    final int mx = minX.abs().clamp(0, 99999);
    final int py = maxY.abs().clamp(0, 99999);
    final int my = minY.abs().clamp(0, 99999);

    final String headerStr = 'LA:$label\r'
        'ST:${totalRecords.toString().padLeft(7)}\r'
        'CO:${colorChanges.toString().padLeft(3)}\r'
        '+X:${px.toString().padLeft(5)}\r'
        '-X:${mx.toString().padLeft(5)}\r'
        '+Y:${py.toString().padLeft(5)}\r'
        '-Y:${my.toString().padLeft(5)}\r'
        'AX:${curX >= 0 ? '+' : '-'}${curX.abs().clamp(0, 99999).toString().padLeft(5)}\r'
        'AY:${curY >= 0 ? '+' : '-'}${curY.abs().clamp(0, 99999).toString().padLeft(5)}\r'
        'MX:+    0\r'
        'MY:+    0\r'
        'PD:******\r'
        '\x1A';

    final Uint8List header = Uint8List(512)..fillRange(0, 512, 0x20);
    final List<int> hBytes = latin1.encode(headerStr);
    header.setRange(0, math.min(512, hBytes.length), hBytes);

    final out = BytesBuilder(copy: false);
    out.add(header);
    out.add(body.takeBytes());
    return out.takeBytes();
  }

  static void _writeDstTriplet(BytesBuilder out, int dx, int dy, bool isJump, bool isStop) {
    int b0 = 0, b1 = 0, b2 = 0x03;
    int x = dx, y = dy;

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

    if (isJump) b2 |= 0x80;
    if (isStop) b2 |= 0xC0;

    out.addByte(b0);
    out.addByte(b1);
    out.addByte(b2);
  }
}


/// محمّل بيانات المتجهات لمحاكي التطريز (Stitch Player) والعرض ثلاثي الأبعاد (3D)
class VectorDesignLoader {
  static bool supportsVectorView(String filePath) {
    final lower = filePath.toLowerCase();
    return lower.endsWith('.dhp') ||
        lower.endsWith('.dha') ||
        lower.endsWith('.dhe') ||
        lower.endsWith('.dst') ||
        UniversalFormatParser.isSupported(lower);
  }

  static Future<VectorDesignData?> load(String filePath) async {
    try {
      return await Isolate.run(() {
        final lower = filePath.toLowerCase();
        VectorDesignData? v;
        if (lower.endsWith('.dhp')) {
          v = DahaoParser._decodeDhpSync(filePath);
        } else if (lower.endsWith('.dhe') || lower.endsWith('.dha')) {
          v = DahaoParser._decodeDheDhaSync(filePath, lower.endsWith('.dhe'));
        } else if (lower.endsWith('.dst')) {
          v = DstParser._decodeDstSync(filePath)?.$1;
        } else if (UniversalFormatParser.isSupported(lower)) {
          v = UniversalFormatParser._decodeAnySync(filePath);
        }
        if (v != null && v.stX.length >= 2) return v;
        // كشف ذكي بالبايتات عند فتح ملفات واتساب (.bin) أو لاحقة مختلفة
        final f = File(filePath);
        if (!f.existsSync()) return null;
        final bytes = f.readAsBytesSync();
        final det = UniversalFormatParser.detectFormatByContent(bytes);
        switch (det) {
          case '.dst': return DstParser._decodeDstSync(filePath)?.$1;
          case '.dhp': return DahaoParser._decodeDhpSync(filePath);
          case '.dhe': return DahaoParser._decodeDheDhaSync(filePath, true);
          case '.pes': return UniversalFormatParser._decodePesSync(bytes);
          case '.pec': return UniversalFormatParser._decodePecSync(bytes, 8, 'Brother (PEC)');
          case '.jef': return UniversalFormatParser._decodeJefSync(bytes);
          case '.xxx': return UniversalFormatParser._decodeXxxSync(bytes);
          case '.tbf': return UniversalFormatParser._decodeTbfSync(bytes);
          case '.dsb': return UniversalFormatParser._decodeDsbSync(bytes);
          case '.exp': return UniversalFormatParser._decodeExpSync(bytes);
          default: return null;
        }
      });
    } catch (_) {
      return null;
    }
  }
}


/// محرك التصدير متعدد الصيغ (.DST, .EXP, .DSB, .JEF, .TBF)
class UniversalExporter {
  static const List<Map<String, String>> supportedFormats = [
    {'ext': 'DHE', 'name': 'Dahao (.DHE • خرز وترتر)'},
    {'ext': 'DHA', 'name': 'Dahao (.DHA • خرز وترتر)'},
    {'ext': 'DST', 'name': 'Tajima (.DST)'},
    {'ext': 'EXP', 'name': 'Melco / Bernina (.EXP)'},
    {'ext': 'DSB', 'name': 'Barudan (.DSB)'},
    {'ext': 'JEF', 'name': 'Janome (.JEF)'},
    {'ext': 'TBF', 'name': 'Tajima Modern (.TBF)'},
    {'ext': 'XXX', 'name': 'Singer (.XXX)'},
  ];

  static bool canExport(String filePath) => DstExporter.canExportToDst(filePath);

  static Future<String?> exportToFormat(String sourcePath, String outputPath, String targetExt) async {
    try {
      final String ext = targetExt.toUpperCase().replaceAll('.', '');
      final Uint8List? outBytes = await Isolate.run(() => _convertSync(sourcePath, ext));
      if (outBytes == null || outBytes.isEmpty) return null;
      final outFile = File(outputPath);
      await outFile.writeAsBytes(outBytes, flush: true);
      return outFile.path;
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _convertSync(String sourcePath, String ext) {
    if (ext == 'DST') return DstExporter._convertFileToDstSync(sourcePath);

    final lower = sourcePath.toLowerCase();
    VectorDesignData? vec;
    if (lower.endsWith('.dhp')) {
      vec = DahaoParser._decodeDhpSync(sourcePath);
    } else if (lower.endsWith('.dhe') || lower.endsWith('.dha')) {
      vec = DahaoParser._decodeDheDhaSync(sourcePath, lower.endsWith('.dhe'));
    } else if (lower.endsWith('.dst')) {
      vec = DstParser._decodeDstSync(sourcePath)?.$1;
    } else {
      vec = UniversalFormatParser._decodeAnySync(sourcePath);
    }
    if (vec == null || vec.stX.length < 2) return null;

    switch (ext) {
      case 'DHE':
        return DahaoExporter.encode(vec, isDhe: true);
      case 'DHA':
        return DahaoExporter.encode(vec, isDhe: false);
      case 'EXP':
        return _encodeExp(vec);
      case 'DSB':
        return _encodeDsb(vec);
      case 'JEF':
        return _encodeJef(vec);
      case 'TBF':
        return _encodeTbf(vec);
      case 'XXX':
        return _encodeXxx(vec);
      default:
        return DstExporter._convertFileToDstSync(sourcePath);
    }
  }

  static Uint8List _encodeExp(VectorDesignData vec) {
    final out = BytesBuilder(copy: false);
    final stX = vec.stX, stY = vec.stY, stMove = vec.stMove, stColor = vec.stColor;
    int curX = 0, curY = 0;
    int activeColor = stColor[0];

    void emitStep(int dx, int dy, bool isJump) {
      int rx = dx, ry = dy;
      while (rx.abs() > 127 || ry.abs() > 127) {
        final int sx = rx.clamp(-127, 127);
        final int sy = ry.clamp(-127, 127);
        out.add([0x80, 0x04, sx & 0xFF, sy & 0xFF]);
        curX += sx;
        curY += sy;
        rx -= sx;
        ry -= sy;
      }
      if (isJump) {
        out.add([0x80, 0x04, rx & 0xFF, ry & 0xFF]);
      } else {
        out.add([rx & 0xFF, ry & 0xFF]);
      }
      curX += rx;
      curY += ry;
    }

    for (int i = 0; i < stX.length; i++) {
      final int tx = stX[i].round();
      final int ty = (-stY[i]).round();
      final int c = stColor[i];
      if (i > 0 && c != activeColor) {
        out.add(const [0x80, 0x01, 0x00, 0x00]);
        activeColor = c;
      }
      final int dx = tx - curX;
      final int dy = ty - curY;
      final int mv = stMove[i];
      if (mv == 2) {
        if (dx != 0 || dy != 0) emitStep(dx, dy, true);
      } else if (mv != 0 && (dx != 0 || dy != 0)) {
        emitStep(dx, dy, true);
        emitStep(0, 0, false);
      } else {
        emitStep(dx, dy, false);
      }
    }
    out.add(const [0x80, 0x80]);
    return out.takeBytes();
  }

  static Uint8List _encodeDsb(VectorDesignData vec) {
    final body = BytesBuilder(copy: false);
    final stX = vec.stX, stY = vec.stY, stMove = vec.stMove, stColor = vec.stColor;
    int curX = 0, curY = 0;
    int activeColor = stColor[0];

    void emitStep(int dx, int dy, int cmd) {
      int rx = dx, ry = dy;
      while (rx.abs() > 127 || ry.abs() > 127) {
        final int sx = rx.clamp(-127, 127);
        final int sy = ry.clamp(-127, 127);
        int ctrl = 0x81; // jump
        if (sy < 0) ctrl |= 0x40;
        if (sx < 0) ctrl |= 0x20;
        body.add([ctrl, sy.abs(), sx.abs()]);
        curX += sx;
        curY += sy;
        rx -= sx;
        ry -= sy;
      }
      int ctrl = 0x80 | cmd;
      if (ry < 0) ctrl |= 0x40;
      if (rx < 0) ctrl |= 0x20;
      body.add([ctrl, ry.abs(), rx.abs()]);
      curX += rx;
      curY += ry;
    }

    for (int i = 0; i < stX.length; i++) {
      final int tx = stX[i].round();
      final int ty = (-stY[i]).round();
      final int c = stColor[i];
      if (i > 0 && c != activeColor) {
        emitStep(0, 0, 0x08); // color change
        activeColor = c;
      }
      final int dx = tx - curX;
      final int dy = ty - curY;
      final int mv = stMove[i];
      if (mv == 2) {
        if (dx != 0 || dy != 0) emitStep(dx, dy, 0x01);
      } else if (mv != 0 && (dx != 0 || dy != 0)) {
        emitStep(dx, dy, 0x01);
        emitStep(0, 0, 0x00);
      } else {
        emitStep(dx, dy, 0x00);
      }
    }
    body.add(const [0xF8, 0x00, 0x00]);

    final Uint8List header = Uint8List(512)..fillRange(0, 512, 0x20);
    final out = BytesBuilder(copy: false);
    out.add(header);
    out.add(body.takeBytes());
    return out.takeBytes();
  }

  static Uint8List _encodeJef(VectorDesignData vec) {
    final body = BytesBuilder(copy: false);
    final stX = vec.stX, stY = vec.stY, stMove = vec.stMove, stColor = vec.stColor;
    int curX = 0, curY = 0;
    int activeColor = stColor[0];
    int colorChanges = 0;

    void emitStep(int dx, int dy, bool isJump) {
      int rx = dx, ry = dy;
      while (rx.abs() > 127 || ry.abs() > 127) {
        final int sx = rx.clamp(-127, 127);
        final int sy = ry.clamp(-127, 127);
        body.add([0x80, 0x02, sx & 0xFF, sy & 0xFF]);
        curX += sx;
        curY += sy;
        rx -= sx;
        ry -= sy;
      }
      if (isJump) {
        body.add([0x80, 0x02, rx & 0xFF, ry & 0xFF]);
      } else {
        body.add([rx & 0xFF, ry & 0xFF]);
      }
      curX += rx;
      curY += ry;
    }

    for (int i = 0; i < stX.length; i++) {
      final int tx = stX[i].round();
      final int ty = (-stY[i]).round();
      final int c = stColor[i];
      if (i > 0 && c != activeColor) {
        body.add(const [0x80, 0x01]);
        colorChanges++;
        activeColor = c;
      }
      final int dx = tx - curX;
      final int dy = ty - curY;
      final int mv = stMove[i];
      if (mv == 2) {
        if (dx != 0 || dy != 0) emitStep(dx, dy, true);
      } else if (mv != 0 && (dx != 0 || dy != 0)) {
        emitStep(dx, dy, true);
        emitStep(0, 0, false);
      } else {
        emitStep(dx, dy, false);
      }
    }
    body.add(const [0x80, 0x10]);

    final int numColors = math.max(1, colorChanges + 1);
    final int stitchOffset = 116 + numColors * 8;
    final Uint8List header = Uint8List(stitchOffset);
    final bd = ByteData.sublistView(header);
    bd.setUint32(0, stitchOffset, Endian.little);
    bd.setUint32(4, 0x0A, Endian.little);
    bd.setUint32(24, numColors, Endian.little);
    bd.setUint32(28, stX.length, Endian.little);
    for (int i = 0; i < numColors; i++) {
      bd.setUint32(116 + i * 4, (i % 78) + 1, Endian.little);
      bd.setUint32(116 + numColors * 4 + i * 4, 0x0D, Endian.little);
    }

    final out = BytesBuilder(copy: false);
    out.add(header);
    out.add(body.takeBytes());
    return out.takeBytes();
  }

  static Uint8List _encodeTbf(VectorDesignData vec) {
    final body = BytesBuilder(copy: false);
    final stX = vec.stX, stY = vec.stY, stMove = vec.stMove, stColor = vec.stColor;
    int curX = 0, curY = 0;
    int activeColor = stColor[0];

    void emitStep(int dx, int dy, int ctrl) {
      int rx = dx, ry = dy;
      while (rx.abs() > 127 || ry.abs() > 127) {
        final int sx = rx.clamp(-127, 127);
        final int sy = ry.clamp(-127, 127);
        body.add([sx & 0xFF, sy & 0xFF, 0x81]);
        curX += sx;
        curY += sy;
        rx -= sx;
        ry -= sy;
      }
      body.add([rx & 0xFF, ry & 0xFF, ctrl]);
      curX += rx;
      curY += ry;
    }

    for (int i = 0; i < stX.length; i++) {
      final int tx = stX[i].round();
      final int ty = (-stY[i]).round();
      final int c = stColor[i];
      if (i > 0 && c != activeColor) {
        emitStep(0, 0, 0x86);
        activeColor = c;
      }
      final int dx = tx - curX;
      final int dy = ty - curY;
      final int mv = stMove[i];
      if (mv == 2) {
        if (dx != 0 || dy != 0) emitStep(dx, dy, 0x81);
      } else if (mv != 0 && (dx != 0 || dy != 0)) {
        emitStep(dx, dy, 0x81);
        emitStep(0, 0, 0x80);
      } else {
        emitStep(dx, dy, 0x80);
      }
    }
    body.add(const [0x00, 0x00, 0x8F]);

    final Uint8List header = Uint8List(0x600);
    final out = BytesBuilder(copy: false);
    out.add(header);
    out.add(body.takeBytes());
    return out.takeBytes();
  }


  static Uint8List _encodeXxx(VectorDesignData vec) {
    final body = BytesBuilder(copy: false);
    final stX = vec.stX, stY = vec.stY, stMove = vec.stMove, stColor = vec.stColor;
    int curX = 0, curY = 0;
    int activeColor = stColor[0];
    int colorChanges = 0;

    void emitStep(int dx, int dy, bool isJump) {
      int rx = dx, ry = dy;
      while (rx.abs() > 120 || ry.abs() > 120) {
        final int sx = rx.clamp(-120, 120);
        final int sy = ry.clamp(-120, 120);
        body.add([0x7F, 0x01, sx & 0xFF, sy & 0xFF]);
        curX += sx;
        curY += sy;
        rx -= sx;
        ry -= sy;
      }
      if (isJump) {
        body.add([0x7F, 0x01, rx & 0xFF, ry & 0xFF]);
      } else {
        body.add([rx & 0xFF, ry & 0xFF]);
      }
      curX += rx;
      curY += ry;
    }

    for (int i = 0; i < stX.length; i++) {
      final int tx = stX[i].round();
      final int ty = (-stY[i]).round();
      final int c = stColor[i];
      if (i > 0 && c != activeColor) {
        body.add(const [0x7F, 0x08, 0x00, 0x00]);
        colorChanges++;
        activeColor = c;
      }
      final int dx = tx - curX;
      final int dy = ty - curY;
      final int mv = stMove[i];
      if (mv == 2) {
        if (dx != 0 || dy != 0) emitStep(dx, dy, true);
      } else if (mv != 0 && (dx != 0 || dy != 0)) {
        emitStep(dx, dy, true);
        emitStep(0, 0, false);
      } else {
        emitStep(dx, dy, false);
      }
    }
    body.add(const [0x7F, 0x7F]);

    final Uint8List header = Uint8List(256);
    final bd = ByteData.sublistView(header);
    bd.setUint32(0x1B, stX.length, Endian.little);
    bd.setUint16(0x27, math.max(1, colorChanges + 1), Endian.little);

    final out = BytesBuilder(copy: false);
    out.add(header);
    out.add(body.takeBytes());
    return out.takeBytes();
  }
}


/// محرك تعديل التصاميم المتجهية (تكبير/تصغير، دوران، قلب، حذف لون، حذف غرز)
class VectorDesignEditor {
  /// تعديل شامل للتصميم:
  /// - الحجم (scale / scaleX / scaleY) والدوران والقلب وحذف الألوان وقص الغرز
  /// - الكثافة والفلترة (0.3 - 1.5 مم مع حماية الزوايا)
  /// - التحكم بطول الدرزة Run (للإطار ولدرزات الرسمة مع حماية الفستون والزوايا)
  /// - إضافة / إلغاء إطار درزة (Basting Frame) مع التحكم بالبُعد عن التصميم ولون مستقل
  /// - تحديد نقطة البداية والنهاية (شبكة ويلكم 3×3 ذات الـ 9 نقاط: 0=الأصلي، 1..9=الشبكة)
  static VectorDesignData transform(
    VectorDesignData src, {
    double scale = 1.0,
    double? scaleX,
    double? scaleY,
    double rotationDeg = 0.0,
    bool flipH = false,
    bool flipV = false,
    Set<int> deletedColors = const {},
    int? trimStart,
    int? trimEnd,
    double densityFactor = 1.0,
    double minStitchFilterMm = 0.0,
    double runStitchLengthMm = 4.0,
    bool applyRunLengthToDesign = false,
    bool addBastingFrame = false,
    double bastingMarginMm = 5.0,
    bool bastingSeparateColor = true,
    int startAnchor = 0, // 0=الأصلي, 1=أعلى يسار, 2=أعلى وسط, 3=أعلى يمين, 4=وسط يسار, 5=المركز, 6=وسط يمين, 7=أسفل يسار, 8=أسفل وسط, 9=أسفل يمين
    bool returnToStart = true,
  }) {
    final int total = src.stX.length;
    if (total == 0) return src;

    final int startIdx = (trimStart ?? 0).clamp(0, total);
    final int endIdx = (trimEnd ?? total).clamp(startIdx, total);

    final double cx = src.hasBounds ? (src.minX + src.maxX) * 0.5 : 0.0;
    final double cy = src.hasBounds ? (src.minY + src.maxY) * 0.5 : 0.0;
    final double rad = rotationDeg * math.pi / 180.0;
    final double cosA = math.cos(rad);
    final double sinA = math.sin(rad);

    final double sxVal = scaleX ?? scale;
    final double syVal = scaleY ?? scale;
    (double, double) xform(double x, double y) {
      double dx = (x - cx) * sxVal * (flipH ? -1.0 : 1.0);
      double dy = (y - cy) * syVal * (flipV ? -1.0 : 1.0);
      final double rx = dx * cosA - dy * sinA + cx;
      final double ry = dx * sinA + dy * cosA + cy;
      return (rx, ry);
    }

    // المرحلة 1: التحويل الهندسي + حذف الألوان + التكثيف/التخفيف مع حماية الزوايا
    final rawX = _Float32Buf(math.max(64, endIdx - startIdx));
    final rawY = _Float32Buf(math.max(64, endIdx - startIdx));
    final rawMove = _Uint8Buf(math.max(64, endIdx - startIdx));
    final rawColor = _Uint8Buf(math.max(64, endIdx - startIdx));

    bool forceMove = true;
    final double safeDensity = densityFactor.clamp(0.4, 2.2);
    double thinAcc = 0.0;
    double denseAcc = 0.0;
    double prevPx = 0.0, prevPy = 0.0;
    bool hasPrev = false;
    int prevColor = -1;

    for (int i = startIdx; i < endIdx; i++) {
      final int c = src.stColor[i];
      if (deletedColors.contains(c)) {
        forceMove = true;
        hasPrev = false;
        continue;
      }
      if (src.stMove[i] == 2) {
        // تجاهل أي قفزة نهاية قديمة قبل إعادة حساب نقطة البداية والنهاية
        continue;
      }
      final pt = xform(src.stX[i], src.stY[i]);
      final double px = pt.$1;
      final double py = pt.$2;
      final bool isMove = forceMove || src.stMove[i] != 0 || (hasPrev && c != prevColor);
      final bool hasNextSame = !isMove &&
          hasPrev &&
          i + 1 < endIdx &&
          src.stMove[i + 1] == 0 &&
          src.stColor[i + 1] == c &&
          !deletedColors.contains(src.stColor[i + 1]);

      if (safeDensity < 0.99 && hasNextSame) {
        final nextPt = xform(src.stX[i + 1], src.stY[i + 1]);
        final double v1x = px - prevPx, v1y = py - prevPy;
        final double v2x = nextPt.$1 - px, v2y = nextPt.$2 - py;
        final double l1 = math.sqrt(v1x * v1x + v1y * v1y);
        final double l2 = math.sqrt(v2x * v2x + v2y * v2y);
        bool isSharpCorner = false;
        if (l1 > 1.5 && l2 > 1.5) {
          final double cosT = (v1x * v2x + v1y * v2y) / (l1 * l2);
          if (cosT < 0.70 && cosT > -0.82) {
            isSharpCorner = true;
          }
        }
        if (!isSharpCorner) {
          thinAcc += safeDensity;
          if (thinAcc < 1.0) {
            continue;
          }
          thinAcc -= 1.0;
        }
      }

      rawX.add(px);
      rawY.add(py);
      rawMove.add(isMove ? 1 : 0);
      rawColor.add(c);
      forceMove = false;

      if (safeDensity > 1.01 && hasNextSame) {
        denseAcc += (safeDensity - 1.0);
        if (denseAcc >= 1.0) {
          denseAcc -= 1.0;
          final nextPt = xform(src.stX[i + 1], src.stY[i + 1]);
          final double mx = (prevPx + nextPt.$1) * 0.5;
          final double my = (prevPy + nextPt.$2) * 0.5;
          final double d = math.sqrt((mx - px) * (mx - px) + (my - py) * (my - py));
          if (d >= 2.0) {
            rawX.add(mx);
            rawY.add(my);
            rawMove.add(0);
            rawColor.add(c);
          }
        }
      }

      prevPx = px;
      prevPy = py;
      prevColor = c;
      hasPrev = true;
    }

    Float32List rX = rawX.finish();
    Float32List rY = rawY.finish();
    Uint8List rM = rawMove.finish();
    Uint8List rC = rawColor.finish();

    // المرحلة 1.5: تعديل طول الدرزة (Run Stitch Length) على مسارات الدرز في الرسمة مع حماية الفستون والزوايا
    final double safeRunMm = runStitchLengthMm.clamp(1.0, 12.0);
    if (applyRunLengthToDesign && rX.length >= 2) {
      final res = _resampleRunStitches(rX, rY, rM, rC, safeRunMm * 10.0);
      rX = res.$1;
      rY = res.$2;
      rM = res.$3;
      rC = res.$4;
    }

    // المرحلة 2: فلترة الغرز القصيرة (0.3 مم إلى 1.5 مم) مع الحفاظ الكامل على غرز الزوايا
    final int rLen = rX.length;
    final designX = _Float32Buf(math.max(64, rLen));
    final designY = _Float32Buf(math.max(64, rLen));
    final designMove = _Uint8Buf(math.max(64, rLen));
    final designColor = _Uint8Buf(math.max(64, rLen));

    double dMinX = double.infinity, dMaxX = -double.infinity;
    double dMinY = double.infinity, dMaxY = -double.infinity;
    bool hasDesignBounds = false;

    void emitDesign(double px, double py, int mv, int c) {
      designX.add(px);
      designY.add(py);
      designMove.add(mv);
      designColor.add(c);
      if (!hasDesignBounds) {
        dMinX = dMaxX = px;
        dMinY = dMaxY = py;
        hasDesignBounds = true;
      } else {
        if (px < dMinX) dMinX = px;
        if (px > dMaxX) dMaxX = px;
        if (py < dMinY) dMinY = py;
        if (py > dMaxY) dMaxY = py;
      }
    }

    final double filterUnits = minStitchFilterMm >= 0.25 ? (minStitchFilterMm.clamp(0.3, 1.5) * 10.0) : 0.0;

    if (filterUnits <= 0.0) {
      for (int i = 0; i < rLen; i++) {
        emitDesign(rX[i], rY[i], rM[i], rC[i]);
      }
    } else {
      double lastKeptX = 0.0, lastKeptY = 0.0;
      int lastKeptColor = -1;
      bool hasKept = false;

      for (int i = 0; i < rLen; i++) {
        final double px = rX[i];
        final double py = rY[i];
        final int mv = rM[i];
        final int c = rC[i];

        final bool isStartOfRun = !hasKept || mv != 0 || c != lastKeptColor;
        final bool isEndOfRun = (i + 1 >= rLen) || rM[i + 1] != 0 || rC[i + 1] != c;

        if (isStartOfRun || isEndOfRun) {
          emitDesign(px, py, mv, c);
          lastKeptX = px;
          lastKeptY = py;
          lastKeptColor = c;
          hasKept = true;
          continue;
        }

        final double v1x = px - lastKeptX;
        final double v1y = py - lastKeptY;
        final double d1 = math.sqrt(v1x * v1x + v1y * v1y);

        if (d1 >= filterUnits) {
          emitDesign(px, py, mv, c);
          lastKeptX = px;
          lastKeptY = py;
          lastKeptColor = c;
          continue;
        }

        final double nx = rX[i + 1];
        final double ny = rY[i + 1];
        final double v2x = nx - px;
        final double v2y = ny - py;
        final double d2 = math.sqrt(v2x * v2x + v2y * v2y);

        bool keepCorner = false;
        if (d1 >= 1.4 && d2 >= 1.4) {
          final double cosTheta = (v1x * v2x + v1y * v2y) / (d1 * d2);
          final double chX = nx - lastKeptX;
          final double chY = ny - lastKeptY;
          final double chLen = math.sqrt(chX * chX + chY * chY);
          final double perpErr = chLen > 1e-4 ? ((v1x * chY - v1y * chX).abs() / chLen) : d1;

          if (cosTheta < 0.66 && (perpErr >= 2.0 || d2 >= filterUnits * 1.15)) {
            keepCorner = true;
          }
        }

        if (keepCorner) {
          emitDesign(px, py, mv, c);
          lastKeptX = px;
          lastKeptY = py;
          lastKeptColor = c;
        }
      }
    }

    final Float32List dX = designX.finish();
    final Float32List dY = designY.finish();
    final Uint8List dM = designMove.finish();
    final Uint8List dC = designColor.finish();

    // المرحلة 3: حساب إطار الدرزة (Basting Frame) حول التصميم قبل التطريز بطول الدرزة runStitchLengthMm
    List<int> outPaletteList = src.paletteArgb.toList();
    final stX = _Float32Buf(math.max(64, dX.length + 128));
    final stY = _Float32Buf(math.max(64, dX.length + 128));
    final stMove = _Uint8Buf(math.max(64, dX.length + 128));
    final stColor = _Uint8Buf(math.max(64, dX.length + 128));

    double totalMinX = dMinX, totalMaxX = dMaxX;
    double totalMinY = dMinY, totalMaxY = dMaxY;
    bool hasBounds = hasDesignBounds;

    if (addBastingFrame && hasDesignBounds) {
      final double mUnits = bastingMarginMm.clamp(0.0, 40.0) * 10.0;
      final double fx0 = dMinX - mUnits;
      final double fx1 = dMaxX + mUnits;
      final double fy0 = dMinY - mUnits;
      final double fy1 = dMaxY + mUnits;

      totalMinX = fx0;
      totalMaxX = fx1;
      totalMinY = fy0;
      totalMaxY = fy1;

      int frameColorIdx = dC.isNotEmpty ? dC[0] : 0;
      if (bastingSeparateColor && outPaletteList.length < 254) {
        frameColorIdx = outPaletteList.length;
        outPaletteList.add(0xFF00BFA5); // لون فيروزي مميز لإطار التثبيت
      }

      // اختيار أقرب زاوية لنقطة البداية المختارة لبدء الإطار منها
      final corners = [
        (fx0, fy0), // 0: TL
        (fx1, fy0), // 1: TR
        (fx1, fy1), // 2: BR
        (fx0, fy1), // 3: BL
      ];
      int startCorner = 0;
      if (startAnchor == 3 || startAnchor == 6) {
        startCorner = 1;
      } else if (startAnchor == 9 || startAnchor == 8) {
        startCorner = 2;
      } else if (startAnchor == 7) {
        startCorner = 3;
      }

      final double stepUnits = safeRunMm * 10.0;
      bool firstFramePt = true;
      for (int side = 0; side < 4; side++) {
        final a = corners[(startCorner + side) % 4];
        final b = corners[(startCorner + side + 1) % 4];
        final double segLen = math.sqrt((b.$1 - a.$1) * (b.$1 - a.$1) + (b.$2 - a.$2) * (b.$2 - a.$2));
        final int steps = math.max(1, (segLen / stepUnits).round());
        for (int s = 0; s < steps; s++) {
          final double t = s / steps;
          final double px = a.$1 + (b.$1 - a.$1) * t;
          final double py = a.$2 + (b.$2 - a.$2) * t;
          stX.add(px);
          stY.add(py);
          stMove.add(firstFramePt ? 1 : 0);
          stColor.add(frameColorIdx);
          if (firstFramePt) {
            // غرزة تثبيت خفيفة في بداية إطار التثبيت (Tie-in)
            final double lockDist = math.min(8.0, segLen * 0.25);
            if (segLen > 4.0) {
              final double ux = (b.$1 - a.$1) / segLen;
              final double uy = (b.$2 - a.$2) / segLen;
              stX.add(px + ux * lockDist);
              stY.add(py + uy * lockDist);
              stMove.add(0);
              stColor.add(frameColorIdx);
              stX.add(px);
              stY.add(py);
              stMove.add(0);
              stColor.add(frameColorIdx);
            }
            firstFramePt = false;
          }
        }
      }
      // إغلاق الإطار عند زاوية البداية مع تثبيت خفيف
      final closePt = corners[startCorner];
      stX.add(closePt.$1);
      stY.add(closePt.$2);
      stMove.add(0);
      stColor.add(frameColorIdx);
    }

    // إضافة غرز التصميم نفسه بعد الإطار
    for (int i = 0; i < dX.length; i++) {
      stX.add(dX[i]);
      stY.add(dY[i]);
      stMove.add((i == 0 && addBastingFrame) ? 1 : dM[i]);
      stColor.add(dC[i]);
    }

    // المرحلة 4: تطبيق نقطة البداية والنهاية (شبكة ويلكم 3×3: 1..9) بتحريك الإحداثيات بحيث تصبح النقطة المختارة عند (0, 0)
    double shiftX = 0.0, shiftY = 0.0;
    if (startAnchor >= 1 && startAnchor <= 9 && hasBounds) {
      final int col = (startAnchor - 1) % 3; // 0=يسار, 1=وسط, 2=يمين
      final int row = (startAnchor - 1) ~/ 3; // 0=أعلى, 1=وسط, 2=أسفل
      final double ax = col == 0 ? totalMinX : (col == 2 ? totalMaxX : (totalMinX + totalMaxX) * 0.5);
      final double ay = row == 0 ? totalMinY : (row == 2 ? totalMaxY : (totalMinY + totalMaxY) * 0.5);
      shiftX = -ax;
      shiftY = -ay;
    }

    final Float32List preX = stX.finish();
    final Float32List preY = stY.finish();
    final Uint8List preM = stMove.finish();
    final Uint8List preC = stColor.finish();

    final finalX = _Float32Buf(preX.length + 2);
    final finalY = _Float32Buf(preY.length + 2);
    final finalM = _Uint8Buf(preM.length + 2);
    final finalC = _Uint8Buf(preC.length + 2);
    final Set<int> usedColors = {};

    for (int i = 0; i < preX.length; i++) {
      finalX.add(preX[i] + shiftX);
      finalY.add(preY[i] + shiftY);
      finalM.add(i == 0 ? 1 : preM[i]);
      finalC.add(preC[i]);
      usedColors.add(preC[i]);
    }

    // إذا كان Auto Start & End مفعّلاً، نعيد الإبرة في النهاية إلى نقطة (0, 0) بقفزة نقية (stMove = 2 بدون إسقاط غرزة)
    if (startAnchor >= 1 && startAnchor <= 9 && returnToStart && preX.isNotEmpty) {
      finalX.add(0.0);
      finalY.add(0.0);
      finalM.add(2);
      finalC.add(preC.last);
    }

    final seqX = _Float32Buf(math.max(16, src.seqX.length));
    final seqY = _Float32Buf(math.max(16, src.seqY.length));
    for (int i = 0; i < src.seqX.length; i++) {
      final pt = xform(src.seqX[i], src.seqY[i]);
      seqX.add(pt.$1 + shiftX);
      seqY.add(pt.$2 + shiftY);
    }

    final beadX = _Float32Buf(math.max(16, src.beadX.length));
    final beadY = _Float32Buf(math.max(16, src.beadY.length));
    for (int i = 0; i < src.beadX.length; i++) {
      final pt = xform(src.beadX[i], src.beadY[i]);
      beadX.add(pt.$1 + shiftX);
      beadY.add(pt.$2 + shiftY);
    }

    final Uint8List outStX_check = finalM.finish();
    return VectorDesignData(
      stX: finalX.finish(),
      stY: finalY.finish(),
      stMove: outStX_check,
      stColor: finalC.finish(),
      stDev: (src.stDev != null && src.stDev!.length == outStX_check.length) ? src.stDev : null,
      seqX: seqX.finish(),
      seqY: seqY.finish(),
      seqCode: src.seqCode,
      beadX: beadX.finish(),
      beadY: beadY.finish(),
      beadCode: src.beadCode,
      paletteArgb: Int32List.fromList(outPaletteList),
      stitches: preX.length,
      colorCount: math.max(1, usedColors.length),
      stopsCount: usedColors.length > 1 ? usedColors.length - 1 : 0,
      jumpsCount: src.jumpsCount,
      sequinsCount: src.sequinsCount,
      beadsCount: src.beadsCount,
      trimsCount: src.trimsCount,
      minX: hasBounds ? (totalMinX + shiftX) : 0,
      maxX: hasBounds ? (totalMaxX + shiftX) : 0,
      minY: hasBounds ? (totalMinY + shiftY) : 0,
      maxY: hasBounds ? (totalMaxY + shiftY) : 0,
      hasBounds: hasBounds,
      machineType: src.machineType,
    );
  }

  /// إعادة توزيع غرز الدرزة (Run Stitches) بطول targetUnits (وحدة 0.1 مم) مع حماية أعمدة الفستون المتعرجة والزوايا الحادة
  static (Float32List, Float32List, Uint8List, Uint8List) _resampleRunStitches(
    Float32List xs,
    Float32List ys,
    Uint8List mv,
    Uint8List col,
    double targetUnits,
  ) {
    final int n = xs.length;
    if (n < 2 || targetUnits < 5.0) return (xs, ys, mv, col);

    // 1) تصنيف نقاط الزكزاك (فستون/تاتامي) لحمايتها من التعديل
    final Uint8List isReversal = Uint8List(n);
    for (int i = 1; i < n - 1; i++) {
      if (mv[i] != 0 || mv[i + 1] != 0 || col[i] != col[i - 1] || col[i] != col[i + 1]) continue;
      final double v1x = xs[i] - xs[i - 1], v1y = ys[i] - ys[i - 1];
      final double v2x = xs[i + 1] - xs[i], v2y = ys[i + 1] - ys[i];
      final double l1 = math.sqrt(v1x * v1x + v1y * v1y);
      final double l2 = math.sqrt(v2x * v2x + v2y * v2y);
      if (l1 > 1.0 && l2 > 1.0) {
        final double cosT = (v1x * v2x + v1y * v2y) / (l1 * l2);
        if (cosT < -0.50) {
          isReversal[i] = 1;
        }
      }
    }

    final Uint8List isSatinPt = Uint8List(n);
    for (int i = 1; i < n - 1; i++) {
      if (isReversal[i] != 0 && (isReversal[i - 1] != 0 || isReversal[i + 1] != 0)) {
        isSatinPt[i] = 1;
        isSatinPt[i - 1] = 1;
        isSatinPt[i + 1] = 1;
      }
    }

    final outX = _Float32Buf(n);
    final outY = _Float32Buf(n);
    final outM = _Uint8Buf(n);
    final outC = _Uint8Buf(n);

    void emitResampledChain(List<int> chain, int cIdx, bool startMove) {
      if (chain.isEmpty) return;
      if (chain.length == 1) {
        outX.add(xs[chain[0]]);
        outY.add(ys[chain[0]]);
        outM.add(startMove ? 1 : 0);
        outC.add(cIdx);
        return;
      }

      // تقسيم السلسلة عند الزوايا الحادة (cosT < 0.65) لحماية الزوايا 100%
      final List<int> splitPositions = [0];
      for (int k = 1; k < chain.length - 1; k++) {
        final int p0 = chain[k - 1], p1 = chain[k], p2 = chain[k + 1];
        final double v1x = xs[p1] - xs[p0], v1y = ys[p1] - ys[p0];
        final double v2x = xs[p2] - xs[p1], v2y = ys[p2] - ys[p1];
        final double l1 = math.sqrt(v1x * v1x + v1y * v1y);
        final double l2 = math.sqrt(v2x * v2x + v2y * v2y);
        if (l1 > 1.0 && l2 > 1.0) {
          final double cosT = (v1x * v2x + v1y * v2y) / (l1 * l2);
          if (cosT < 0.65) {
            splitPositions.add(k);
          }
        }
      }
      splitPositions.add(chain.length - 1);

      bool isFirstPt = true;
      for (int sp = 0; sp < splitPositions.length - 1; sp++) {
        final int aPos = splitPositions[sp];
        final int bPos = splitPositions[sp + 1];

        // حساب الطول الكلي للقطعة الناعمة بين الزاويتين
        final List<double> cum = [0.0];
        double totalL = 0.0;
        for (int k = aPos + 1; k <= bPos; k++) {
          final int p0 = chain[k - 1], p1 = chain[k];
          totalL += math.sqrt((xs[p1] - xs[p0]) * (xs[p1] - xs[p0]) + (ys[p1] - ys[p0]) * (ys[p1] - ys[p0]));
          cum.add(totalL);
        }

        if (isFirstPt) {
          outX.add(xs[chain[aPos]]);
          outY.add(ys[chain[aPos]]);
          outM.add(startMove ? 1 : 0);
          outC.add(cIdx);
          isFirstPt = false;
        }

        if (totalL < 1.5) {
          if (bPos > aPos) {
            outX.add(xs[chain[bPos]]);
            outY.add(ys[chain[bPos]]);
            outM.add(0);
            outC.add(cIdx);
          }
          continue;
        }

        final int steps = math.max(1, (totalL / targetUnits).round());
        for (int s = 1; s <= steps; s++) {
          final double targetD = totalL * (s / steps);
          int seg = 0;
          while (seg + 1 < cum.length - 1 && cum[seg + 1] < targetD) {
            seg++;
          }
          final double segStartD = cum[seg];
          final double segEndD = cum[seg + 1];
          final double t = (segEndD - segStartD) > 1e-5 ? ((targetD - segStartD) / (segEndD - segStartD)).clamp(0.0, 1.0) : 1.0;
          final int p0 = chain[aPos + seg];
          final int p1 = chain[aPos + seg + 1];
          outX.add(xs[p0] + (xs[p1] - xs[p0]) * t);
          outY.add(ys[p0] + (ys[p1] - ys[p0]) * t);
          outM.add(0);
          outC.add(cIdx);
        }
      }
    }

    int i = 0;
    while (i < n) {
      if (isSatinPt[i] != 0) {
        outX.add(xs[i]);
        outY.add(ys[i]);
        outM.add(mv[i]);
        outC.add(col[i]);
        i++;
        continue;
      }

      // تجميع سلسلة درز متصلة (Run Chain) من نفس اللون بدون قفزات
      final int cIdx = col[i];
      final bool startMove = mv[i] != 0 || outX.length == 0 || (i > 0 && col[i - 1] != cIdx);
      final List<int> chain = [i];
      int j = i + 1;
      while (j < n && mv[j] == 0 && col[j] == cIdx && isSatinPt[j] == 0) {
        chain.add(j);
        j++;
      }
      // إذا كان السطر ينتهي بالاتصال مع عمود فستون مباشرة، نربط النهاية بنقطة بداية الفستون
      if (j < n && mv[j] == 0 && col[j] == cIdx && isSatinPt[j] != 0) {
        chain.add(j);
      }
      emitResampledChain(chain, cIdx, startMove);
      i = j;
    }

    return (outX.finish(), outY.finish(), outM.finish(), outC.finish());
  }

  static Future<String?> exportVectorToFile(
    VectorDesignData vec,
    String outputPath,
    String targetExt, {
    String baseName = 'TARIK_EMB',
  }) async {
    try {
      final String ext = targetExt.toUpperCase().replaceAll('.', '');
      final Uint8List? bytes = await Isolate.run(() {
        if (vec.stX.length < 2) return null;
        switch (ext) {
          case 'DHE':
            return DahaoExporter.encode(vec, isDhe: true);
          case 'DHA':
            return DahaoExporter.encode(vec, isDhe: false);
          case 'EXP':
            return UniversalExporter._encodeExp(vec);
          case 'DSB':
            return UniversalExporter._encodeDsb(vec);
          case 'JEF':
            return UniversalExporter._encodeJef(vec);
          case 'TBF':
            return UniversalExporter._encodeTbf(vec);
          case 'XXX':
            return UniversalExporter._encodeXxx(vec);
          case 'DST':
          default:
            return DstExporter._encodeDstFromVector(vec, baseName);
        }
      });
      if (bytes == null || bytes.isEmpty) return null;
      final outFile = File(outputPath);
      await outFile.writeAsBytes(bytes, flush: true);
      return outFile.path;
    } catch (_) {
      return null;
    }
  }
}


/// محرك تحويل الكتابة العربية والإنجليزية إلى غرز تطريز احترافية (جيل 2 — مستوى Wilcom / Ink/Stitch)
/// المراحل الـ 7:
/// 1) تنظيف السلالم القطرية للهيكل (8-Connected Simple-Point Cleanup) لإلغاء التقاطعات الوهمية
/// 2) تقليم الشوائب الزاوية (Iterative Corner Spur Pruning)
/// 3) مدّ الأطراف حتى الحافة الحقيقية تحت البكسل (Subpixel Endpoint Extrapolation) لإصلاح قمة ألف «ط» والأطراف
/// 4) دمج الفروع المستقيمة وتداخل الأعمدة عند التقاطعات لإغلاق أي فراغ مثلثي
/// 5) إسقاط الأشعة تحت البكسل (Bilinear Ray-Casting) مع حماية «البوز» عند الزوايا وتنعيم الحواف
/// 6) تقصير الغرز متعدد المستويات (Ink/Stitch Sawtooth Shortening) + التبطين العكسي + تعويض الشد + Auto-Split
/// 7) فستون بيضوي نظيف (PCA Elliptical Satin) للنقط والتشكيل
class TextToStitchEngine {
  static Future<VectorDesignData?> generateFromText({
    required String text,
    double widthCm = 12.0,
    double? heightCm,
    double densityMm = 0.45,
    int colorArgb = 0xFFFF1744,
    bool isBold = true,
    bool isSatin = true,
    bool isItalic = false,
    String? fontFamily,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final bool isRtl = RegExp(r'[\u0600-\u06FF]').hasMatch(trimmed);

    // 1) رسم النص بدقة عالية (180px لوضوح أدق للحواف والزوايا) على لوحة شفافة
    const double fontSize = 180.0;
    final tp = TextPainter(
      text: TextSpan(
        text: trimmed,
        style: TextStyle(
          color: const Color(0xFFFFFFFF),
          fontSize: fontSize,
          fontWeight: isBold ? FontWeight.w800 : FontWeight.w500,
          fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
          fontFamily: fontFamily,
          height: 1.25,
        ),
      ),
      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: 2000);

    final int w = math.max(16, tp.width.ceil() + 32);
    final int h = math.max(16, tp.height.ceil() + 32);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    tp.paint(canvas, const Offset(16, 16));
    final picture = recorder.endRecording();
    final ui.Image img = await picture.toImage(w, h);
    final ByteData? rgba = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    picture.dispose();
    if (rgba == null) return null;

    final Uint8List pixels = rgba.buffer.asUint8List();

    // 2) تنفيذ الحسابات الهندسية في الخيط الخلفي (Isolate)
    return await Isolate.run(() {
      final raw = _buildStitchesFromMask(
        pixels: pixels,
        w: w,
        h: h,
        isRtl: isRtl,
        widthCm: widthCm,
        densityMm: densityMm,
        colorArgb: colorArgb,
        isSatin: isSatin,
      );
      if (raw == null) return null;
      // ضبط دقيق للطول والعرض بالـ سم حسب جدول المقاسات
      final double curW = (raw.widthMm ?? 0.0) / 10.0;
      final double curH = (raw.heightMm ?? 0.0) / 10.0;
      if (curW > 0.1 && curH > 0.1) {
        final double sx = (widthCm / curW).clamp(0.25, 4.0);
        final double sy = heightCm != null ? (heightCm / curH).clamp(0.25, 4.0) : sx;
        if ((sx - 1.0).abs() > 0.015 || (sy - 1.0).abs() > 0.015) {
          return VectorDesignEditor.transform(raw, scaleX: sx, scaleY: sy);
        }
      }
      return raw;
    });
  }

  static VectorDesignData? _buildStitchesFromMask({
    required Uint8List pixels,
    required int w,
    required int h,
    required bool isRtl,
    required double widthCm,
    required double densityMm,
    required int colorArgb,
    required bool isSatin,
  }) {
    // 1) فصل الكائنات المتصلة (Connected Components)
    final Int32List labels = Int32List(w * h);
    final List<_TextComp> comps = [];
    final List<int> queue = [];

    int nextLabel = 1;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int idx = y * w + x;
        if (labels[idx] != 0 || pixels[idx * 4 + 3] < 110) continue;

        final int cid = nextLabel++;
        labels[idx] = cid;
        queue.clear();
        queue.add(idx);
        int qHead = 0;
        int minX = x, maxX = x, minY = y, maxY = y;
        int area = 0;

        while (qHead < queue.length) {
          final int cur = queue[qHead++];
          final int cx = cur % w;
          final int cy = cur ~/ w;
          area++;
          if (cx < minX) minX = cx;
          if (cx > maxX) maxX = cx;
          if (cy < minY) minY = cy;
          if (cy > maxY) maxY = cy;

          for (int dy = -1; dy <= 1; dy++) {
            final int ny = cy + dy;
            if (ny < 0 || ny >= h) continue;
            for (int dx = -1; dx <= 1; dx++) {
              if (dx == 0 && dy == 0) continue;
              final int nx = cx + dx;
              if (nx < 0 || nx >= w) continue;
              final int nIdx = ny * w + nx;
              if (labels[nIdx] == 0 && pixels[nIdx * 4 + 3] >= 110) {
                labels[nIdx] = cid;
                queue.add(nIdx);
              }
            }
          }
        }

        if (area >= 12) {
          comps.add(_TextComp(cid, minX, maxX, minY, maxY, area));
        }
      }
    }

    if (comps.isEmpty) return null;

    // 2) فصل الأجسام عن النقط وترتيب القراءة
    int maxArea = 1;
    for (final c in comps) {
      if (c.area > maxArea) maxArea = c.area;
    }
    final List<_TextComp> bodies = [];
    final List<_TextComp> dots = [];
    final Set<int> dotIds = {};
    for (final c in comps) {
      final int cw = c.maxX - c.minX + 1;
      final int ch = c.maxY - c.minY + 1;
      final double aspect = math.max(cw, ch) / math.max(1.0, math.min(cw, ch).toDouble());
      if (c.area < maxArea * 0.16 && cw < 56 && ch < 56 && aspect < 2.1) {
        dots.add(c);
        dotIds.add(c.id);
      } else {
        bodies.add(c);
      }
    }

    if (isRtl) {
      bodies.sort((a, b) => b.maxX.compareTo(a.maxX));
      dots.sort((a, b) => b.centerX.compareTo(a.centerX));
    } else {
      bodies.sort((a, b) => a.minX.compareTo(b.minX));
      dots.sort((a, b) => a.centerX.compareTo(b.centerX));
    }

    final List<_TextComp> ordered = [];
    final Set<int> placedDots = {};
    for (final body in bodies) {
      ordered.add(body);
      for (final dot in dots) {
        if (placedDots.contains(dot.id)) continue;
        if (dot.centerX >= body.minX - 18 && dot.centerX <= body.maxX + 18) {
          ordered.add(dot);
          placedDots.add(dot.id);
        }
      }
    }
    for (final dot in dots) {
      if (!placedDots.contains(dot.id)) ordered.add(dot);
    }

    final double targetWidthUnits = (widthCm * 100.0).clamp(200.0, 4500.0);
    final double pxToUnits = targetWidthUnits / w;
    final double safeDensityMm = densityMm.clamp(0.25, 1.2);
    final double densityUnits = safeDensityMm * 10.0;
    final double rowStepPx = math.max(1.15, densityUnits / pxToUnits);
    final double stitchStepPx = math.max(2.5, 30.0 / pxToUnits);

    final stX = _Float32Buf(8192);
    final stY = _Float32Buf(8192);
    final stMove = _Uint8Buf(8192);
    final stColor = _Uint8Buf(8192);

    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int jumpCount = 0;
    double curNeedleX = 0.0, curNeedleY = 0.0;
    bool hasNeedlePos = false;

    void addPt(double ux, double uy, bool isMove) {
      bool actualMove = isMove;
      if (isMove && hasNeedlePos) {
        final double d = math.sqrt((ux - curNeedleX) * (ux - curNeedleX) + (uy - curNeedleY) * (uy - curNeedleY));
        if (d < 36.0) {
          // أقصر طريق للكائن المجاور بدون جنبات (Wilcom Closest-Join Bridge)
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
      hasNeedlePos = true;
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

    if (isSatin) {
      // ====== وضع الفستون الاحترافي من الجيل الثاني (Subpixel Ray-Cast + Corner Beaks + Multi-Level Shortening) ======
      for (final comp in ordered) {
        final int pad = 6;
        final int bw = (comp.maxX - comp.minX + 1) + pad * 2;
        final int bh = (comp.maxY - comp.minY + 1) + pad * 2;
        final int ox = comp.minX - pad;
        final int oy = comp.minY - pad;

        final Uint8List bin = Uint8List(bw * bh);
        final Uint8List alphaCrop = Uint8List(bw * bh);
        for (int y = math.max(0, oy); y < math.min(h, oy + bh); y++) {
          for (int x = math.max(0, ox); x < math.min(w, ox + bw); x++) {
            final int gIdx = y * w + x;
            final int lIdx = (y - oy) * bw + (x - ox);
            if (labels[gIdx] == comp.id) {
              bin[lIdx] = 1;
              alphaCrop[lIdx] = pixels[gIdx * 4 + 3];
            } else if (labels[gIdx] == 0) {
              // الإبقاء على تدرج الحواف الناعمة (Anti-Aliasing) فقط حول نفس الكائن لدقة تحت البكسل
              alphaCrop[lIdx] = pixels[gIdx * 4 + 3];
            }
          }
        }

        // المرحلة 7: إذا كان الكائن نقطة صغيرة (مثل نقط ق، ت، ث، ي) نطرزها بفستون بيضوي نظيف وممتلئ
        if (dotIds.contains(comp.id)) {
          _emitEllipticalDotSatin(
            bin: bin,
            bw: bw,
            bh: bh,
            ox: ox,
            oy: oy,
            pxToUnits: pxToUnits,
            rowStepPx: rowStepPx,
            addPt: addPt,
          );
          continue;
        }

        final Float32List distMap = _computeDistanceTransform(bin, bw, bh);

        // المرحلة 1: ترقيق الهيكل + تنظيف السلالم القطرية بالاتصال الثماني
        Uint8List skel = _zhangSuenThin(Uint8List.fromList(bin), bw, bh);
        skel = _cleanSkeleton8Connected(skel, bw, bh);

        // المرحلة 2: تقليم الشوائب الزاوية القصيرة (تنظيف أعلى الألف والزوايا الحادة)
        _pruneCornerSpurs(skel, distMap, bw, bh);
        skel = _cleanSkeleton8Connected(skel, bw, bh);

        // المرحلة 3 + 4: استخراج أعمدة الهيكل كرسم بياني + دمج الفروع المستقيمة + مدّ الأطراف حتى الحافة الفعلية
        List<_SkelColumn> columns = _extractAndMergeColumns(
          skel: skel,
          distMap: distMap,
          alphaCrop: alphaCrop,
          bw: bw,
          bh: bh,
          ox: ox,
          oy: oy,
        );

        if (columns.isEmpty) {
          _emitEllipticalDotSatin(
            bin: bin,
            bw: bw,
            bh: bh,
            ox: ox,
            oy: oy,
            pxToUnits: pxToUnits,
            rowStepPx: rowStepPx,
            addPt: addPt,
          );
          continue;
        }

        // إزالة الشظايا الميكروية (< 3.8px) التي تسبب تشويشاً عند التقاطعات
        if (columns.length > 1) {
          final cleanedCols = <_SkelColumn>[];
          for (final c in columns) {
            double clen = 0.0;
            for (int i = 1; i < c.pts.length; i++) {
              clen += math.sqrt(_dist2(c.pts[i - 1].$1, c.pts[i - 1].$2, c.pts[i].$1, c.pts[i].$2));
            }
            if (clen >= 3.8) cleanedCols.add(c);
          }
          if (cleanedCols.isNotEmpty) columns = cleanedCols;
        }

        // نقطة الجذب للكائن التالي (أقرب نقطة للانتقال السلس بدون جنبات)
        final int compIdxInOrdered = ordered.indexOf(comp);
        double? nextCompX, nextCompY;
        if (compIdxInOrdered >= 0 && compIdxInOrdered + 1 < ordered.length) {
          final nc = ordered[compIdxInOrdered + 1];
          nextCompX = isRtl ? nc.maxX.toDouble() : nc.minX.toDouble();
          nextCompY = (nc.minY + nc.maxY) * 0.5;
        }

        // خوارزمية Auto-Branching (ويلكم): ترتيب الأعمدة حسب أقرب مسار متسلسل وتحديد أسلوب التطريز (دخول بدرز ورجوع بفستون للفرع المغلق، أو عبور أمامي للفرع الموصل للكائن التالي)
        final List<_SkelColumn> orderedCols = [];
        final List<bool> used = List<bool>.filled(columns.length, false);
        double refX = hasNeedlePos ? (curNeedleX / pxToUnits) : (isRtl ? comp.maxX.toDouble() : comp.minX.toDouble());
        double refY = hasNeedlePos ? (curNeedleY / pxToUnits) : ((comp.minY + comp.maxY) * 0.5);

        for (int k = 0; k < columns.length; k++) {
          int bestIdx = -1;
          bool bestRev = false;
          double bestScore = 1e18;
          for (int j = 0; j < columns.length; j++) {
            if (used[j] || columns[j].pts.length < 2) continue;
            final pts = columns[j].pts;
            final dStart = _dist2(refX, refY, pts.first.$1, pts.first.$2);
            if (dStart < bestScore) {
              bestScore = dStart;
              bestIdx = j;
              bestRev = false;
            }
            final dEnd = _dist2(refX, refY, pts.last.$1, pts.last.$2);
            if (dEnd < bestScore) {
              bestScore = dEnd;
              bestIdx = j;
              bestRev = true;
            }
          }
          if (bestIdx == -1) break;
          used[bestIdx] = true;
          final chosen = columns[bestIdx];
          final orderedPts = bestRev ? chosen.pts.reversed.toList() : chosen.pts;
          orderedCols.add(_SkelColumn(orderedPts, chosen.isLoop));
          refX = orderedPts.last.$1;
          refY = orderedPts.last.$2;
        }

        // المرحلة 5 + 6: استخراج الحافتين بإسقاط الأشعة + تنقية التشويش بمرشح الوسيط + Auto-Branching بدون جنبات
        for (int cIdx = 0; cIdx < orderedCols.length; cIdx++) {
          final col = orderedCols[cIdx];
          // تحديد الهدف التالي (العمود التالي داخل الحرف أو الحرف المجاور)
          double? tgtX = nextCompX;
          double? tgtY = nextCompY;
          if (cIdx + 1 < orderedCols.length) {
            final nPts = orderedCols[cIdx + 1].pts;
            final dToFirst = _dist2(col.pts.last.$1, col.pts.last.$2, nPts.first.$1, nPts.first.$2);
            final dToStart = _dist2(col.pts.first.$1, col.pts.first.$2, nPts.first.$1, nPts.first.$2);
            tgtX = nPts.first.$1;
            tgtY = nPts.first.$2;
            // إذا كان الهدف التالي أقرب لبداية العمود (فرع جانبي مثل ألف ط): ندخل بدرز وسط ونرجع بفستون لنقطة الالتقاء بدون قفزة!
            final bool returnToStart = dToStart <= dToFirst;
            _emitSmoothRayCastSatinColumn(
              col: col,
              alphaCrop: alphaCrop,
              bw: bw,
              bh: bh,
              ox: ox,
              oy: oy,
              pxToUnits: pxToUnits,
              rowStepPx: rowStepPx,
              returnToStart: returnToStart,
              addPt: addPt,
            );
          } else {
            // آخر عمود في الحرف: إن كان الحرف التالي أقرب لنهايته نخرج عند نهايته مباشرة (Through-Branch) بدون قفزة
            bool returnToStart = true;
            if (tgtX != null && tgtY != null) {
              final dStart = _dist2(col.pts.first.$1, col.pts.first.$2, tgtX, tgtY);
              final dEnd = _dist2(col.pts.last.$1, col.pts.last.$2, tgtX, tgtY);
              returnToStart = dStart < dEnd;
            }
            _emitSmoothRayCastSatinColumn(
              col: col,
              alphaCrop: alphaCrop,
              bw: bw,
              bh: bh,
              ox: ox,
              oy: oy,
              pxToUnits: pxToUnits,
              rowStepPx: rowStepPx,
              returnToStart: returnToStart,
              addPt: addPt,
            );
          }
        }
      }
    } else {
      // ====== وضع التاتامي (Tatami Fill مع زاوية مناسبة لكل حرف وأقرب نقطة تلاقي) ======
      for (final comp in ordered) {
        final double cw = (comp.maxX - comp.minX + 1).toDouble();
        final double ch = (comp.maxY - comp.minY + 1).toDouble();
        final double cx = (comp.minX + comp.maxX) * 0.5;
        final double cy = (comp.minY + comp.maxY) * 0.5;

        double angleDeg;
        if (ch > cw * 1.35) {
          angleDeg = 12.0;
        } else if (cw > ch * 1.35) {
          angleDeg = 68.0;
        } else {
          angleDeg = 42.0;
        }

        final double rad = angleDeg * math.pi / 180.0;
        final double cosA = math.cos(rad);
        final double sinA = math.sin(rad);
        final double diag = math.sqrt(cw * cw + ch * ch) * 0.55 + 2.0;

        final List<List<(double, double, double)>> branches = [];

        for (double v = -diag; v <= diag; v += rowStepPx) {
          final List<(double, double)> rowRuns = [];
          double u = -diag;
          while (u <= diag) {
            final int sx = (cx + u * cosA - v * sinA).round();
            final int sy = (cy + u * sinA + v * cosA).round();
            if (sx >= comp.minX && sx <= comp.maxX && sy >= comp.minY && sy <= comp.maxY && labels[sy * w + sx] == comp.id) {
              final double uStart = u;
              while (u <= diag) {
                final int nx = (cx + u * cosA - v * sinA).round();
                final int ny = (cy + u * sinA + v * cosA).round();
                if (nx < comp.minX || nx > comp.maxX || ny < comp.minY || ny > comp.maxY || labels[ny * w + nx] != comp.id) {
                  break;
                }
                u += 1.0;
              }
              if (u - uStart >= 1.5) {
                rowRuns.add((uStart, u - 1.0));
              }
            } else {
              u += 1.0;
            }
          }

          for (final run in rowRuns) {
            List<(double, double, double)>? bestBranch;
            double bestDist = 1e9;
            for (final br in branches) {
              final last = br.last;
              if ((v - last.$1).abs() <= rowStepPx * 1.6) {
                final bool overlaps = run.$1 <= last.$3 + 4.0 && run.$2 >= last.$2 - 4.0;
                if (overlaps) {
                  final double d = ((run.$1 + run.$2) * 0.5 - (last.$2 + last.$3) * 0.5).abs();
                  if (d < bestDist) {
                    bestDist = d;
                    bestBranch = br;
                  }
                }
              }
            }
            if (bestBranch != null) {
              bestBranch.add((v, run.$1, run.$2));
            } else {
              branches.add([(v, run.$1, run.$2)]);
            }
          }
        }

        final List<bool> usedBr = List<bool>.filled(branches.length, false);
        for (int k = 0; k < branches.length; k++) {
          int bestIdx = -1;
          bool bestRev = false;
          double bestD = 1e18;
          final double refX = hasNeedlePos ? curNeedleX : (cx * pxToUnits);
          final double refY = hasNeedlePos ? curNeedleY : (cy * pxToUnits);

          for (int j = 0; j < branches.length; j++) {
            if (usedBr[j] || branches[j].isEmpty) continue;
            final s0 = branches[j].first;
            final x0 = (cx + s0.$2 * cosA - s0.$1 * sinA) * pxToUnits;
            final y0 = (cy + s0.$2 * sinA + s0.$1 * cosA) * pxToUnits;
            final d0 = _dist2(refX, refY, x0, y0);
            if (d0 < bestD) {
              bestD = d0;
              bestIdx = j;
              bestRev = false;
            }
            final s1 = branches[j].last;
            final x1 = (cx + s1.$2 * cosA - s1.$1 * sinA) * pxToUnits;
            final y1 = (cy + s1.$2 * sinA + s1.$1 * cosA) * pxToUnits;
            final d1 = _dist2(refX, refY, x1, y1);
            if (d1 < bestD) {
              bestD = d1;
              bestIdx = j;
              bestRev = true;
            }
          }
          if (bestIdx == -1) break;
          usedBr[bestIdx] = true;
          final br = bestRev ? branches[bestIdx].reversed.toList() : branches[bestIdx];

          bool forward = true;
          bool firstInBranch = true;
          for (final seg in br) {
            final double v = seg.$1;
            final double a = forward ? seg.$2 : seg.$3;
            final double b = forward ? seg.$3 : seg.$2;

            final double x0 = (cx + a * cosA - v * sinA) * pxToUnits;
            final double y0 = (cy + a * sinA + v * cosA) * pxToUnits;
            addPt(x0, y0, firstInBranch);
            firstInBranch = false;

            final double dist = (b - a).abs();
            if (dist > stitchStepPx) {
              final int steps = (dist / stitchStepPx).floor();
              for (int s = 1; s < steps; s++) {
                final double u = a + (b - a) * (s / steps);
                final double xm = (cx + u * cosA - v * sinA) * pxToUnits;
                final double ym = (cy + u * sinA + v * cosA) * pxToUnits;
                addPt(xm, ym, false);
              }
            }

            final double x1 = (cx + b * cosA - v * sinA) * pxToUnits;
            final double y1 = (cy + b * sinA + v * cosA) * pxToUnits;
            addPt(x1, y1, false);
            forward = !forward;
          }
        }
      }
    }

    if (stX.length < 2) return null;

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
      machineType: isSatin ? 'Tarik Pro Satin' : 'Tarik Tatami',
    );
  }

  static double _dist2(double x1, double y1, double x2, double y2) {
    final dx = x1 - x2;
    final dy = y1 - y2;
    return dx * dx + dy * dy;
  }

  static double _sampleAlphaBilinear(Uint8List alpha, int w, int h, double x, double y) {
    if (x < 0.0 || y < 0.0 || x >= w - 1 || y >= h - 1) return 0.0;
    final int ix = x.floor();
    final int iy = y.floor();
    final double fx = x - ix;
    final double fy = y - iy;
    final int row0 = iy * w + ix;
    final int row1 = row0 + w;
    final double v00 = alpha[row0].toDouble();
    final double v10 = alpha[row0 + 1].toDouble();
    final double v01 = alpha[row1].toDouble();
    final double v11 = alpha[row1 + 1].toDouble();
    return (v00 * (1.0 - fx) + v10 * fx) * (1.0 - fy) + (v01 * (1.0 - fx) + v11 * fx) * fy;
  }

  /// إسقاط شعاع من (cx, cy) بالاتجاه (dx, dy) لإيجاد المسافة الدقيقة تحت البكسل إلى حافة الحرف
  static double _rayEdgeDist(Uint8List alpha, int w, int h, double cx, double cy, double dx, double dy, {double maxD = 42.0, double thresh = 115.0}) {
    double prevT = 0.0;
    double t = 0.5;
    while (t <= maxD) {
      if (_sampleAlphaBilinear(alpha, w, h, cx + dx * t, cy + dy * t) < thresh) {
        double lo = prevT, hi = t;
        for (int k = 0; k < 5; k++) {
          final double mid = 0.5 * (lo + hi);
          if (_sampleAlphaBilinear(alpha, w, h, cx + dx * mid, cy + dy * mid) >= thresh) {
            lo = mid;
          } else {
            hi = mid;
          }
        }
        return 0.5 * (lo + hi);
      }
      prevT = t;
      t += 0.5;
    }
    return maxD;
  }

  static void _emitEllipticalDotSatin({
    required Uint8List bin,
    required int bw,
    required int bh,
    required int ox,
    required int oy,
    required double pxToUnits,
    required double rowStepPx,
    required void Function(double, double, bool) addPt,
  }) {
    double sumX = 0, sumY = 0;
    int cnt = 0;
    for (int y = 0; y < bh; y++) {
      for (int x = 0; x < bw; x++) {
        if (bin[y * bw + x] != 0) {
          sumX += x;
          sumY += y;
          cnt++;
        }
      }
    }
    if (cnt == 0) return;
    final double cx = sumX / cnt;
    final double cy = sumY / cnt;

    // تحليل المحور الرئيسي (PCA) لزاوية النقطة
    double sxx = 0, syy = 0, sxy = 0;
    for (int y = 0; y < bh; y++) {
      for (int x = 0; x < bw; x++) {
        if (bin[y * bw + x] != 0) {
          final dx = x - cx, dy = y - cy;
          sxx += dx * dx;
          syy += dy * dy;
          sxy += dx * dy;
        }
      }
    }
    final double angle = 0.5 * math.atan2(2.0 * sxy, sxx - syy);
    final double ca = math.cos(angle), sa = math.sin(angle);

    double minU = 1e9, maxU = -1e9, minV = 1e9, maxV = -1e9;
    for (int y = 0; y < bh; y++) {
      for (int x = 0; x < bw; x++) {
        if (bin[y * bw + x] != 0) {
          final dx = x - cx, dy = y - cy;
          final u = dx * ca + dy * sa;
          final v = -dx * sa + dy * ca;
          if (u < minU) minU = u;
          if (u > maxU) maxU = u;
          if (v < minV) minV = v;
          if (v > maxV) maxV = v;
        }
      }
    }

    final double halfU = math.max(1.8, (maxU - minU) * 0.52);
    final double halfV = math.max(1.8, (maxV - minV) * 0.52);
    final int steps = math.max(4, ((halfU * 2.0) / math.max(1.0, rowStepPx)).ceil());

    // درز تثبيت وسطي أولاً ثم فستون بيضوي منتظم
    final double gx = cx + ox, gy = cy + oy;
    addPt((gx - halfU * 0.7 * ca) * pxToUnits, (gy - halfU * 0.7 * sa) * pxToUnits, true);
    addPt((gx + halfU * 0.7 * ca) * pxToUnits, (gy + halfU * 0.7 * sa) * pxToUnits, false);

    for (int i = steps; i >= 0; i--) {
      final double frac = -1.0 + 2.0 * (i / steps);
      final double u = frac * halfU;
      final double spanV = halfV * math.sqrt(math.max(0.08, 1.0 - frac * frac * 0.92));
      final double lx = (gx + u * ca - spanV * sa) * pxToUnits;
      final double ly = (gy + u * sa + spanV * ca) * pxToUnits;
      final double rx = (gx + u * ca + spanV * sa) * pxToUnits;
      final double ry = (gy + u * sa - spanV * ca) * pxToUnits;
      addPt(lx, ly, false);
      addPt(rx, ry, false);
    }
  }

  static Float32List _computeDistanceTransform(Uint8List bin, int w, int h) {
    final dist = Float32List(w * h);
    const double inf = 1e6;
    for (int i = 0; i < w * h; i++) {
      dist[i] = bin[i] != 0 ? inf : 0.0;
    }
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final int idx = y * w + x;
        if (dist[idx] == 0.0) continue;
        double m = dist[idx];
        final double d1 = dist[idx - 1] + 1.0;
        final double d2 = dist[idx - w] + 1.0;
        final double d3 = dist[idx - w - 1] + 1.414;
        final double d4 = dist[idx - w + 1] + 1.414;
        if (d1 < m) m = d1;
        if (d2 < m) m = d2;
        if (d3 < m) m = d3;
        if (d4 < m) m = d4;
        dist[idx] = m;
      }
    }
    for (int y = h - 2; y >= 1; y--) {
      for (int x = w - 2; x >= 1; x--) {
        final int idx = y * w + x;
        if (dist[idx] == 0.0) continue;
        double m = dist[idx];
        final double d1 = dist[idx + 1] + 1.0;
        final double d2 = dist[idx + w] + 1.0;
        final double d3 = dist[idx + w + 1] + 1.414;
        final double d4 = dist[idx + w - 1] + 1.414;
        if (d1 < m) m = d1;
        if (d2 < m) m = d2;
        if (d3 < m) m = d3;
        if (d4 < m) m = d4;
        dist[idx] = m;
      }
    }
    return dist;
  }

  static Uint8List _zhangSuenThin(Uint8List img, int w, int h) {
    final List<int> toRemove = [];
    for (int iter = 0; iter < 54; iter++) {
      bool changed = false;
      for (int step = 0; step < 2; step++) {
        toRemove.clear();
        for (int y = 1; y < h - 1; y++) {
          final int row = y * w;
          for (int x = 1; x < w - 1; x++) {
            final int idx = row + x;
            if (img[idx] == 0) continue;
            final int p2 = img[idx - w];
            final int p3 = img[idx - w + 1];
            final int p4 = img[idx + 1];
            final int p5 = img[idx + w + 1];
            final int p6 = img[idx + w];
            final int p7 = img[idx + w - 1];
            final int p8 = img[idx - 1];
            final int p9 = img[idx - w - 1];

            final int b = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9;
            if (b < 2 || b > 6) continue;

            int a = 0;
            if (p2 == 0 && p3 == 1) a++;
            if (p3 == 0 && p4 == 1) a++;
            if (p4 == 0 && p5 == 1) a++;
            if (p5 == 0 && p6 == 1) a++;
            if (p6 == 0 && p7 == 1) a++;
            if (p7 == 0 && p8 == 1) a++;
            if (p8 == 0 && p9 == 1) a++;
            if (p9 == 0 && p2 == 1) a++;
            if (a != 1) continue;

            if (step == 0) {
              if (p2 * p4 * p6 != 0) continue;
              if (p4 * p6 * p8 != 0) continue;
            } else {
              if (p2 * p4 * p8 != 0) continue;
              if (p2 * p6 * p8 != 0) continue;
            }
            toRemove.add(idx);
          }
        }
        if (toRemove.isNotEmpty) {
          for (final idx in toRemove) {
            img[idx] = 0;
          }
          changed = true;
        }
      }
      if (!changed) break;
    }
    return img;
  }

  /// تنظيف السلالم القطرية الزائدة بشرط بقاء الجيران الثمانية في مكوّن متصل واحد
  static Uint8List _cleanSkeleton8Connected(Uint8List img, int w, int h) {
    const ring = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)];
    final List<(int, int)> nbs = [];
    final List<bool> vis = List<bool>.filled(8, false);
    final List<int> q = [];

    for (int y = 1; y < h - 1; y++) {
      final int row = y * w;
      for (int x = 1; x < w - 1; x++) {
        final int idx = row + x;
        if (img[idx] == 0) continue;
        final int p2 = img[idx - w];
        final int p4 = img[idx + 1];
        final int p6 = img[idx + w];
        final int p8 = img[idx - 1];
        if (!((p2 != 0 && p4 != 0) || (p4 != 0 && p6 != 0) || (p6 != 0 && p8 != 0) || (p8 != 0 && p2 != 0))) {
          continue;
        }

        nbs.clear();
        for (int k = 0; k < 8; k++) {
          final nx = x + ring[k].$1;
          final ny = y + ring[k].$2;
          if (img[ny * w + nx] != 0) nbs.add((nx, ny));
        }
        if (nbs.length <= 1) continue;

        for (int k = 0; k < nbs.length; k++) {
          vis[k] = false;
        }
        q.clear();
        vis[0] = true;
        q.add(0);
        int reached = 1;
        while (q.isNotEmpty) {
          final int cur = q.removeLast();
          final cx = nbs[cur].$1, cy = nbs[cur].$2;
          for (int k = 0; k < nbs.length; k++) {
            if (!vis[k] && (nbs[k].$1 - cx).abs() <= 1 && (nbs[k].$2 - cy).abs() <= 1) {
              vis[k] = true;
              q.add(k);
              reached++;
            }
          }
        }
        if (reached == nbs.length) {
          img[idx] = 0;
        }
      }
    }
    return img;
  }

  /// تقليم الشوائب الزاوية القصيرة التي تنتج عن الترقيق عند رؤوس الحروف المستقيمة (مثل أعلى ألف «ط»)
  static void _pruneCornerSpurs(Uint8List skel, Float32List distMap, int w, int h) {
    const dirs = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)];

    List<(int, int)> nbsOf(int x, int y) {
      final List<(int, int)> res = [];
      for (final d in dirs) {
        final nx = x + d.$1, ny = y + d.$2;
        if (nx >= 0 && nx < w && ny >= 0 && ny < h && skel[ny * w + nx] != 0) {
          res.add((nx, ny));
        }
      }
      return res;
    }

    for (int pass = 0; pass < 6; pass++) {
      bool prunedAny = false;
      final List<(int, int)> endpoints = [];
      for (int y = 1; y < h - 1; y++) {
        for (int x = 1; x < w - 1; x++) {
          if (skel[y * w + x] != 0 && nbsOf(x, y).length == 1) {
            endpoints.add((x, y));
          }
        }
      }

      for (final ep in endpoints) {
        if (skel[ep.$2 * w + ep.$1] == 0) continue;
        final List<(int, int)> branch = [ep];
        (int, int)? prev;
        int cx = ep.$1, cy = ep.$2;
        double len = 0.0;
        (int, int)? hitJunction;

        while (true) {
          final ns = nbsOf(cx, cy).where((p) => prev == null || p.$1 != prev.$1 || p.$2 != prev.$2).toList();
          if (ns.isEmpty) break;
          if (ns.length >= 2) {
            hitJunction = (cx, cy);
            break;
          }
          final nxt = ns.first;
          len += math.sqrt(((nxt.$1 - cx) * (nxt.$1 - cx) + (nxt.$2 - cy) * (nxt.$2 - cy)).toDouble());
          if (nbsOf(nxt.$1, nxt.$2).length >= 3) {
            hitJunction = nxt;
            break;
          }
          branch.add(nxt);
          prev = (cx, cy);
          cx = nxt.$1;
          cy = nxt.$2;
          if (len > 45.0) break;
        }

        if (hitJunction != null) {
          final double jr = distMap[hitJunction.$2 * w + hitJunction.$1];
          if (len <= math.max(jr * 1.58, 6.0)) {
            for (final pt in branch) {
              skel[pt.$2 * w + pt.$1] = 0;
            }
            prunedAny = true;
          }
        }
      }
      if (!prunedAny) break;
    }
  }

  /// استخراج الأعمدة من الهيكل المنظف + دمج الفروع المستقيمة عبر التقاطعات + مدّ الأطراف حتى الحافة الفعلية
  static List<_SkelColumn> _extractAndMergeColumns({
    required Uint8List skel,
    required Float32List distMap,
    required Uint8List alphaCrop,
    required int bw,
    required int bh,
    required int ox,
    required int oy,
  }) {
    const dirs = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)];
    final Uint8List deg = Uint8List(bw * bh);
    for (int y = 1; y < bh - 1; y++) {
      for (int x = 1; x < bw - 1; x++) {
        final int idx = y * bw + x;
        if (skel[idx] == 0) continue;
        int d = 0;
        for (final dir in dirs) {
          if (skel[(y + dir.$2) * bw + (x + dir.$1)] != 0) d++;
        }
        deg[idx] = d;
      }
    }

    final Set<int> visitedEdges = {};
    final List<_RawEdge> rawEdges = [];

    int edgeKey(int a, int b) => a < b ? (a * 1000003 + b) : (b * 1000003 + a);

    void traceFromNode(int startIdx) {
      final int sx = startIdx % bw, sy = startIdx ~/ bw;
      for (final dir in dirs) {
        final int nx = sx + dir.$1, ny = sy + dir.$2;
        if (nx < 0 || nx >= bw || ny < 0 || ny >= bh) continue;
        final int nIdx = ny * bw + nx;
        if (skel[nIdx] == 0) continue;
        final int ek = edgeKey(startIdx, nIdx);
        if (visitedEdges.contains(ek)) continue;

        final List<(double, double, double)> pts = [
          (sx.toDouble(), sy.toDouble(), distMap[startIdx]),
        ];
        int prev = startIdx;
        int cur = nIdx;
        visitedEdges.add(ek);

        while (true) {
          final int cx = cur % bw, cy = cur ~/ bw;
          pts.add((cx.toDouble(), cy.toDouble(), distMap[cur]));
          if (deg[cur] != 2 || cur == startIdx) break;

          int nextIdx = -1;
          for (final d2 in dirs) {
            final int tx = cx + d2.$1, ty = cy + d2.$2;
            if (tx < 0 || tx >= bw || ty < 0 || ty >= bh) continue;
            final int cand = ty * bw + tx;
            if (skel[cand] != 0 && cand != prev) {
              nextIdx = cand;
              break;
            }
          }
          if (nextIdx == -1) break;
          final int ek2 = edgeKey(cur, nextIdx);
          if (visitedEdges.contains(ek2)) {
            final int tx = nextIdx % bw, ty = nextIdx ~/ bw;
            pts.add((tx.toDouble(), ty.toDouble(), distMap[nextIdx]));
            break;
          }
          visitedEdges.add(ek2);
          prev = cur;
          cur = nextIdx;
        }

        if (pts.length >= 2) {
          final int endIdx = cur;
          final bool startFree = deg[startIdx] == 1;
          final bool endFree = deg[endIdx] == 1;
          rawEdges.add(_RawEdge(pts, startIdx, endIdx, startFree, endFree, startIdx == endIdx));
        }
      }
    }

    // 1) نبدأ من العقد (الأطراف والتقاطعات: deg != 2)
    for (int i = 0; i < bw * bh; i++) {
      if (skel[i] != 0 && deg[i] != 2) {
        traceFromNode(i);
      }
    }
    // 2) الحلقات المغلقة النقية (كل نقاطها deg == 2)
    for (int i = 0; i < bw * bh; i++) {
      if (skel[i] != 0 && deg[i] == 2) {
        final int sx = i % bw, sy = i ~/ bw;
        bool hasUnvisited = false;
        for (final dir in dirs) {
          final nx = sx + dir.$1, ny = sy + dir.$2;
          if (nx >= 0 && nx < bw && ny >= 0 && ny < bh) {
            final nIdx = ny * bw + nx;
            if (skel[nIdx] != 0 && !visitedEdges.contains(edgeKey(i, nIdx))) {
              hasUnvisited = true;
              break;
            }
          }
        }
        if (hasUnvisited) traceFromNode(i);
      }
    }

    // دمج الفروع الأكثر استقامةً عند كل تقاطع (Collinear Merging) لتشكيل أعمدة متواصلة (مثل كامل ألف ط وكامل القاعدة)
    final List<_RawEdge> merged = List.from(rawEdges);
    bool didMerge = true;
    while (didMerge) {
      didMerge = false;
      double bestDot = 0.55; // لا ندمج إلا الفروع المتقاربة في الاتجاه (زاوية انحراف < 56°)
      int bestA = -1, bestB = -1;
      bool flipA = false, flipB = false;

      (double, double) endDir(List<(double, double, double)> pts, bool atStart) {
        final int span = math.min(pts.length - 1, 6);
        final a = atStart ? pts[span] : pts[pts.length - 1 - span];
        final b = atStart ? pts.first : pts.last;
        final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
        final l = math.sqrt(dx * dx + dy * dy);
        return l > 1e-4 ? (dx / l, dy / l) : (0.0, 0.0);
      }

      for (int i = 0; i < merged.length; i++) {
        if (merged[i].isLoop) continue;
        for (int j = i + 1; j < merged.length; j++) {
          if (merged[j].isLoop) continue;
          // فحص الأطراف المشتركة عند نفس التقاطع
          final pairs = [
            (merged[i].endNode, merged[j].startNode, false, false),
            (merged[i].endNode, merged[j].endNode, false, true),
            (merged[i].startNode, merged[j].startNode, true, false),
            (merged[i].startNode, merged[j].endNode, true, true),
          ];
          for (final pr in pairs) {
            if (pr.$1 == pr.$2 && deg[pr.$1] >= 3) {
              final dA = endDir(merged[i].pts, pr.$3);
              final dB = endDir(merged[j].pts, pr.$4);
              // استمرار مستقيم يعني المتجهين متعاكسين بالنسبة لنقطة الالتقاء (dA . (-dB) قريب من 1)
              final double dot = -(dA.$1 * dB.$1 + dA.$2 * dB.$2);
              if (dot > bestDot) {
                bestDot = dot;
                bestA = i;
                bestB = j;
                flipA = pr.$3;
                flipB = pr.$4;
              }
            }
          }
        }
      }

      if (bestA != -1 && bestB != -1) {
        final eA = merged[bestA];
        final eB = merged[bestB];
        final ptsA = flipA ? eA.pts.reversed.toList() : List<(double, double, double)>.from(eA.pts);
        final ptsB = flipB ? eB.pts.reversed.toList() : List<(double, double, double)>.from(eB.pts);
        final combined = [...ptsA, ...ptsB.skip(1)];
        final int newStart = flipA ? eA.endNode : eA.startNode;
        final int newEnd = flipB ? eB.startNode : eB.endNode;
        final bool newStartFree = flipA ? eA.endFree : eA.startFree;
        final bool newEndFree = flipB ? eB.startFree : eB.endFree;
        merged.removeAt(bestB);
        merged[bestA] = _RawEdge(combined, newStart, newEnd, newStartFree, newEndFree, newStart == newEnd);
        didMerge = true;
      }
    }

    // المرحلة 3: مدّ الأطراف الحرة بدقة تحت البكسل حتى الحافة الفعلية (إصلاح نقص أعلى ألف «ط» ونقص البوز)
    // ومدّ الأطراف المتصلة بتقاطع مسافة 0.55*r داخل العمود الرئيسي لإغلاق أي فراغ مثلثي
    final List<_SkelColumn> result = [];
    for (final edge in merged) {
      final pts = List<(double, double, double)>.from(edge.pts);
      if (pts.length < 2) continue;

      void extendEnd(bool atStart, bool isFreeTip) {
        final int span = math.min(pts.length - 1, math.max(3, (pts.length * 0.2).round()));
        final anchor = atStart ? pts[span] : pts[pts.length - 1 - span];
        final tip = atStart ? pts.first : pts.last;
        double dx = tip.$1 - anchor.$1;
        double dy = tip.$2 - anchor.$2;
        final double l = math.sqrt(dx * dx + dy * dy);
        if (l < 1e-4) return;
        dx /= l;
        dy /= l;

        final double rTip = math.max(1.8, tip.$3);
        double extLen;
        if (isFreeTip) {
          // مدّ الطرف الحر حتى الحافة الحقيقية (alpha == 115) تماماً
          final double hit = _rayEdgeDist(alphaCrop, bw, bh, tip.$1, tip.$2, dx, dy, maxD: rTip * 2.1 + 4.0);
          extLen = math.max(0.0, hit - 0.35);
        } else {
          // تداخل نظيف داخل العمود الرئيسي عند التقاطع (0.55 * r)
          final double hit = _rayEdgeDist(alphaCrop, bw, bh, tip.$1, tip.$2, dx, dy, maxD: rTip * 1.1);
          extLen = math.min(rTip * 0.58, math.max(0.0, hit - 0.8));
        }

        if (extLen >= 0.8) {
          final int steps = math.max(1, (extLen / 1.5).ceil());
          final List<(double, double, double)> added = [];
          for (int s = 1; s <= steps; s++) {
            final double d = extLen * (s / steps);
            added.add((tip.$1 + dx * d, tip.$2 + dy * d, rTip));
          }
          if (atStart) {
            pts.insertAll(0, added.reversed);
          } else {
            pts.addAll(added);
          }
        }
      }

      if (!edge.isLoop) {
        extendEnd(true, edge.startFree);
        extendEnd(false, edge.endFree);
      }

      // تحويل الإحداثيات إلى نظام النص الكلي (+ox, +oy)
      final globalPts = pts.map((p) => (p.$1 + ox, p.$2 + oy, p.$3)).toList();
      result.add(_SkelColumn(globalPts, edge.isLoop));
    }

    return result;
  }

  /// المرحلة 5 + 6: استخراج الحافتين بإسقاط الأشعة تحت البكسل (مع حماية البوز) + تنعيم الحواف + تقصير متعدد المستويات
  static double _median3(double a, double b, double c) {
    if (a > b) {
      if (b > c) return b;
      return a > c ? c : a;
    } else {
      if (a > c) return a;
      return b > c ? c : b;
    }
  }

  static void _emitSmoothRayCastSatinColumn({
    required _SkelColumn col,
    required Uint8List alphaCrop,
    required int bw,
    required int bh,
    required int ox,
    required int oy,
    required double pxToUnits,
    required double rowStepPx,
    required bool returnToStart,
    required void Function(double, double, bool) addPt,
  }) {
    final resampled = _cornerPreservingSmoothAndResample(col.pts, rowStepPx, col.isLoop);
    if (resampled.length < 2) return;

    // 1) معادلة Auto-Branching:
    // - إذا returnToStart = true (فرع جانبي مثل ألف ط): الدخول بدرز وسط للأمام والرجوع بفستون لنقطة الالتقاء بدون قفزة!
    // - إذا returnToStart = false (فرع موصّل للكائن التالي): درز وسط ذهاب وإياب خفيف أو تثبيت ثم فستون للأمام حتى يخرج عند أقرب نقطة للكائن المجاور!
    final double runStepUnits = 22.0;
    void emitCenterRun(List<(double, double, double)> path, bool startWithMove) {
      addPt(path.first.$1 * pxToUnits, path.first.$2 * pxToUnits, startWithMove);
      double accRun = 0.0;
      for (int i = 1; i < path.length; i++) {
        final dx = (path[i].$1 - path[i - 1].$1) * pxToUnits;
        final dy = (path[i].$2 - path[i - 1].$2) * pxToUnits;
        accRun += math.sqrt(dx * dx + dy * dy);
        if (accRun >= runStepUnits || i == path.length - 1) {
          addPt(path[i].$1 * pxToUnits, path[i].$2 * pxToUnits, false);
          accRun = 0.0;
        }
      }
    }

    final List<(double, double, double)> satinPath;
    if (returnToStart) {
      emitCenterRun(resampled, true);
      satinPath = resampled.reversed.toList();
    } else {
      // للفرع الموصّل: نبدأ من البداية (أقرب نقطة للفرع السابق)، نثبّت الحافة الأولى ذهاباً وإياباً فقط إذا كان العمود طويلاً، ثم نطرز فستون للأمام نحو الكائن التالي
      addPt(resampled.first.$1 * pxToUnits, resampled.first.$2 * pxToUnits, true);
      satinPath = resampled;
    }

    // 2) استخراج عرض الحافتين بإسقاط الأشعة تحت البكسل + مرشح الوسيط (Median-3) لإزالة أي تشويش أو طفرات في العرض
    final int n = satinPath.length;
    final List<double> nxArr = List<double>.filled(n, 0.0);
    final List<double> nyArr = List<double>.filled(n, 0.0);
    final List<double> dLArr = List<double>.filled(n, 0.0);
    final List<double> dRArr = List<double>.filled(n, 0.0);
    final List<bool> bendArr = List<bool>.filled(n, false);

    for (int i = 0; i < n; i++) {
      final int iPrev = math.max(0, i - 2);
      final int iNext = math.min(n - 1, i + 2);
      final double tx = satinPath[iNext].$1 - satinPath[iPrev].$1;
      final double ty = satinPath[iNext].$2 - satinPath[iPrev].$2;
      final double tLen = math.sqrt(tx * tx + ty * ty);
      double nx = 0.0, ny = 1.0;
      if (tLen > 1e-4) {
        nx = -ty / tLen;
        ny = tx / tLen;
      }
      nxArr[i] = nx;
      nyArr[i] = ny;

      bool isBend = false;
      if (i > 1 && i < n - 2) {
        final double v1x = satinPath[i].$1 - satinPath[i - 2].$1, v1y = satinPath[i].$2 - satinPath[i - 2].$2;
        final double v2x = satinPath[i + 2].$1 - satinPath[i].$1, v2y = satinPath[i + 2].$2 - satinPath[i].$2;
        final double l1 = math.sqrt(v1x * v1x + v1y * v1y);
        final double l2 = math.sqrt(v2x * v2x + v2y * v2y);
        if (l1 > 1e-3 && l2 > 1e-3 && (v1x * v2x + v1y * v2y) / (l1 * l2) < 0.78) {
          isBend = true;
        }
      }
      bendArr[i] = isBend;

      final double cx = satinPath[i].$1 - ox;
      final double cy = satinPath[i].$2 - oy;
      final double rBase = satinPath[i].$3.clamp(1.6, 36.0);
      final double maxAllowed = isBend ? (rBase * 2.25) : (rBase * 1.44);

      double dLeft = _rayEdgeDist(alphaCrop, bw, bh, cx, cy, nx, ny, maxD: maxAllowed + 4.0);
      double dRight = _rayEdgeDist(alphaCrop, bw, bh, cx, cy, -nx, -ny, maxD: maxAllowed + 4.0);

      if (dLeft > maxAllowed) dLeft = rBase * 1.03;
      if (dRight > maxAllowed) dRight = rBase * 1.03;
      if (dLeft < 0.8 && dRight < 0.8) {
        dLeft = rBase * 0.95;
        dRight = rBase * 0.95;
      }

      final double pullPx = 1.2 / pxToUnits;
      dLArr[i] = dLeft + pullPx;
      dRArr[i] = dRight + pullPx;
    }

    // مرشح الوسيط (Median-3) لإزالة الطفرات العرضية الناتجة عن التقاطعات مع حماية البوز الحقيقي
    if (n >= 3) {
      final fL = List<double>.from(dLArr);
      final fR = List<double>.from(dRArr);
      for (int i = 1; i < n - 1; i++) {
        if (!bendArr[i]) {
          fL[i] = _median3(dLArr[i - 1], dLArr[i], dLArr[i + 1]);
          fR[i] = _median3(dRArr[i - 1], dRArr[i], dRArr[i + 1]);
        }
      }
      for (int i = 0; i < n; i++) {
        dLArr[i] = fL[i];
        dRArr[i] = fR[i];
      }
    }

    final List<double> lxArr = List<double>.filled(n, 0.0);
    final List<double> lyArr = List<double>.filled(n, 0.0);
    final List<double> rxArr = List<double>.filled(n, 0.0);
    final List<double> ryArr = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      lxArr[i] = satinPath[i].$1 + nxArr[i] * dLArr[i];
      lyArr[i] = satinPath[i].$2 + nyArr[i] * dLArr[i];
      rxArr[i] = satinPath[i].$1 - nxArr[i] * dRArr[i];
      ryArr[i] = satinPath[i].$2 - nyArr[i] * dRArr[i];
    }

    // 3) تنعيم الحافتين مع حماية الزوايا الحادة (البوز لا يُقص ولا يُدوّر!)
    _smoothRailPreserveCorners(lxArr, lyArr, passes: 3);
    _smoothRailPreserveCorners(rxArr, ryArr, passes: 3);

    // 4) توليد الغرز العلوية مع التقصير متعدد المستويات (Ink/Stitch #3987) وتقسيم الغرز العريضة جداً (> 8.5 مم)
    double? lastFullLx, lastFullLy, lastFullRx, lastFullRy;
    int shortStreakL = 0, shortStreakR = 0;

    for (int i = 0; i < n; i++) {
      final double lx = lxArr[i] * pxToUnits;
      final double ly = lyArr[i] * pxToUnits;
      final double rx = rxArr[i] * pxToUnits;
      final double ry = ryArr[i] * pxToUnits;

      final double dx = rx - lx, dy = ry - ly;
      final double widthUnits = math.sqrt(dx * dx + dy * dy);

      double emitLx = lx, emitLy = ly, emitRx = rx, emitRy = ry;
      bool shortenedL = false, shortenedR = false;

      if (lastFullLx != null && lastFullLy != null && lastFullRx != null && lastFullRy != null && widthUnits > 10.0) {
        final double dL = math.sqrt((lx - lastFullLx) * (lx - lastFullLx) + (ly - lastFullLy) * (ly - lastFullLy));
        final double dR = math.sqrt((rx - lastFullRx) * (rx - lastFullRx) + (ry - lastFullRy) * (ry - lastFullRy));

        if (dL < 3.8 && dR > 4.2 && shortStreakL < 2) {
          final double inset = shortStreakL == 0 ? 0.22 : 0.40;
          emitLx = lx + dx * inset;
          emitLy = ly + dy * inset;
          shortenedL = true;
          shortStreakL++;
        } else {
          shortStreakL = 0;
        }

        if (!shortenedL && dR < 3.8 && dL > 4.2 && shortStreakR < 2) {
          final double inset = shortStreakR == 0 ? 0.22 : 0.40;
          emitRx = rx - dx * inset;
          emitRy = ry - dy * inset;
          shortenedR = true;
          shortStreakR++;
        } else {
          shortStreakR = 0;
        }
      }

      if (widthUnits > 85.0) {
        final double sp = (i % 3 == 0) ? 0.36 : ((i % 3 == 1) ? 0.54 : 0.44);
        addPt(emitLx, emitLy, false);
        addPt(emitLx + (emitRx - emitLx) * sp, emitLy + (emitRy - emitLy) * sp, false);
        addPt(emitRx, emitRy, false);
      } else {
        addPt(emitLx, emitLy, false);
        addPt(emitRx, emitRy, false);
      }

      if (!shortenedL) {
        lastFullLx = lx;
        lastFullLy = ly;
      }
      if (!shortenedR) {
        lastFullRx = rx;
        lastFullRy = ry;
      }
    }
  }

  /// تنعيم الحافة مع حماية النقاط الزاوية الحادة (البوز)
  static void _smoothRailPreserveCorners(List<double> xs, List<double> ys, {int passes = 3}) {
    final int n = xs.length;
    if (n <= 3) return;
    final nx = List<double>.filled(n, 0.0);
    final ny = List<double>.filled(n, 0.0);
    for (int p = 0; p < passes; p++) {
      nx[0] = xs[0];
      ny[0] = ys[0];
      nx[n - 1] = xs[n - 1];
      ny[n - 1] = ys[n - 1];
      for (int i = 1; i < n - 1; i++) {
        final double v1x = xs[i] - xs[i - 1], v1y = ys[i] - ys[i - 1];
        final double v2x = xs[i + 1] - xs[i], v2y = ys[i + 1] - ys[i];
        final double l1 = math.sqrt(v1x * v1x + v1y * v1y);
        final double l2 = math.sqrt(v2x * v2x + v2y * v2y);
        double w = 0.25;
        if (l1 > 1e-4 && l2 > 1e-4) {
          final double cosT = (v1x * v2x + v1y * v2y) / (l1 * l2);
          if (cosT < 0.72) {
            // زاوية حادة / بوز -> لا ننعّمها حتى تحافظ على حدّتها
            w = 0.0;
          }
        }
        nx[i] = xs[i] * (1.0 - 2.0 * w) + (xs[i - 1] + xs[i + 1]) * w;
        ny[i] = ys[i] * (1.0 - 2.0 * w) + (ys[i - 1] + ys[i + 1]) * w;
      }
      for (int i = 0; i < n; i++) {
        xs[i] = nx[i];
        ys[i] = ny[i];
      }
    }
  }

  /// تنعيم خط الوسط مع حماية الزوايا الحادة وإعادة التوزيع حسب كثافة الغرز
  static List<(double, double, double)> _cornerPreservingSmoothAndResample(
    List<(double, double, double)> raw,
    double stepPx,
    bool isLoop,
  ) {
    if (raw.length <= 2) return raw;

    List<(double, double, double)> pts = List.from(raw);
    for (int pass = 0; pass < 3; pass++) {
      final List<(double, double, double)> next = [pts.first];
      for (int i = 1; i < pts.length - 1; i++) {
        final double v1x = pts[i].$1 - pts[i - 1].$1, v1y = pts[i].$2 - pts[i - 1].$2;
        final double v2x = pts[i + 1].$1 - pts[i].$1, v2y = pts[i + 1].$2 - pts[i].$2;
        final double l1 = math.sqrt(v1x * v1x + v1y * v1y);
        final double l2 = math.sqrt(v2x * v2x + v2y * v2y);
        double w = 0.25;
        if (l1 > 1e-4 && l2 > 1e-4) {
          final double cosT = (v1x * v2x + v1y * v2y) / (l1 * l2);
          if (cosT < 0.60) w = 0.05; // نحافظ على قمة الزاوية
        }
        final x = pts[i].$1 * (1.0 - 2.0 * w) + (pts[i - 1].$1 + pts[i + 1].$1) * w;
        final y = pts[i].$2 * (1.0 - 2.0 * w) + (pts[i - 1].$2 + pts[i + 1].$2) * w;
        final r = pts[i].$3 * 0.5 + (pts[i - 1].$3 + pts[i + 1].$3) * 0.25;
        next.add((x, y, r));
      }
      next.add(pts.last);
      pts = next;
    }

    final List<(double, double, double)> out = [pts.first];
    double carry = 0.0;
    for (int i = 1; i < pts.length; i++) {
      final double x0 = pts[i - 1].$1, y0 = pts[i - 1].$2, r0 = pts[i - 1].$3;
      final double x1 = pts[i].$1, y1 = pts[i].$2, r1 = pts[i].$3;
      final double segLen = math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
      if (segLen < 1e-4) continue;
      double d = stepPx - carry;
      while (d <= segLen) {
        final double t = d / segLen;
        out.add((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, r0 + (r1 - r0) * t));
        d += stepPx;
      }
      carry = segLen - (d - stepPx);
    }
    if (out.length < 2 || _dist2(out.last.$1, out.last.$2, pts.last.$1, pts.last.$2) > stepPx * stepPx * 0.25) {
      out.add(pts.last);
    }
    return out;
  }
}

class _RawEdge {
  final List<(double, double, double)> pts;
  final int startNode, endNode;
  final bool startFree, endFree, isLoop;
  _RawEdge(this.pts, this.startNode, this.endNode, this.startFree, this.endFree, this.isLoop);
}

class _SkelColumn {
  final List<(double, double, double)> pts;
  final bool isLoop;
  _SkelColumn(this.pts, this.isLoop);
}

class _TextComp {
  final int id, minX, maxX, minY, maxY, area;
  _TextComp(this.id, this.minX, this.maxX, this.minY, this.maxY, this.area);
  double get centerX => (minX + maxX) * 0.5;
}
// Tarik emb - Pro Smooth Satin v3

// === TARIK_INKSTITCH_FONT_ENGINE_START ===

class EmbFontMeta {
  final String id;
  final String nameAr;
  final String nameEn;
  final bool rtl;
  final double capH;
  final double spaceW;
  final double letterSp;
  final double lineH;
  final double minScale;
  final double maxScale;
  final int glyphCount;
  final String file;

  const EmbFontMeta({
    required this.id,
    required this.nameAr,
    required this.nameEn,
    required this.rtl,
    required this.capH,
    required this.spaceW,
    required this.letterSp,
    required this.lineH,
    required this.minScale,
    required this.maxScale,
    required this.glyphCount,
    required this.file,
  });

  factory EmbFontMeta.fromJson(Map<String, dynamic> m) => EmbFontMeta(
        id: (m['id'] ?? '').toString(),
        nameAr: (m['nameAr'] ?? m['nameEn'] ?? '').toString(),
        nameEn: (m['nameEn'] ?? m['id'] ?? '').toString(),
        rtl: m['rtl'] == true,
        capH: (m['capH'] as num?)?.toDouble() ?? 150.0,
        spaceW: (m['spaceW'] as num?)?.toDouble() ?? 75.0,
        letterSp: (m['letterSp'] as num?)?.toDouble() ?? 16.0,
        lineH: (m['lineH'] as num?)?.toDouble() ?? 220.0,
        minScale: (m['minScale'] as num?)?.toDouble() ?? 0.5,
        maxScale: (m['maxScale'] as num?)?.toDouble() ?? 2.5,
        glyphCount: (m['glyphCount'] as num?)?.toInt() ?? 0,
        file: (m['file'] ?? '').toString(),
      );
}

class InkStitchFontCatalog {
  static List<EmbFontMeta>? _cachedIndex;
  static final Map<String, String> _rawFontCache = {};

  static Future<List<EmbFontMeta>> loadIndex() async {
    if (_cachedIndex != null) return _cachedIndex!;
    final List<EmbFontMeta> merged = [];
    final Set<String> seenIds = {};
    final Set<String> seenCodes = {};

    // 1) الفونطات الأصلية من ويلكم المدمجة مباشرة داخل الكود (A2 + E1..E4) لها الأولوية المطلقة
    for (final f in _EmbeddedWilcomFonts.metas) {
      merged.add(f);
      seenIds.add(f.id);
      seenCodes.add(f.nameEn.trim().toUpperCase());
    }

    // 2) دمج أي فونطات إضافية من assets/emb_fonts/index.json (مثل A1 أو E5) إن وُجدت
    try {
      final raw = await rootBundle.loadString('assets/emb_fonts/index.json');
      final Map<String, dynamic> decoded = jsonDecode(raw);
      final List<dynamic> list = (decoded['fonts'] as List<dynamic>?) ?? const [];
      for (final item in list.whereType<Map<String, dynamic>>()) {
        final f = EmbFontMeta.fromJson(item);
        final code = f.nameEn.trim().toUpperCase();
        if (f.id.isNotEmpty && f.file.isNotEmpty && !seenIds.contains(f.id) && !seenCodes.contains(code)) {
          merged.add(f);
          seenIds.add(f.id);
          if (code.isNotEmpty) seenCodes.add(code);
        }
      }
    } catch (_) {}

    _cachedIndex = merged;
    return _cachedIndex!;
  }

  static Future<String?> loadRawFontJson(EmbFontMeta meta) async {
    if (_rawFontCache.containsKey(meta.id)) {
      return _rawFontCache[meta.id];
    }
    if (meta.file.startsWith('embedded://')) {
      final raw = _EmbeddedWilcomFonts.decodeJson(meta.id);
      if (raw != null && raw.isNotEmpty) {
        _rawFontCache[meta.id] = raw;
        return raw;
      }
    }
    try {
      final raw = await rootBundle.loadString(meta.file);
      _rawFontCache[meta.id] = raw;
      return raw;
    } catch (_) {
      final fallback = _EmbeddedWilcomFonts.decodeJson(meta.id);
      if (fallback != null && fallback.isNotEmpty) {
        _rawFontCache[meta.id] = fallback;
        return fallback;
      }
      return null;
    }
  }
}

/// فونطات ويلكم الأصلية مدمجة مباشرة داخل التطبيق (A2 عربي + E1..E4 إنجليزي)
/// تعمل 100% دائماً بدون الاعتماد على تحميل ملفات assets خارجية
class _EmbeddedWilcomFonts {
  static final List<EmbFontMeta> metas = [
    EmbFontMeta(
      id: 'wilcom_a2',
      nameAr: 'A2',
      nameEn: 'A2',
      rtl: true,
      capH: 323.0,
      spaceW: 165.2,
      letterSp: 27.5,
      lineH: 478.0,
      minScale: 0.45,
      maxScale: 2.5,
      glyphCount: 145,
      file: 'embedded://wilcom_a2',
    ),
    EmbFontMeta(
      id: 'wilcom_e1',
      nameAr: 'E1',
      nameEn: 'E1',
      rtl: false,
      capH: 254.0,
      spaceW: 127.4,
      letterSp: 35.6,
      lineH: 368.3,
      minScale: 0.45,
      maxScale: 2.5,
      glyphCount: 66,
      file: 'embedded://wilcom_e1',
    ),
    EmbFontMeta(
      id: 'wilcom_e2',
      nameAr: 'E2',
      nameEn: 'E2',
      rtl: false,
      capH: 254.0,
      spaceW: 119.6,
      letterSp: 35.6,
      lineH: 368.3,
      minScale: 0.45,
      maxScale: 2.5,
      glyphCount: 66,
      file: 'embedded://wilcom_e2',
    ),
    EmbFontMeta(
      id: 'wilcom_e3',
      nameAr: 'E3',
      nameEn: 'E3',
      rtl: false,
      capH: 255.0,
      spaceW: 115.7,
      letterSp: 35.7,
      lineH: 369.8,
      minScale: 0.45,
      maxScale: 2.5,
      glyphCount: 66,
      file: 'embedded://wilcom_e3',
    ),
    EmbFontMeta(
      id: 'wilcom_e4',
      nameAr: 'E4',
      nameEn: 'E4',
      rtl: false,
      capH: 256.0,
      spaceW: 133.2,
      letterSp: 35.8,
      lineH: 371.2,
      minScale: 0.45,
      maxScale: 2.5,
      glyphCount: 66,
      file: 'embedded://wilcom_e4',
    ),
  ];

  static String? decodeJson(String id) {
    final String? b64 = _rawB64(id);
    if (b64 == null) return null;
    try {
      final compressed = base64Decode(b64);
      final raw = zlib.decode(compressed);
      return utf8.decode(raw);
    } catch (_) {
      return null;
    }
  }

  static String? _rawB64(String id) {
    switch (id) {
      case 'wilcom_a2': return _wilcom_a2;
      case 'wilcom_e1': return _wilcom_e1;
      case 'wilcom_e2': return _wilcom_e2;
      case 'wilcom_e3': return _wilcom_e3;
      case 'wilcom_e4': return _wilcom_e4;
      default:
        return null;
    }
  }

  static const String _wilcom_a2 =
    'eNrsvcmuLUmWHfYvb3xewvomZxwI0IyDGnBAEEIoGRBDyMoqZCVJCQUO1H6IBEGCGqpvv4T6G/pejZ/j55774r6IF6miEMiM527b'
    '7LrtY25utvey3fztpx/+8afffvrnP/z+d3/1l//Od+XT7dMfvvvL7//eHw/i33Pp3/qDS3/80+8//fZPf/yn398+fffH7/7dH37n'
    '0h+++9MP/+z7v/jTD3/63T8x7d//qx/+8Pf/2fd//P13f/3pt3n8Jt0+/e67v/63P/22lhqFv/nr7373/T+Iqv6bcvv0++//9Kfv'
    '//gXR9syf9OP8g9/+P5o3OaKxn/5wx/+4nff/f77T79Nv2lH7V9+9x+oXKLxv/f7//Cv/8nffPrt3376V//1b374m7/6fdz+8+Ov'
    '1+3T0eYf/u2nPx2/4R8fP+F4/j88qOlW2u1zx79VhYbL3LjkVHkti9deeJ0T15Iyr2Xw2vmUMvmYsvmc48fejv6Oa3SKC4uVRdXm'
    'jeJxYbGx2FhMrE2qTaxNrI2eEi8sNhZVu1i7VLtYu1Q7WTtVO1k7VTtYO1Q7WDtU21nbVdtZ21XbWNtU21jbVFtZW1VbO4tdxcRi'
    'YrGwtqi2sLaoNrM2qzazNqs2sTapNrE2sTZv1MaFxcSiahdrl2oXa5dqJ2unaidrp2oHa4dqR2Yxs9gHiseFRdZ21TbWNtU21jbV'
    'VtZW1VbWVtUW1hbVFtYW1WbWZtVm1mbVJtYm1SbWJtZuVG7WbVRt1izULNYs1CzWTNRM1syCQkFhzCgc/6KAmsGajprOmo6azpqG'
    'msYaDorGhEOiEeGAaDw4HBoNDobHgj/Wv5U/lZ2izxtWieN//+hf/KN/cfv0r/7Lx3XleK2v1pV+cHRrJV7HrdaYwbgcLMdlZlyO'
    'IYxLPuYvrkd7XI9n4rrYOmYwn8H6+LBwnarfx8N3/NB6650ryzFqxyjw7+oxnnnpGgNydH/89OPKBawes/x49HHdYLkd38QxPXmN'
    '5x0rRlxbLqCjnFk+5i3KcUW5qFxYxmuIFWeqrOc11+t5VfVV7avqgx78lR3lfK+PV57WrUb/8fvL09+/83cF/Ry/F7/7WMjxewef'
    'c4x3jFNLheOx1i0Hv3ux/bFU5sL+ylI5sR3G+VgP4jWswuq5UJx8y/VYHjz6nS8DJa7gx57RWeosbZY2S7myiGuUl8qL5fgZUcY1'
    'ykPlwXLNLOMaZXVW1VtVd1X9NfXX1F9Tf039dfXX1R+mW5Qny5gmxy8cev5QfyM/1D+0j+lRj7kYr6seq3uO+oN5DPvxztDuGNT1'
    'MLuP5osXFhOLYuZ4cYsXFjOLmcXjjS9eWCwsFhTLnrfFC4uVxcriAhtxYbHdtJuymFgkG2WCjbiwmFkkG2WAjbiwWFgUG51sdLHR'
    'yUYXG41sNLHRyEYTG41sNLFRyUYVG5VsVLFRyEYRG4VsFLGRyUYWG5lsZLGRyEYSG4lsJLGRyEYiG7G7aq9lMbNINvICG3FhsbBI'
    'NkLaWrywWFkkG3mAjbiw2FhsKiYWxUYnG11sdLLRxUYjG01sNLLRxEYlG1VsVLJRxQanaNYUzZyiWVM0c4pmTdHMKZo1RTOnaNYU'
    'zZyiWVM0c4pmTVHOUE1Qzk9NT85OTU7OTU1NzkxNTM5LTUvOSk1KzklNSc5ITUjOR01HzkZNRs5FTUXORE1EzkNNQ87C6k+SX6Sm'
    'Pme+JiDnn6YBZ4GGm6PNn41fzV7QyQ0Cwzr36f/qA/t0xd+FBB4iV8H/W6z+x0Z17NkdS+6Mp65YryHaHSPd4q7dMPKoPe7Y8Pg3'
    '7vPtmJnx5ZRYU49/YwpiPTxqj3+PlgNPGnjosX3G+xu4L7gv6GKit4l7PLmhl4oeKzqv4KOCpYpnVjyz4JkFzzy2+7jP4BDPzPOB'
    'W3IOnmPYV/xVh/BwDAaH4Zi0h4x2bGATksyIve3455jpx1Q5brFlDmyIx884luyBJ3ZIOnF/bB4jODtqj7d57PucBwV7dnw/+cYF'
    '/ygeX+axExzEY1s+BqLiB8d9jl4qxIKjTfzbnikVQsVx30CPedhjBCuEkfjm8ZCONgczFULM0Wyg5cADY6Xo8S9rz5aU60L4oAhS'
    'MdjxTcRlgVV8s7jWxGvnn+TJPyqJf1UK/6wER4m7BB6a+HfY2iTPDW18neTxWJtYTCwey8nQxte54w1tfJ073tDG17njDW18nTve'
    '0MbXueMNbXydO97Qxte54w1tfJ073tDG1/lbhja+zh1vaOPr3PGGNr7OHW9o4+vc8YY2vs4db2jj69zxhja+zh1vaOPr3PGGNr7O'
    'HW9o4+vc8YY2vs4db2jj69zxhja+zh1vaOPr3PGGNr7OHW9o4+vc8YY2vs4db2jj69zxhja+zh1vaOPr3PGGNr7OHW9o4+vc8YY2'
    'vs4db2jj69zxhja+zh1vaOPr3PGGNr7OHW9o4+vc8YY2vs4db2jj69zxhja+zh1vaOPr3PGGNr7OHW9o4+vc8YY2vs4db2jj69zx'
    'hja+zh1vaOPr/HqGNr7OHW9o4+vY8gY3vo4tb3Dj69jyBje+ji1vcOPr2PIGN76OLW9w4+vY8gY3vo4tb3Dj69jyBje+js97cOPr'
    '2PIGN76OLW9w4+vY8gY3vo4tb3DjgwiMz8yfJL9ITX3OfE1Azj9NA84CDTdHmz8bv5q9oJO4je688f0XjxtfPvTsFzvfxl/vyk2V'
    'GuqihrqooS5qqEsa6pKGuqShLmmoSxrqkoa6pKEuaahLGupO1FBz0pKWqczsWwBsh7bAP6kHuwPXHYsylCpqLyP2oKPdlBYkxanE'
    'BvW5HnxDF5FKG7sXVZCC8cf4xd9SI6IgEnowBJJFvW52KiCxXXWyUKXIZCh2Vfo0gb26pDcO/V3ogdCzpbgEepTZLRSrQEnw94s/'
    '7dA/ofhEebPc8RN3iCQsN5VdP1gejc8DPdaAxf5GYXlW6en62XNRv52J/K5C/qeHflCfnZO/F28rJHDwf0gPehWr853txfFZm4Me'
    '3ycAhV05vvH94qXtyZeVk3RMNj3eW87FFLyUfMsc9pCfpCjmPMlAbklvArPjGIKY2HxXBCWONmPqbfZFdtk4RA4M5IyqLQa7IBBW'
    'HQOe8TJmNNbMynhNobgDt+hmI3huyar5FM9Qpo8XmanuByWLgulx8Jsx/UAZppxtiijZbajll/tobOm9U2rykJq8pCbnJD0ZPzK+'
    'saS/IKGZkERIIsRSvHkVQVPruJIQy/HmVYQiQiEBUsPmVYQqQhVhkbG4itBEaCYkEcQY5IfNqwhZBDEGGWLzKkIRwYx1MdbNWBdj'
    '3Yw1MdbMWBNjzYw1MdbMWBVj1YxVMVbNWBFjxYwVMVbMWBZj2YxlMZbNWBJjyYwlMZbMWBJjSYxBxti8ipBFEGOQMzavIhQRxBhk'
    'jc2rCFUEMQZ5Y/MqQhOhmZBEMGNdjHUz1sVYN2NNjDUz1sRYM2NVjFUzVsVYNWOa/NmTP2vyZ0/+rMmfPfmzJn/25M+a/NmTP2vy'
    'Z0/+rMmfPfk19z31NfM98TXvPe016z3pNec95TXjPeE13z3dNds92TXXPdU10z3RNc89zTXLPck1xz3FNcM9wTW/67kgaD3wR6Zv'
    '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'
    'qH6ongr+5rXCcQ5lXKMsfqf4XeJniZ8lfpf43eJni58tfrf62+Jni5/44j97JRRlmaI+cTINSs6mTFPUL/BAUEoyZZiivrN91+It'
    'iyL2ci2mbFP8Vw0cLuJ1mCkEv5caA1WrorRiisyP+eeYX8UUP2egjcz0sRFhGoFSTBmmdFEwK2Pdt7/SnYJ5WrjxidIZOQO4Vjz+'
    'gQLcZj9QAP8a5SOl00fmgYK/KhQagxJRY4D2PFAaTVpECS14MNzMAwXYzn6k2GL6pPB1P7Q5v9G3VTiOy5Zmc5F+znHuwrdBKf45'
    'sajlRl2ATwYE13gjSjVFRgbYvnKnbiDKMOVsk0mJXWoIGcr082K5shwbdZSXnhmb89DRcKbDF8uF5Sl7kJVUFuNTfz/E9lR/QwwF'
    'Mpnp/8Wy+u+u1/NDltKRMsuF5QD+6NGisn5xlatKIFG50Yx60JqbZU3ykTSKjWXItQIm5iN6YpwCk0oA9ANcYthi7Ytl3eKjusCF'
    'uS4ohvCRti/4iO3uhkANIyDzgnF0/a1wiibIQ48i0nQ/AiVXgpZybRdAhEhT1lFzJtJ0t9kjG0U853W12Yt3yXWwy2RHBuv2Rxpc'
    'QLt8kIiLwF6+otRUSnCWYwCaDV/zRZAhRrhiWQ+9JDZVrPnHL44ds2BDaIRTvAdLBf0fripoeqmCYrYN2sUMwf5A2cNAXSopRGtu'
    'JBSWtRzIyhpvIV4yV//eubnE5lvklZG+cvNVvRf/qvqq+qb6pvqm+qb6rvqu+q76rvqhPWlo2xrakYY2ran6qfqp+jk+uNmqfqt+'
    'q353b6XeFJM3xeRNMblNPtt4S87eFLO3wOKNM7tN6T9lc21ugypspd1bqcUwSjSxlWZTujfOc0HPpoxH4W0SS/hZW2n+wFb60zbO'
    '7Y2ze5ssP2nj/PFtUnthe38vLO/vhen9vVC7BFTcp73QbVI35WyjvWSrydbesbX3bO2VS3vT0t61VL+0V03Xq/0sT3uf967HvW8+'
    '7H3am869T3vX1PMg50+esmT6PbOs51XtXUPPi9mCsp5X8sf3unnd69J1r+Oe09flLMAQPbFrTGpsbtr60uvNrX5xcyvXzW1c8PzG'
    'HbhqC6qq1R5bVSueC5+sc5OQtT6wm+U72j+0bTWK/4NLF4qIabiH9i9oqtDlCnSIY/+a3L8G9i9i62/2Lyo2ERAHujrDuog0FaOF'
    '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'
    'C4M2JJxctHc+3uuGM+jgO99w6QzJLsN9NOY7T3gXrJg7ZaoFEKcpLD0OphF1CMfXoWbDz/RY0Ab9FBBOf+AT2vAZCuMRuAsNzvPl'
    'SPTw/mQkeuCHjkQfsrXzR8bZPmLkJ55eIxL9hk9CDZuQMEeZD5HomwLGd/QZZjEdFtaRIutG5OYSiT6i6ITmc2OQ+phVsQjBjYKR'
    '6Dsj0acbA8wHItHpZBFAA9CMG+yEYAYG8EIYB7EUwTAoCAwBdlEIVxTAJoVwBcIEImccU8UxbWTjQs0I9LA5w6MbARP4xQeyjQLg'
    'HTp3xEV5z+l6T4ew0rTN8HRR0ayKAlARu6pX7Grxp6z0DbAr1vbxGrsipNQEKTVCSk1jWAkpVY1iZW1VbSGyVTT6hUwWMVnIZBGT'
    'mWxksZHJZBaTiWwksZHIZCKTG1xsMrHBwyYLCxwsMrDQ/2L3HECNH0zo499GBYZefA9olaCrwhcmgOo/uaSLPIbkBUDVdDDTqrPD'
    'b4FfCy+b+Q5jStJ6tSrR1bHkMWUVDm1knl0BFMQxD3ONRigGURRu1mBC3BSDCckax1JUOErvvUrUh6IxleqAGNTUTU02VpeBYPQj'
    'I/Mhm/m4KU03cNOKm5l0AwfsqeTuuIHDVtyMopulJ7ekJ7eafTMYpQs3YX3BKlCyKMVtitsUtyluk90mu012m+w2yW2S2yS3SWqD'
    'RJVBwQ0p2RS3WW6z3Ga5zXKb6TbTbabbTLcZbjPcZrjNcJvuNt1tutt0t8FLwTHcNKWYUkSpblPdprpNdZviNsVtitsUt8luk90m'
    'u012m+Q2yW2S2yS1wZl66TpcJ6WY4jbLbZbbLLdZbjPdZrrNdJvpNsNthtsMtxlu092mu013m+42HuficS4e5+JxLh7n4nEuHufi'
    'cS4e5+JxJkx6ntmBkkTxOBePfPF8JgDbZUdCiuYGVGlQGM9M2aNI6aLgxDMJTivn2VwSoEZKNsV/NZop7ssjlv2+AKGQUk1JojCc'
    'YaG7wZ0CwBN5q7IpcklA5EBS9Fdco7ZC9THT7TJlmOLnwCbRiDcpSZTmvwK6kpnlVxT3bhgVgd9AKQIOS3bvUUWKnwMDUgWrEyWL'
    'ktwmuU0yh0ltLMh/DjxeFIdA2WcbA8LLCEwIqgAoVjKlOAvA6aWyFa4A5wiGj4BdDx3D0qp0PUaaR5Yo57Bh9sPtsKRTzwHFkQCm'
    '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'
    'MeVFhuN0DfcU5duiPChUiUmu48XPoWxRt44RSL6SGZITE1K5k+WF3imteBnGkkY4SseRETcUHSrwXTgf+XwOM2WDbo/ALSCiDtW0'
    'rxvl8lT6NXeaJMSQdDycHz1Eka5jabECj66zXnUXFO306R3qvPCTq4jf8Q6FX7o4ebk4nZn6nM7r2gsEXr1FOyjUcR2+VSKZIdeH'
    'dpLTwfrUTpI/MVy/C7/009RjPIi1tTjOxsrZ0DYbiWr9nW4L8uACfZJXifxJimftLfLMP7aDaZOAejvHDVfbhvWFZDfI7szcrs7t'
    'fiFxZ4O3PD/h/voJ99dPuL9+wv31E+6vn3B//YT76yfcXz/h/voJ99dPuL9+wv31E+6vn3B//YT76yfcXz/h/vqK++sL7q8vuL++'
    '4P4q3B8vuD9+EveXb3B/Eu4P4v6yXnD/FO7P3+D+Ktwfwv35D+L+8Q3unz/E/eOJ+/MPcX/6Ie6XVyB9ifuBynv+EveXO+6H9y3k'
    'QX3F/ekL3C9UjtX9K+53MnD8APdzrVG+xP3wCaT6Je4H7ljtS9wP3DH78SX/btyf1yvut6vwwv15veJ+9txxf16vuD+vV9xvb+SF'
    '+/N6xf0ng+Lg/rxecT/dm3fcb4fnhfvZc8f9jHXccX9er7g/r1fcb5/qhfvzeuL+vJ64P68n7s/rD+L+JNw//8y4vwj3xxP3j/WC'
    '+8s3uL/8JO4vvxP39xfcn3+M+9OXuD8/cX/+KdxfvsT9hgL1B7j/mcfxxP39C9xvSaHxBe6XTyDNb3E/QkeLv9OV0/GTqH9/7Jg/'
    'Rv0nvwO0V6I2/wuh/rqeqL+uJ+qv64n663qi/rqeqL+uJ+qv64n663qi/rqeqL+uJ+qv64n663qi/rqeqL+uJ+qv64n663qi/roe'
    'qL+uO+qv647667qj/rruqL+uO+qvrPtBDcN3qJ/JVkD236F+OgZW+b2ov32P+utxOP0k6p931B+fUX/6FvVXh+o+of52C9Z9gfpf'
    'gnXzBfWnF9T/vz9Q/8cZ/ipY13hOuJzL3O7lIeVFFuMvWLjSVT25YsNr7bzfkBgBB7eyEbOvUuUV+rEVKtnETrLfynR/qgcfCtCd'
    'mvclUfvM7VpPcpKlO7NpQbDWk5pkrSczyVpPYpK1nrwkaz1pSdZ6spKs9SQlWaIzbGIYX+tJSeLv15RZudaTkGStJx8J2zpe1vFu'
    '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'
    'NBk78PO5/hM7+wNDmivc6cl6z8UK0EUi09v4PKwSXfQFrdSi30u01zgJSZLSOJc7Cr7o/JzKdsV2e1sbTcE2U9l8G8JTzwVOiNk4'
    'lFcY4qxlpWq1DVVWPW04VmHy1OI4e3Vbmte7XvgOr3e9Jv61Sv61Sv61Sv61Sv61Sv61Sv61Sv61Sv6NVfJ/+qiJ+7gAviTyrFgl'
    'F+fu1aTaOGpHMrt650DDJbqTgBl8ruScgviOhTnCShl6Uk0ttnH9neVNZgI3Sx2qgjh7h2n/+Y0lApMLlo/7aGiJSvoX0b00/mT7'
    '2AihYQf5ekNvEuyMoh2I6EGNWJNZm7d3uiZLHU15zNipmswM573DFMGlHSdzowc76PGc7jnNc5rnNM9pnlM9p3pO9ZzqOQiQOw2a'
    'Pdk9qjZDzjx6wnPCc8Jzsudkz8mekz0neU7ynOQ5SXNiaQ530JPd4znTc6bnTM+ZnjM8Z3jO8JzhOd1zuud0z+me0zyneU7zHFfj'
    'IXc6nEvNHs+pnuPzHD7P4fMcPs/h8xw+z+HzHD7PrHisroFET7gn1JM8J3lO8pykObx6nVrNHistLs+ZnjM951Jj9JzhOcNzhucM'
    'z+me0z2ne073nOY5zXOa5zTPqZ5TPQepG+g5c3SFZ59nhg+cY82eKtQICI4e8xr5rDJCgZ7sHmPN1NyjLJP9lkBHVt2jr1S8dQAJ'
    'faCsPzlnK+k4vvmJ9Rr1jcL0RCimLPeOXU1ZSFKljqIOk0JJkfbigCr6E5MPocIyTPkET0NSh7IIUHNpIVh2NHY4eWivF9lx/kSf'
    'ASYhIOGhjuSOyo7sB22iig6CRuzQjHRm8EMzThCKMBvpr0HXhA4yYZOuaU/9uGbZEe4oBFkIzRfJyjjBgh0MuAM2KasCMKytw09s'
    'GLbEUwyEsGFaZeVmV6EQ/n637/zCXckRrrjcRGNTtYJC71xRm2Jp499iViaACdVW7vUgEz9MHrR7mKhTnArSnEBStIOepZ6jR8+k'
    'oGJxnuZkleJkleaElqId9HhO8ZzqOdVzqudYn4oMQcNUQUBfntOM0LrndCO07jndCG14zvCc4TnDc6bR4PScaTQ4PWd5zvKc5TnO'
    'TkGJ+u4JI+Ew7uVOGH0NsWmzx3OMe7GuR0+UO0Yahj3h4r/hbK5w8R96PKd6Dkp10OM5ZKMuFJJET/Mco9xonmOUG91zuhPGuucM'
    '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'
    '5p23vjE5jHn02OnyvCGbrXiJXsysX0zzVbwOK8n0rKb5CjPZh7ntw1Rg2TRf5M7qqm0Gig0v/ofz+ofsSeba563Ep8/+WtjuJ3l9'
    'nhKfItyCH/OmahmGSLWG1IaHSLWGqiG6SkLIxd+0/C3cdi3TUyhPaWgLjxKW86GMqxD6wTYjsQx2Y7vL8nSmi069z7NPfFXFdZWI'
    'cRWD11m+iwCXFQ/5aY/t23brjTnHnYVpiC19tIsIvs07l/v+qtOrWYkPtOnVbNdqdno127WanV7Ndq1mp1ezElpu06tZxYzadFWD'
    'ktva9GpWKeltWna534jeTylzJHUkdWSZnm16lmHZhiWZnmx6kmFJhi3atWTWolVLRk3aNGXSpEX/L3vvlSQ50nWJbaia5loshy80'
    '4wv3QDU04zJIozCOoBg9K/lnN8x7BAJARHZlVVd3V/eXD1WAOyLDTwAO9yvPXQK0eKOW7tMkmikwk1j8JAaRmFN/EMcQjE4YXTA6'
    'YdhaogppOhwqpvjjTBEgiuTTqgUN9cUutLB/LNsjsJhOkxBh/1BwYkbmIaKq0Xpk2O1Lht2+8JtvBHabwmdfKHzIxGAKn32h8NmI'
    'MFecOfZAjF40esFCr9qB53y7fcm32zBHiZeh8cml4z7GNk9j8dP+GEPv+rw/xrAqFXjZH4/cu9v+GMOpPOCDwue2Px4UPrf98aDw'
    'ue2PRx7ebX+EE+swMqWTjSmdTEzpYWFKh4EpHerAdX/855f9cb/eH5dmHHnIRarRTWdB1b7TQCQT8UCrsVrdoHY+adTZPMQDwzHI'
    '5s5RMmHc1Ro2HOTpOutKS5sOXt1OggOLzhD9ODY6W6cgsjazTtZujsli1slF9gFsmDiJ5aRr2+BJoguClJA4QeHjfGdTr+ZXr67v'
    'cuMzL+Y8N6MIeuqZaD0d3OnD3OnNv6vqJNY3nmzbRjJnOdyQiA52+YsTT3uyZS6dv6d4rMAzTWyyTZA5VU46yuryM0Mn4YUXMJ3U'
    'bDxDRhsmU3bv9uEyOlIBR3LipayAnSFd9ZhSDFuO9lI4cxzj8wxXzjjGN3JGNBwj+R7HDFcdsjOHMj4H+hPnaliLKvM7afVbj78X'
    'ZBMJ4Q2ok1bIt++18ZPcnjp2We2SjoPBcyXJ+jf0jmj7RrizrGrMc186DoVTR+AlrYaUSAuPGV4d3B8cM60LMR6nIlyLGM+TtTtL'
    '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'
    'IQM+8r4rU0aQ0RwCFkVJUEllucS68lJ5Ep6Vbum5K7JEf151Eo5FnoixCXIn9rKiLLVSjwIrhziuZYPiOAa1FP4Qx625Qxxfcg0+'
    'hO+iH3gI3+UQtbM8aw9x3GJrtc+xpYs4PrWKyl7Hbz5+YPdYSBhFJJ5CoVnuNfxrCMqPm9COIeCJ7fQ3Q56G4xmye5PM3VUgiDc8'
    '4rng1zfRPXrgyQ7v47DsDu9BsaAfPXGCz9C6mniC76F8n3nCHvtZF5R9FUoAsI1f0bUPhids41KSxB8vyVbOE05w6x7f46nFzN6t'
    'TTCm1vTcmOIB5meyPwydZFonERewNBCrIkNVLamTDGsXVw1kWgPJ1kAW2XXwmezPUAOp1kCGNZBuDcQqRLJ2AZ0Eb1zVSVcNS+gk'
    '1eWUa7FOsli49vZX8cI+dJJunWQ96STrSSdZTzrJetJJ1pNOsp50kvWkk6wnnWQ96STrSSdZTzrJetJJ1pNOsp50kvWkk6wnnWQ9'
    '6STrSSdZN51k3XSSddNJ1k0nWTedZN10knXTSdZNJ1k3nWTddJIlnaTddJJ100n2V3QSah1tvNZJqHXU+VonodYhX+mTTkKtI++X'
    'Okmm1pGTlBDCkCQNBtLCA5QQivuS+Qqd0EVOaBCPFh5eWfMp7s/90ppPJ3SRE/rJmk9xX07oJ52EMJTk/KSTEEarr3USwqjttU5C'
    'GKW/1kkIIwtGJowsGIkwkmAkwkj1tU5COXu31zoJxf0lcZ8SNQ5QQijuS47m/sHDK2s+xf1RX+skhNHba52kX9z5nKIPd/64uPM5'
    'RR/u/Js1X979+tqaTxiaotZJNEUz1easKUpxhD7/J6Ukv2vOZ3g4fwl2ry+6nVJK5jk8vL7Ikh6vs6QZBIg0Aygl+WLOH1RK5lkp'
    'GUzcBzPmw5xfqZTQAII3mILvyZzPkrMMuzvnTB9KyTwrJZ0p3OmslJA1sagGkwJvWLWISdZHEu1XUmwfSsm+KiX7qpTsq1Kyr0rJ'
    'viol+6qU7KtS8irj9qGU7KtSsq9Kyb4qJfuqlOyrUrLPSsk+KyVPCbiHUrLPSskmucOzUoIEXNv0Xygl/+KslMQC9qpuWZUXOdur'
    'jIRPtpFuL/quTboIHIP6divfmIWejorkEOuK6lZ1KZGsngT2BpeZLzzOy6PcnMUkPFClcBfdds1tF722+OPy0WqbilQVuV0y3BXD'
    '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'
    'wzqYmQysZOF4PWRoIRoEFBaVvLrAHYI6xI54EUSGnn+AZhHQdKE6VSWrnRANEAsJC2b7FDXmC/HiZONhldw8F1rJyQKUYCmSGZ1s'
    'cZh85uXkOqiraGTrqwVwAEhnEgHQ0ibuDFhh5rtT7MrbR6URwTSKq6eMRTrxBqO3NphhBmGxBTw4WMT562feQC7zay1gi8GfeeHY'
    'y+teAaMvMgtU3FULke4wwnjnTJxQE7Blg49wsvIovv/EH1UwF9GmragsOUg71FRLcoJyfeHu/xpCyCaJO8E5kDySX/+Q2k0SmpyV'
    '1SCywgNZJhO6/SDDZF7TDyY054P6wTQJbJdiqykvthoyKYqiBmwLCELG1koKH5J9HpN9HpB9lovrU6m4iGoU1ScsXlN9Ii6cDcQ0'
    'crFPrPZJIT5ZopCcQZ+dlSEZ5dGZu3vF6JDwM1i2lxHTwYBphksHo6UZKx0MlWagtDJFSLjxivhyVCUWJV+Qkra2UpaxKG+cT1iB'
    'aTvfQjmVAI1FDxc9SpV25jQTqct6RpLWR5ypyVHrfISdNgaWOlSVxS6rYtsYoEh4QX4+UaywuR+Z4k4c34+0cmeZO+l8PVLSdeFo'
    'uJIAb9zz2J3WLjPkf3uaIeVnuqInIybuQMUiNsRstVF/ZMwncUh7Jyj6rnPhsjTFbb7rXFhdcZutXmz6aG3qXOuuc1XpXFU6V4fO'
    'NaVzTehc9alzTelc9alzdTandC5izSzFpqAAhs/i+GAt5yICFlghN52rP3WuQZ2rSedaHy6qzojC1lXzA4cjdC6WnK71TecSwiKi'
    '1Nqte0nrgVVcRUMqqq83nUtajwjCzh3NsMk94oF77B90rnVHT4ylCFmZd9TFGMwu33WuC7s5P+hc+4YAGQ8yOrTuyJFxJKFKz1tF'
    'l7OZnQ861/gg3yR0rkWdqz90rqDOValzDepc/UP2H3SuoM5F6vE+HjqXwmOW63XfdS7GSOzl6t3QuSZ1rk6daz50rkGdqzx0rv2T'
    'ztWoc1E52ZU6V/lJ59rUuRTv8vVLQeeq0rmCOpeAgq+hxbKF1LkKdS4xlk9y6aTmAJ1rUudqH4482/y21LkadS7BDrNQ55KXbKyn'
    'zkXP1jzSuRp1rpDOhVRNJiDddK6QzkWS8TiXvw5KVkjnWh+u4f2TzlWeOhfVqMuPSIqaVl5OR2YJPnQujVZOLuOpc0nXK1OuUOpc'
    '3TWyg7kn33Suete55l3nqvYDps5F0vY97joX4iOQw/auc4ENR+HDCxqyQkakc/FnXsAYVI59AhIUgU8S+b50Lt45465zgSVJvEdw'
    'dw/qhfObzjU/aARvgN5ZEh0qF5Sp9aPKhWyiQU3qg+TemYJtLSwNLREEFoYOU+XCN4n9Urn2S+XaL5Vrv1Su/VK59qVyvfGrF9b8'
    'ocq1XyrXvqlc+65y7bvKte8q176rXPuucu2bytXIidno+UMpH9bDRoJrmMJNWsJ+stzsm9Kg0RvLzX6y3Owny81+stzslyrTNWpF'
    'R2WqpQY1RRJbSVKZaqtQ5Yoztr61b+qXamlLOSsS0qobhaRedyiEND4KSF1wUwBpiRRO+iMXFx0Al5bOyYWpjU4uKz1VFcm31dl9'
    '6baqYn6sAu9LH+ai0pRV1uhf/uNDLVvlt7JGgMrCmR5V6LBY+g9vrty3yXHWiGAJuppkeUT0rKDfSQ/CFcxSCQsfungWQyQGonW+'
    '9ivUT/xACbh8MOAF/RBU3cnhmi9ZjC9w3bs8bHjtzj9TlHc6psSeyHzYSZLWQo9cnk1NkW1NkW1dkW2hwLapuLap4LOpqLapoLap'
    'mLahkLahiLah0LSheLZQCFkoVC30eaHQs9D8rvGuULTe723xCo14jSuUrSuU7Tm/ff87ydEUytYVytYUytYVyla36zwzRK0qlK0r'
    'lK0qlK0plK0qlK0rlK0qlK0plK0qlK0rlM3XX5FsCmRTHJvCyhxVpqAyxXk5pMwRZQ4oUzxZc6UkRYE5dMyxZF2BY12RZF2Lda3W'
    'tVzXeqH1QuuF1ot9y1GvSznqZA9GW3FpUyGVU+tPyTPrbfw235tm1546tKfK0hoaPrfRwYszlpocHRrFEYKXoT1VduDQnior0ewE'
    'siGH9lRZmEN7quzPoT1V1unQnirbdWhPlWU7tKfK7h3aU2UVD+6ptJgH91Ta0oN7Kq3swT2V9vfgnkrLfHBPpc0+uKfSmh/cU2nn'
    'D+6pRAAG91RiA4N7KlGDwT2VeMLgnkqkoTOjjT9MvmAv6nj2BsLTF35WsgXCJ1YYQQbFDjFYTJqCJVebKBsbSB/hj+EO6v0URApI'
    '6xc/eCdMjI25aaOWG48b93ffxqLOIUsXZ3OTC/Vf3+9xVewI1aDosK8WkfHlmhOypQ8MwSNTen/wKYBJ3mkU1CJLeuiSisS0yyOm'
    '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'
    '7fh4cWX/asdfrAB/YMfnZyomBiwMImH40Y5vcZnz82aH/4eHHd5/LvttSm4pDTgY2xSmo5+26ddDFNJ+UAuqUua8fAWBqrdwKTS6'
    'GRoDsxoPWLyGSrJo1isMbovMQ3GPk/PySIMBVKkT9SpDsG61Q22Nl8M266PCYGF7qF3VrtSxjuIQz1S7qd3Yzu1hy3BZNFjY7mwv'
    'ygPDZdFgYVs63Cpq8/5Jg4UlvIfaVW3JMyTPkDxD8gzJE5InJE9InpA8rGpMw2UpflNxnGxLni55rjhLydMkT5M8VfJUyVMlT5U8'
    'RfIUyVMkT6E8oF7YMlwUptgU/sh2UVvsyFu1j/ZQu6pNeZCbtGW4uE75luGyaLCgPcUYNLvakmdIniF5huQZkmdIniF5QvKE5AnJ'
    'E5KnS54uebrk6ZKnSZ4meZrkaZKnSp4qeXQ/V93PabCYxgntwt8DhsuiwcI25TkU51Aa3cy6lzdF2ZREN7Lu40UxFqXQTax7WLew'
    '7uBJAfIFeA3hotdGkA9tgjMsKIxsD4SPkF9ws3pBIjPJEIS3m+PkomXqLhuVVBEfDK1lOiypKnN4ght28uMmPjqVnQIEZSPvAg1E'
    'rwS5bgMp18HPDywmKr0OKTolYg3Kzo/u+OjGj26Ma+JHMzCmikZ33UXn98AXIBkn47tjKl13IJSFtbmDeb44NQIW4MSpEfC9TqC/'
    'jMufODWCf4Kom0CBkol0l4jHdWcJ54raD53khwjRAioNLsiOiC5yaJFiNLmi8Cng1lUIDOjb0k1MTr6GfGHmgjVc0g7JMnsCqf0T'
    'xwEDwme3ZOsm5WQtZp4g8hhv6TTWbVq5EdsOpRSSTOJTxM88vXQK0lv93eR9izFFLqdO1Aado/X6Y4wpTOXWfuTWgCFbHajIsEWt'
    'AJ2jSedo8B60Un6scAKN59R/XoWTLbdKms4weadM3mmTd9rknTZ5p01e86YyHEiJp206QGhvp6JKwaXJ22zyFpu87T6niIWEJm+x'
    'ydts8habvM0mb7HJ22zyFpu8zSZvscnbbPIWm7zNJm+xydts8habvM0mb7HJ22zyFpu8zSZvscnbbPIWm7zNJm+xydts8habvM0m'
    'b7HJ22zyFpu8zo9gjyXslrBZwmYJmyVslrBawmoJzftCk7fY5G02eYtN3maTt9jkbTZ5i03eZpO32ORtNnmLTd5mk7fY5G02eYtN'
    '3maTt9jkbTZ5i03eZpO32ORtNnmLTd5mk7fY5G02eYtN3maTt9jkbTZ5i03eZpO32ORtNnmLTd5mk7fY5G02eYtN3maTt9jkbTZ5'
    'i03eZpO32ORtNnmLTd5mk7fY5G02eYtM3iaTt8jkbTJ5i0zeJpO3yORtMnmLTN4mk7fI5K00eYvKvk0CmGhPOXCX4rKn4n0m2b5o'
    '8jLxjO0uG3NfGCDbg9t2kM6JJm/I2uwyeatMXpmdLji1mkzeTpNXCRiE6vT9RPlKk3fQ5AVWKyu2EjidxFFjKl+cH9Z1ERgnTBt3'
    '0uSVjQtmSMb2DMX4VPmqjypNyOF9zCvUh1r94tE7V30cmcPAWF/1cc6jPg629aotn+5qgwhyV2vLR0mtqpJaJxc/vPKop6VyWr9W'
    'ywFjHg8yFA1b/FScMWbSmzcmvXZj0ls3Jr1+q5xzXCEHnkoyV+Z7ZKQWV25i+lhsEueJLwBJpk2HLuHpG2fd/yH7Nn6srgT20i7+'
    'zUbvZ2YUgYC10PJW8uV55X1mTszmC3wSB0yWDEChJb7p2ESzgu2Sjgza40zhZ7Ox2dgEg1VVUTp6HakvornR2mxIBorAMomsGakv'
    '/n/6i/9o15v2AwEQek2zQNhV8PkCXMzcXHw4+TiQNkp2E2a1ilOEebji7GDGHT3wGHFV2PkXWFg4EiybxRGkpuRjBK4V+G2V8Yjg'
    'uqs0HevUDZe0LnT3H1ewWxxhobsn8cq4Vco7HIF34fOo1h6TfcuPhfj4cL3K9NXyKOJXx9/PtaLRzlGR05Cw88Uby0zdi2Z2cHRo'
    'dHB0anRydGqUZf3yUA1Fcen4DYV54XzW6Fb2t0aZlozcQnkdVb435JQsNPVDPsvC4rhsMndcTD7UmaGPhALgpLmEIuRUmZZNjiL5'
    'RqBGsP4vXlXksEFnxgubTFD36OLoMkeQ0tc1yoTpJjKfxpTpJr4aZrThhU2KJ4Ig5rThJeQ8Lnxhqq6E12jv/i73r3Z9Qz3T/5ee'
    '6TyZftrNENzZWYyNhZZDMBLfgJmiE7iqTRHs7AG7Rdzn7O6erp4lcmi8YU+4J9xT3KN6TFi9KaZdPdU9OmQTyGLPmO6xhMMShiUM'
    'rx6WMCxht4T9uMcSdq/ejnvkBWzNEirtCInE6mnqqZawbvd4TmV24KdZNoF7sTrVYZoMbmzoD05nUvnrcMBls2IN/3tTweZKQpFP'
    '5hMqbJ5FIVZXBZSiuGpkNyHruogvh4SLU2LAnp5dNnNxRWFk9RTXaR7SlVmQe2toFldwMfP3OCqgkgpode1kWNnZU8aN8Js9Isg+'
    'So+/ytDqK7gMrQvEXEXOptougtZUOGa9CL/R7i/Cb2RDuwyt1pvxKkOLDLpbGdrmSPqh1IwyX0XdCttXGVrJG4qivSqTK+WgqYo6'
    'Xtvga1EBd1ajHazj3jhpvB2s48V0dpV95S5/5zrz3srtQVsI9zXtch9EQHCwYtfq3KWoLDxPWa4JvevtlBXvGhbVQcJzZHJRECkl'
    'cQcaLCer2rLtO9dZvZeg/f3I5aI8RnSK8BCpOkRY7RFGTyjKVuZRKAz3J66zerGz/3D+dl3rXv7M+fvGdSY2s1g/cp1JjCHaEokx'
    'pS5JDKorVfoK8Zq/eBxLjE0xdMARI4KdHQrslkXue1Ymeyg0XDZ9KHZcRn8ouFyoQCj6vJBdgc3z4+ms05DcLwAkhqCKwTr1eP3b'
    'TmcusbQib7im269RpWnScBpv1KbbtvEmbsOj/Gq63Rtv/qZHofHBaHpMGlXTJkW18YH6etGx/O/sQ/vaq3/yoSHtrW9H3HS9mUNv'
    '0tQe9isVOZbYk0Nl3+ekHV7kXGLP2upZ2z3hnnBPcY9y8LF6kXagnuqeqp4hmx1vhj1NRa4m9oQlDK8eljAsYbeEqaMNe5zY49VB'
    'syynk3osYeZhw7xu/haZGoie6jl1u8dzcojRuwFmVrqlUMHhCGvIYxk8gESlBo+4RlIjMo3xz0P5ZgSSa0WK9WdVqvNnA/c0QuP2'
    'CyVr7Ri5qp6D0IxKjj2I2hRIRwdrwptNURvixDlmBuiMigIldTWWVTqPbnwdHNQ8YUkzx2P5KA2vnuUeH8uuHUq3biGtjnqsXLjW'
    'BgIC0OMa8NWnb/XxW33+VlfcYB0F9FgpmKbKcdUN5oNlj2unEk0p06VBtxNMrewMZk+px6uHV38VHTUdz1Xv5CLq6eVWqpQ56Zbw'
    'UqxavZU8RU+dt7Ko/JxmfcraJR9zZSy06Tep6Pkxp/aEtHM95uy55qBQkoJgqx9z9qztnnBPuKe4xyHy06Xu5hURWN0j7RJKd1FA'
    'bPVjrh5LGJYwvHpYwrCE3RIiaUOPuXq8erPm2C1hs4TNqzdFZ0D7HnIwVz/m1Y959WOuu8WFDVF9KqT2ck6X1ny6Cn/k7+XTUvXg'
    'hgrJbjIJU/sGUIcKV/JPs/zs8nf3DQDtmzqyQlKgfRP6dsnc2VWxDqULhrRv0m1aj55V3q2yNTSJzrFDqvZRgu2RMg5G+gIG4E/R'
    'PqO9x6t2MNTo+qotDLV5vmoPo+1xkwqtV+1itLVfTKnhY73q5IiY4qqTAzVZz2HoMQw9haGHsGuX6JLHT6kfUj+jfkS7VJmmRF+8'
    'xhGMJcK4QratRThr9DuOZXV7v9TtfVO3913d3nd1e9/V7X1Xt/dd3d53dXvf1e19V7f3Xd3ed3V739XtfVe3913d3nd1e9/V7X1X'
    't/dd3d53dXvf1e19V7f3Q93eT3V7P9Xt/VS391Pd3k91ez/V7f1Ut/dT3d5PdXs/1e39VLf3U93eT3V7P9Xt/VS391Pd3k91ez/V'
    '7f1Ut/dT3d5PdXs/1e39VLf3U93eT3V7P9Xt/VS391Pd3g91O/ZNRZ1qzkuf3Tf1VmJI+R0CzkYISNsvIG0/VfX9VNX3U1XfT1V9'
    'P1X1/VTV91NV309Vfd9Vdanb/94o2Nfu9xMKdpTjAU5kOGaJTJHFhW9wwq8uhGJ1lipdYtOYCJggX93diKlNNG+iT8tvt5gvxkpt'
    'kztugN0dt/dW8U8zmNEk7R9OBoV7YMHxMJk9lvghkqwEVrDYWQhDURUlKTtLvi17/1HfkRpfJz8UmoXN5ICRZ76zMkYNMUeHasqo'
    'lgd9aFWgXlcVSFXF6kwjd3i06ozCr6aFyLiCYxlNioHiRsGqAUNkACLZISMOmulaG0rjJCk0mlqorQ/VAGKzo9n0faEd8LDt5H+s'
    'qgYsRaSqFHAXlY5Ujy5CWxUBVh1N1rdEq6CyKT8H1UBxAncEpFQQ3mZjgURGl5d8YahyzhLhIMT5ZC6X4hIX4nhw+nZG8IBBoR8y'
    'wC6x0sNZiAyFhvw6kvwFb5fFcNJBbpSKmyaINFXSSDKNM4+vcVSnkYWgFtN1B5ljWE4NV4fVn8Y0dUzAPbtwguXRTjqSQHkA3Lb4'
    'oEHvS4OPd5BolDHPo9gHMwmp6bjqbIwPpsMAKsLfmAm/5KcJHUqfGjwxg7ynqkQ3+AC5IF0zpR/oMhri2lCRsFI7EcOjK90hUEGU'
    'g5POcsFAQy7ApjD2ITpBlO7rKhVYGNSaaiLIF8pU9d9GPsaiEoIN7MMssydVhaUJO6sAk8/oU8RJEBa+6SbkM8O3qohrgzqhM7Oa'
    '1Mc2bhlkXYSfXxdniAYhVb22Kmsory6EeXWl0C5SqfINdlC8QcqQbchUUjEUx5TyV+iPAobY09zT1MPC1Udvjl0MYZT+LBfcO3pz'
    'nLIRx3kry8QhR2+yZ1jCYQmHJRyWMCxhWMKwhGEJuyXslrBbwm4JmyVslrB59WYJmyVslrB69WoJq1evlrB49WIJi1cvmnO0OGyB'
    'sz780xx9g6OFt+Tf+sgt6Zn9ta+A5i0jFb4MUkrCypsi7XCtcQZQNdUaF+HtKUqxVmD2lskQPBBbJjCLminkS5qKEMP13QyCRwZl'
    'UGtg+NLigZt1H6tQwylaJGVYwp1i4t08HeSYGyaWnXTJkbAImerwycEkaSLmDQWS53MnbiQlYk7ascOaF51yQ/yx/eZ+zBCpG/yZ'
    'VufNdVmo0giTZo4bXtiMJwqLv31htOcDxmqlG+JgXbAfoUmv/1ZVUhbcrEr9zrNeGi1ssc3M8zpNnaTaobOSwRghV6pVqkjqanJX'
    'o1fK/pnGtyZdz4y5kk0Wqqm6QkzJsh0zQ3uzHDoQoSSiVhYQbE1r4LlBdprRrnkO23R6A6WGlj40R0ltsYBPRUhv4WbcWFWWfaj4'
    'fOUDAZ5AMTofRYhtc8tOto/zjYou3DHtR1EalerYCpOoCjVmz5Vz5UOHBeTnEHRUjSrBLeo4LzrepMmQYsSBbM0lYbtXNyU1Ua45'
    'XC/YSNiUNsUerx7+FsOrD0s4pnss4bzC6Mo9+erKJatG+NBjCZdXX159efXl1XczAYyv4fbq26sfr368+vH1OYqq4ZvbkGyD/2Ao'
    '/vxcnZIASSdHLWL/8A1RYaMYpB1CmKtyJVgvZVzO6mO/er/5sYtMluUNRU4QQh1gDMTjR2yoXdz2heoCDV5Zx+tn+7c9yevnFe6h'
    'XIR6D/foH+3mXxrcQxZLj8Is5tPLuyEuQrWmtAgKiz2EdMfYjoI7De7tY5IM7bGlaQuRSmkmZnA6cSvktaY6mrrK1DaHPb1JN8rw'
    '3cW9mpzWOhMYZA6Arcuzv5T93oU+Gn0OZ+lP7sShswu/jeKV8vcGop0h7EpI3Wa1WzxDGN58eDaRRJRyKsj5KJUUckxuIU1bV/t6'
    'LI7uAawDKvrGAwQfvELnfWdqGSKPiY1WflReWhKhdykCaW/ghOv+492U+d1l2zBww6mxuId3KDQgyVCbc395VRdJcdrWFgMUF2/Q'
    'Y1y3G53Gte1bauNW/XL0jOKe7Z5pTLupB8f61qbDHjOA8YRfCq/YJitDjyHxaaItqC+bpVT53bcUC6amdRccWkd/3s1uvVR3ieUI'
    'oX6oVj18T+WiFNtyS1XHs+BXanYMzaXq0CqIyLj3I1Kv5owtJmJmWG93NHgRSX3rYvOXX2mByBdbDcWopASmlw0/bkIQjidqhrLh'
    '1YJzrTrdipdXhS/hw4LKnLzFzaHaU7nRyNmHUww3dm59hDm+/nwe090L3WoMfulMpsjgr7bsOAMSnnvcleXFXS//SuEw2F2hVmz7'
    '3br0l7aVCd36lbRlv1vfTtta8rt1RbG1LX2HLjmkynmIZdm/PvAINwerAfbG6yBAT0LICEEB63JTStcR+YR6qnpSKUVPujWPcB71'
    'hHqARTvke4t8gvLkBd/K3lJP1/fKnxLfAglfk9ArvylS7ILkqF2wa97/GZ7K64WkxsLAbVzkdEEuxozS8QjrlZXW8VOlnplb5pL3'
    'Mn/v3MomqR2QGTYJO+dtkoZ1upEQqp2KCk6zCtgA9z880so+boyxhAc2VAsM1moFigAqiPzNgzgI8mQA6HeWuE6tNTOOSC9I/+Zc'
    'KiutImWirGYBkcaQcrru+KRPEX5ngsqZyqqeKj9NmAKu2SpeBz+IsmXz7iisz5YXOqESfArjxIf2g65iYaxy9VlfzBKsFgbcZpEh'
    'Xkk3VJ4aN8OgctVVq2zgNVTHjGU6Q7zsAS0uxBhJBupQUDmRM6VCBQPRROEW1Cu7KqxR72zc9kXQXKl5ysnnNOold9WVRw0eDoWY'
    'H5x+8nFl/twGKlkIKuFRVlq1lCJUQ2XoLt3FUKzHYqwWUv/S20F+BRyIaaQw7XjzLhyEqjZ/e+CJyK77ZM7bZ79IVEBzRWN3EWz9'
    '6smDYQ2mSoPF/FOMQgPs6Z9KIx0gi06ICQFaB5bNZsWPzMfrgKRyX50oCvV5aEQtgkSoP0o6VUFIuXFvsrYgP6O8mMeQ2ZigFDSt'
    'zLLDYwk1LINiiTFRU6cKV6XC4TdEdDGbAfXvinLabMqiZKB1vSJW/qMh9P2jmozjsdpn+3pT5ek98hzP88qOGMq9wCtAE1Y66BcH'
    'H85ctl6VD7tKOG89h2hruBqF8R9rvPkA13jXeNd4X68qDl1chaCC0XhMteeLVHDzNmBb40PjU+NT41PjqlKGFBh8HY2rrvmniNUR'
    '0b+ZBsC2xrfGj8aPxo/Gj8ZR4HaLeUg90z2eU8V3g1q57Bnu8ZzmOc1zmuc0z+me04t7PCffdOUisCc8JzwnPGd4DlgYcex6DooK'
    'N8WroGd6zvScOW6O9V1NKNpMMVplifRmGtJKO44923O252zPOZ5zWKkSeo56DnvgxGdcR3fPcM9WT/Wc6jk13LPUczGigz5UJYvU'
    'EzxHUPyou8oRLBTct4r/xuGCEAtWThIBSFMlZirD0IERQ+0PpIVSpa6HzhoS5FbHYwgRVgHOKQUepUymFOZwuHe7OG+tZkON7P7K'
    '25zvPfTnu9lUEdIBBZ7mzBAaiigXhYEp3CV06KAn2HNk3xzNOJpwPC4bYCtgZqvo1Fb4+ta4WeWWxpdksA2xJOXU+NT41PjU+NC4'
    'yR+HxofGQ+NhckiNh8ZdFKtrvGu8F8f1OTLOAX9q+yoO/4S+hr5gL9r5Psw+r0GO6QD4T8ZJys+0H8WGEnNjHQe4fCOhbocpl6cc'
    'v6p3o4Q+ZMsizm2wACuzZdnjkKFpEyxsLaZSVhzdPzSZNW36Ft8IkqarbtHhoEraWedmbNL+DrkCYADKk85bPZ+vY4JlB7ES7SkG'
    'eeoVQSfFC5MZgKPyOZjMXMPhHqmY2G1CTPek3IH/0MXFjtAnAnbHdGJrKPRoy7DF7hfe4kieLMbd6qTtF52ySX5Jp2yUkIBoVQgT'
    '9t5QZnefplzutHSQjIjJwOm68UcfndVnLSZjF23KY8DkZb40EvRVBQ1W7WzVVK7IaXW1h/+vvXPJlSQpouheGJdQuPl/SUhIDBiz'
    'GUawS8rtnhv5qlUtMaEFtE8yKty9XkZmxse+9+S9Lntaw4tnx2YKL55yglRj9ZBJ2qT0RYKN1K/IgQ30yc0sG/nhSWMGcNaUSQ51'
    'uabFns0U6nLNmMNAbGAiV9xRCx5qp8/M6XFxBknxzO7MdEFEHRaoS92vmCZRyb8K05F3xI7lb0nb5lOVG25rnE5doeYenASFPtCi'
    'H2phlyN5TGioubHkkwUv8lleMSRJIyEtRZ+ounC3XIHswd3SMSZBrgAXfR/fjzh/tKKe0qLEJ0HzXojpSVdpgj/EMRD8hGhYV4L2'
    '+2EsyUx3fYCtHuL+Nq+6/e9gfPRLAbQ81zGOwUi8zfn1mrSwz9U61c7x/XTZ+uWbqsa2hBubmi/PFbrFazzoG+k+Nik9Lkhz5xfY'
    'NK08oP2eZO7kOVvRYlnErPP6O8UBSJxVAt958X0/r/Pak25IXju21BbRh0pgIS87i2TW/hHRJCMziQsH46r26x/tGsoLA42baZm4'
    'gfYNIWNlJ1SbUGgPPVeNMjhkiKbUns49JbDJBt2B6YOfx6gRioSBx/R9UaWZqjKsan/dEsNNe4txuYY8/h6aecoC2RjfrG5Q6geB'
    'mPf4UFSrW4qfMF63sfV8YWs2oXTQ2D3xCSqm9Cwq3yZ5UNrVhoyxXj+YFuM5R2bqTuCtI0tLkNB2VihMrM6HjN8HNWihHssTNlNC'
    'dbPL8/sfL6bn+XknIPqyehoVGtNVEAQOJR/SH4BEqMjncwudkPG6vanOQ+WVPqCR/svuuSwoXKesu7gZAKuguPTeNgGYvPqWQstE'
    'SDz2UCwodVKCfcKnjdx/wzjoFP1mOwLKet0yAZIbSLvgjG9Jq6ZVcMa3mI7FNSsbPX36mNIgyGIp1VamObDIrWXCVIqB+V2f8S1F'
    'wbxRn/E0DdJYaHLq0jJ4nKZ7wAqa9SWnbtNDrKd+sWUQj2/4tgw+0IIXY0AZg7y7YfiBmQerG5Aw7N01pXT11K/bdgAa/TmlDrxm'
    'O8DeVN/29+xNjWp/D0WFPNkqeSbZAbM6w0l0PrNI6pcgoCbA+mIqb1ULPySnJvqZMgTW8ojbGLfr/h46SbMOe7rzIeP1ea9xw2Z4'
    'apLsV9G/eznzagpPDfpS5PMkjmXiehVP5e0sczDLpQlAbpWVqSa1vJ2tFesg7ePi/94pkUTjvljmyF2rGSV8SFGU9jU9M7tlgTfu'
    '4nTZiY08eWXuWEgHcg3+TrqU1HdQoxKuY3Gnwfnd1bOE4RAoTDDCXVOumltCv3++5aTTw5eykPre1HyqYGlTClP1uDmfaOMRD/uv'
    'D37wQBNwo5Yjn+ORW9ge7uB2JykJIayZyCvShpv0YydBtsmKuPlr9w+i9zxfNs+fRuon807PlNpZWTqeB7ewVDW7blkYSbp+dL42'
    '1uWFvqTRf25Wi7LjRpu9GSyV5+ty5cXS83fxfK6sU2UEklqz0Uy7ZWdMalQ7lRtDpUBF8l1pH7x2BVGcuT7SFq8GXrXdgZ1RbXcU'
    '2RloCJ6bzrS065B943IBNc0qMlsKGPijMUigK1g3sK8CLZxzMabQkMyvgagdTPVzmpwUpCy3IXWOIsW7IYsvZTdm2hPp4aY1ONBv'
    '7WkpDlU6ZmRXAQHh/LKiUdZnUQ1vtxxLegl9mvDbG7CGb0KIdFWazgzJCyd3jImGLSEOHZaE6ARU/HSZEYr7ljQiCnIcRQock+6G'
    'Eoh35Aimwz9fEYGfx36n/gi+LskGCkjO7RpNFApKJv8AlYlbOu35vs6188jth6q67rtslykfbuHu623ifHOkQwVn7uZX7z1nyaIn'
    'ZFCgKcJ7npV5MJWz6DgXnJ2qvsl/EImnAcyFOWBKNVK8pnhN8ZriNY/XPF7zeM3Dms2SzYrNgs38clIAU30x77ipPOTxmvK+NCaX'
    '5mBejTudKlU37nRyEBC0u3Io5W3c6apeffvfFbE615R+Y1RtnsX+fvXyG6GAwOVpBAuCHEWzetZUcVbj/fPbjId5Yd8LJXX5/ZDE'
    'CO40X1q1u2h8lfvWUQWid6R96l8sJHguT6RSIJpTO1Pnl11mJSRThmHpavigd0GC8ar9x5R5ZKQ0jJWfNYswuzSLpNDZ0iCm3fVK'
    'pSwZLpZKWV8o9vXHZhFmUU5xd4hY9+H+JCR4qntH+is+Qo2DpUkWgioIlxAqRpCjUkLCherFFGCqglbZrnR9LMhBMUyzLgexQUWm'
    'dVc/j3UHUTPS7DaSJpmn4x01Cl4zWo2WQB4zNS8NZIfdp87BdwpQO6p6fX2Bcp6gLv/fBaZv0JcykjcobIVcgsqWF3mDysy/QWfm'
    'F++3mN8cz2Z+M7/fhkkX8TzFI29HKKzOT6HP45h7mT9E2Jstt/qlYCi8RgHlN3bvOjb6LxTNDxxdpRDW82XNJyvwg87MnF/W5Nc9'
    'G5mM40EoexsuTuoOCrug+pw7g0oqHVizkn/Syh7OnzH95PDfyZ+m43dI++Utw/Ya1Sf7I1figrm4dudR/IXrf9k7CP+dzMc4eaOR'
    '5pHHSi/bPkX3iNcUr3m85vGax2se1mRcJO/uu3uke+Rd8zCyvGZ5zfKa5TXTa6bXTK+ZXjO8ZnjN8JrhNd1rutd0r+le07ymeU3z'
    'muY11Wv86+hZ7BzkdFYyquPFzlyGGQHT2c14C06dAdWI1zxe83jN4zUPazZLNis2Czbzi/nF/GJ+MT+Zn8xP5ifzg/nB/GB+MN+Z'
    '7+PVO9Q+8435xnxjvjFfmfd5XJmvzPur9DfpL/L9Hv0Vvd+iv0SOl8Nllsnce+tSImtVNPKZ9qpXeP7vf/zTX//y57cEYf48gmUq'
    'qgX9FdxZ840bH1FhGIAK4547xFS1aLJ6KMSqiKRVHtv1+VJVGgWELdm3QbPx1p+rwI2r0McV9HEV+vidFfq4gj6uj4jTD8RpoY8r'
    '6OMQ+jhAH4fQxwH6OIQ+DtDHsUjj4SIIfRygj0Po4wB9HEIfB+jjEPo4QB+H0McB+jiEPg7QxyH0cYA+DqGPA/RxBjy/xD2FPg7Q'
    'xyH0cYA+DqGPA/RxCH0coI9D6OMAfRxCHwfo4xD6OEAfh9DHAfo4hD62YFMIfRygj4vYxwX4cRH9uIA/LuIfFwDIRWnSgiFQxEAu'
    'QJCznYINNBV8ZUGkRWAe6EYp7Fugcyc9kA0Elc4GO7WzgZ3S2QBOIQTXcV/MJQSZ0tnQHYbH3PGUSRx0SCm0lHUwKZ0NjBRM+e4i'
    'IzbCo3S9KpLZ9dqy8KnrteWtUJHQ3Ml358TUeclpqbOSk1LnpF5bgVqvHiBZYFMGlOUmED6L/WkY7Tikg7voMKilQlzNf1RmMjAp'
    'RLKByA9JOUkiV8ycYbGO/McuRiQ3A5G3gcjbI80j75rHI48Ryd2I5O6R4hGDg43lDWN5w1jeMJY3Q2f1pUjZjqtWCBEQeRuIvD1i'
    'bXRjecNY3jCWN4zlDWN5w3nkMJY3ra2K5CEjPkJjeSV4YoWQZYWQaoWQ5WaKaoWQZYO32oZdwCcY8RE6wh3G8oaxvGEsbxjLGwZY'
    'h7G8YSxvppLqdg0PJcqMGBy8DQ42mLeYzFsMsC4GWBcDrIvpvMUA62KAdTHAWhp+YPUYMTjYAGtFyh0yX9PRdOB6AJF9hN1HaIB1'
    'McC6GGBdDLBWlv9llzliU7cz+GAqACL7CA2wLgZYZ2FhdYXhojWLER+hr5TiK6X4SlHWAmQFI353XymqbZuudqPtVpBkPoTh4r5M'
    '/MuYXb14X18i/lUmB+/fJC8PFSYLkkziZCJtn5fGVJY/i04BE6W+fRcMuZLlX+hAv9BkqnKbtacT8Cp7ppMHOd9qI4s/VdtaELyV'
    'BxNAkjuQ5PXRjFY/MNik4t4tChipGF6ISi+5bANKMrpIVKJ1KjQbpQKkXdDNtA4n9Q+dbhOXM5AOwO08tmrq9SslkHANzT6NXdWA'
    'PqoZzsB6vp6dLEzYMn3z6szXriZ6lRSf9Ovx9fL17GRNAkSszNLk69npudO1k+869Kcl1I3Gd3qp+Xq67/NNm940wxf5+n0n7xH5'
    'enbyT1f96TQW87Ur+iWJiK7odORrltGoBJYiUxXC6mPnp9bB5LHkP/Ov5h/9YjV/xTV9//Z/VrdVAGKoKZuM07B6luVJSQp1mojp'
    '3dXnp8NWgWnC3wrln8y/Lj4X7AQ3lKDoKLhNBuK9QQ9wbofWJYyBh6ZsZxnLBWNZBuA7+2zZzptdhcWfzq6scgzA8/zsbBC37WxQ'
    'tqVlqbdPnZwjQVNW6sRKnbJDJ3aoDMDAADyPSlJwvX3y/hiAJ23W2aBg29k0hajo6Olo13Y2BMg6GyIphHw6/UmdDY1HnU3Tw7Cz'
    'cSMbGxJUaJh01KPcpdf0AOxs0JmlaK1TqtbZND33OptGZzKbRhshm6bHXWeDahNaqbKdZYfioxT5KAUfpchHKfgoRT5KwUcp8lEK'
    'PsqJNXQ2TY81tFg6KumdTdMDrbNpepp1Nk2Pss6m6TnW2TQ9zTqbRkU+m0b0nA1qVGjAdmmsqyotd/IYOD3lnuCd6Nzk1JRrgmei'
    '85LTUmclJ6WckiGe9fq2X+RaEAtVAU8QgaT2661HJm1TwyoLX+g58+fUnF9AXZOFU+LfgLpmiwmUvd8A6ppqQwXqnqL7Be5eSQV5'
    'VZJIZBB2Q5PAIDms3Mt3aPH+lbyVn+jxxPk4JqNqacA8fqprJi5HliWM6iqCF2nq7sH8x1r2PcJ+xbBfMTwSHvGaZ9qvmB6pHrH9'
    'vW0B24IKW7dhGyps3Yat27B1G7ajwtZt2JLK3lX5Fba/bd2GrVtVnyOrzojtb1u3WSssv8JH2F++k4/Q1m3Yus0SiIqOKyM+Qlu3'
    'GeCt2+2jVo+orgmTX+EjDB+hrduwdRs2wvIfywnOiiQEIz5C+4Fh6zbsB4at27AfWGzeFvuBxQZusR9YbOLmP5aLYSo6wMWlAfgV'
    'tr/tBxb7gcV+YJlvPbHtb/uBn3pi+4GqJ96uFZ5QcyqKEfgVPsIXKmo/sNgPLPYDi/3AYj+w2A8s9gNLfeua3konH6H9wGI/sPhK'
    'ycz0ctFwRRe6uEQTv8I+jK+UY6fKs+BHthfoy2TzzosPsHlfXyL+VRYH799kUog9AWJNOikmtlpeGsLoydMIPIuBp8H8gOPd6xdP'
    'gxtb7nc8j8DzoHOoUiyenoaKbOV5uF+aAvhGfXQhLdKpdy58vkaFkrUxK8o769NJRSWCQ7NNrkVVLa90vZTM6c/bGhbzU6sMHKCT'
    'cKLqqlFwjTh97uZtvYCNFe/mUW2FeTdUYj+a0y0/Jfl+hnU9d3vQaj9gXc+zBKxaKgMCVfsB63reDqDar2Jdz3vxaPlVrOt5L1jr'
    'KYZY269jXaXr9Xwz8lbPQ86Fb6LHnM94PqLe6VvWkSSYQtnjLDLVvvyM53eKyymXlnNpOZeW8/9Ey4kLy7mwnAvLubCcC8u5sJwL'
    'y/kvgeXUy8q5rJzLyrmsnMvKuaycy8q5rJzLyrmsnMvK+Q+xctpF5VxUzkXlXFTOReVcVM5F5VxUzkXlXFTOReVcVM63P/RLyrmk'
    'nEvKuaScS8q5pJxLyrmknEvKuaScS8r5BSlnXFDOBeVcUM4F5VxQzu8SlDMvJ+dyci4n53JyLifncnIuJ+d/jZOzLibnYnIuJudi'
    'ci4m52JyLibnYnL+bUzOvpScS8m5lJxLybmUnEvJuZScS8m5lJxLyfmtKDl/+9u/AMr6+cw=';
  static const String _wilcom_e1 =
    'eNrkvdmyJcuRHfYv9XwuLOYBb5TUIqlZasn0QKPJrkCIhBkaakNDomRt/HemryEy9z5VdwAum2rqoSqHvc/OyMjICPfly5f//Zff'
    '/asvv/7yb3/3+9/8n3/zv/02f/n48ofv/+a3/+SP18m/8tFf/cFHf/zT77/8+v/4/vd/99uPL9//8fv//Xe/OYd/+P5Pv/u/f/vX'
    'f/rdn37zb778+k9//L+uc7/5/m//2Zdfl95+lT6+/N3ffv+b3/6vX36dy/xV+/jy+9/+6U+//eNf/+2XX9f+q3Ed/+4Pv72+XMf6'
    'Vf348je/+8Nf/+b73//2y6/Tr1q/jr//f3RcfnUd/uvf/79/+2/+7suv//7LP4n//m1c5LrE9fG/+Psvf7pa+6+uxl4//S/ax3fj'
    'o+D/62eu/wf+XwP/54/v8sRBWR9jfXxX28e4jnr5mPPju9k+9sAmZ21r57a3e7sWtzmV6wtTO3lrJ2XuLH1lp2tbEn46vp5TvXZ6'
    'v3biT2b87XWVfH0vl+tvS7q+c7WPZ2rTd1rSX7Wp3+mVP5y7L/1sXbT2+rvvrvvL8/r9Fl+cuPM8CjoCx/r42uyKzssZm7LZlYMb'
    '/gUOr18o5fpuiy/Hx/2jxK2s2Mb30nXpHbd0PYi84k5a7ES/jHpdLtq9rp3o+oJ2X39dSuxcfx7Xwv2XuMlcY2d/7MVPojfL1U0r'
    'zl9dPaNXV/kYm78+Ki/X43zpHw19c42G65evB1+jvfOjXm25+jK6u66PhnvCw/jA0OFu6TzDUdMqvtujd9JHv5pz3VDcQfT8jKd0'
    '9Qnu8Rp4C60ZfOYrnnlc4+qkaNK1c9189GTeU0PpGn58Kle7M+7lGnlx9ruco++u7+zo1esrV/flvTFoS/zsdS85eice6Ercngcc'
    'vbbZ5XoW1yGeUrvufvIweqPp2V6HuuF4INhivE7+VR28WAxEN+Z67t/tqxHxKK4OyCNepcxGLDUCY+J6Zb+LoYwxHSfiChj/iSdi'
    'BF7Ha/Dw+mMM5zS4Ldo2bePdji2+Fw1rGoxxP40Nu4YO+jO6M57GNQ5KzA/XuOCNDL0m9eqPeG0mu+nqcdzAdWPo5ZzO84hxmvXq'
    'RYvjfnDT+eq5jN6LX48RivGOoTjjXcbTWbxgdB+HeUqYK0pa7JF4qfLAOO9+E+pHvFDxaNBZpS4NpXgg2InXh4PLH12vDsbDdZuc'
    'Ya4WzTgxFgdkDD3MHfF+tcf7cl0iWn/1V914pjF+rjuMtnS+a9d1476uhsXEdI2gxrdlcLBoIMYTuIbUxADTYIwvto9aODIXPuHA'
    'i6Z9xB/Gf9cvxy/Gf3H3sbuxG08p4/84WDhYOIhJKeP/OJg4mDiIq2X8HwcDB3frM++h8h7wfxzgmo0XxUuK/+MAF+28KG4Y/8cB'
    'Ljp40bjrjP/joKKXMF1NzA/XSUwT6KQ4wMUXW4L+w7fjb8fzh/ir/LmYwK/R1/hmtng8bOv1nGMEXW/G5EsUYz3elVim8A4lvUP5'
    '3uZYeWKExADpUyewgi4tNzihb3BqjRdc30D34YS/UXSi6Rt1+UTWiaYTmJiX3hGc0DfK0ImibxS3o+gb2e2I+Wx4sONE0QnfXNI3'
    'km8u6RtJP7r5ha2f3Px46weXPtXPLX669GOTny791OSn8TSuF0bPRk8qZqCwPTgmNInzIzzZmJQwV+HNKRjT17ofL16b+OvOAXFt'
    'ol86/+7axIC/HlD85rXBIt4wgK4NunSznRtvw/VHc2MTD+KammIBuzZh9lx3Fzd4/Qsb57rJmKSuTUwJm6N288255onog81VNsd8'
    'trltlTMnbKBryxGy0a+xbVrgMI1e2+ilnNXh17bDdip4LLHlvDsxmmOLMRl9lxJ38J5G98EK0yQVg51PuHHljvEYzcEOZsCYsNPg'
    'Dl6F64dyWtzhwrxksF07o2lqz7JpYAcMjbjYwUSApU32G9b06znAsowdzMSxXMaTjh0sClevcjxfOzAqbBXGzoSZ2LlKxA7Wox1W'
    'ReNOPMyClXVwJ+YR2h2TO6twZcgxNLBExNKTF1847HA58U4sOXHf5XqW8ZhK9F30auzsom9gbr92YJ5Vr19YnOJvr9EF2yMeVd7a'
    'iX7GDhp7fS8GUSmTLzB2YlrFTgzPWA7XWeqqdobPVKyYXLnCtOGFYA0N3xl2ujpBTwe9Ec4AdipWzqyO03SDnekzDTsDkwRMOVw5'
    'duIRYgePMNZdPsPpZ1hpbGMHD3FtWRXLTzEMj7m1g8nvagoNu9jBsnb9Rti83CkYWVkGR+zUTOsTBhB2sP5dwximEnYw8XYZO9iJ'
    'O49JPuNljR34NjCUYNPEGNky5rfMbLol8X7hlQ1rC3OAzS3sNL+leG1jB/PAdXMF7+21Q6+mFBpvsZM5F9j+zFpWwiGgQRZPq2Me'
    'ufwRvLvprFKXNZuO1RkT1aaLEu9KjN3d6efEyxRDN6y8TGsPzsgatAbDqsQKeTUsc07EmLymSFjPYcwNOlslnnk4XTHarrc9hmJs'
    'YRmGVRrP+9rCGr1+Ey7UyBxXMXHH22ZrNGz7QseUtnu4XAvbPGndlnim8QTgx4YVP7mN7qpat/EYGrYw62ObaQXhPmqWWX9tYfZk'
    '/U7lNro/c5u3tnPdvkW2/8JN/CyNoyzriJ4INzicPOQ1Mo2ZLNMm09DJMns46Lmp8jOyrPo43DyUVbjZjK1mbDZjyzKEX6p7jUMa'
    'h0m3immcGxx2HvJCeJCZGxw2HjYdLh7aBJUNWh+dePdp44WaLgQfkJs47LxQ14WavDVswz/bOsaP/ct/9y//3ceX/8xwyLWafQUO'
    'kfuHufgjw+/2kT7iuQUnHx4/HFwaLx9EBDAdD5lofAs3h0/uHJ7xusbscw1JeIWtcrjEtBKzZFhYsY0JLGaF7ceXhiYy/xLefPx0'
    'McqSXyzLcr/EMWXGMJuyVmOii7/AZDaJeOCxTDpN1+DffAfi7q4JEG8ajyY3m5toDgZf+C6DMx3Oe3u1kMt1+eCcn7jNNG1iG+4h'
    'lx+utIUdiNUZw2APzYxz60zMFtWTL5aHeN/xiGKtbWqAGvTSwKvBtKEMK2WvDOFMwuyO+fLuR/fs6esBCypxPsFEjh/uWU9oCIbg'
    '4mPTZGUvfVpa8WpjyQbYVDW136BOk/kdO0Diru3QtnVui7aNm00sCCbAAGgTCFBVJ2I7tb0eJ7ZV20yrd3MTdu51m9dl5CTyJdiY'
    '+O4XInphcTTz6PG166V7fcUAJsAzzvQzr5/WET/Cuz9gmRJtvA4WDmLJrHq/hIagv2JMc62NFwk2XSPm0A2/VPbvrFxCY52KlS8w'
    'IpgBeOrdq+TQAjplnuM3AUR0QjnDl2b7aTolYg4a2gnG+bWJ717Pd3J2nFxd0K2bbkfD0eTRZpfH2myQDMdVx13HQ8fhbiTaTLPx'
    'vYGdeN0QxtH1YIBTVfZ5bLNMTRiCsfJf22uSoiV3+RCFx2h3pn8WxzBVs9zFOAFLHG8sZ9wqmzjJjosVgPYOutnQHqFRg29doHGY'
    'DVwLi62/sKRg0AWil4QU8q2Vj38dYxtvdSfUhE6pSdPP1vSU9H06c8BrEo9XufEbHPtz2XJbn2+1aOtzzi6bHjFOLJ/QN/hJnMnF'
    'Z7rPnO/YmSr+Tj63vnwGzz3wsCo4DUZtvG6tCUXDkI2+JJ6UtOMpP+w9zitFv1Pipc0aERi3McFXbnvi1iOoeo4e/IU5hbphpm46'
    'LpxqEjs5jIXSOIHzuML1htslP4zHTcdNx0nHicdLflvA5UOun1zAYt9wcsvjouPC43hTJrc8rjpWe7ra09WervZ0taerPV3taWpP'
    'U3ua2tPUnqr2VLWnqj1V7SlEPuL58ljtKWpPVnuz2qP+jS2xnXsQ81jtSWpPUnsS27PZnM3WbDZmsy033IUjNmSxHZOXmWzFZCMm'
    'rzHZJZMtGGzA4BUGLz8EtPAK16bccaPOKzTeaKxfDaY5jhpGUeMV4CjRBJm0zgUBTWwGVyJ6mhy1xHBiLnZ4IqDJDxzHSP9IXKRi'
    'vo/9SXtnXftYT8Jx+OB9hXMwr33M1SkWxATYJ/YDd8WCkwLRIXAT+z322fAe5zvvpUcL4h2N/WjD4G+OaMPgb45oQxgTDbNXwtvI'
    'fjidseL84m+uaMNipGpH2zZ/c0cbNn8zFi9OTY3Tj4CdxqkncbZqnGQ0+eAIn+UhoxA9VdIxERPnq+Y5idAHDulkxAQFcD8mABpW'
    'YdDEE2pcJWK1CE+z07WGYxYLM62+wEwGbC8aY23Q74NNluTXYdXgetK1RmPFqYD5sK4X2XCx/gMtmZwGEY4hDo/FC4a3hkW4DUOG'
    'N4KA4ZcWGuTAcjLWbDjecd1YL4fCPfG7ON50urGoMUgTHgdN7kr/N46nPx86ngQPAucKv3HJzA8THiBazo9gytD0oqXC/iGssp+8'
    'VNh/2I53Am4eBomMOWUZETGwinwBLBGCq4CXVYYmaozYy0Ro2AQMyaNOQzTrQ2xjVWk6NrK2dSw8quhzIEuX8QE7psueCYO18pir'
    '1LXV53AfAiTV58ChBJriuPOYBo9uJY6nmlt5PPQ5zsexPqed1YAr41i/B9M+jvV7S59P/d7S51O/t9UfS7+31V1LvwewFie2T+gb'
    'W7+Y3aV7+UR3H6tT6F7hzPAZfyerYwjMxbvCRyHTrASqgueP1y/b+lty05q8EcGFmyM0vHSF55IB0EpkjSBjXAvzyZDNOE58zhYL'
    'ejDQCXqC296z0dfjSBU5iQVRx61m4CWIV4f4ZZe9Hgb9cnwZwa2AtZadTZ6pQvrizwFKbGEn+AgOYhhXOLMcqQnzlmfOd5rOxJvN'
    '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'
    'Knyi2qYS71e9iKMfYSryetWbOPoTiiLX+apXcfQr1B7PWqb9OM1stpt6phhFl82BqG8VVFWVjUKh6vKQVb5O7PnQXY7j+hBmLvmE'
    'P724LIU/l4vwOvo5eDz7I+m45FtJevL4KE2rQSdcq/ZYTqu3xx1ZmK+QMnLCvyXfSdVqz0m6VntOUvajZMwJR5f8StYvLB16wtme'
    'eR3uLvlW9pbalybwb6fJ5Gf8/PkD/kHLhnnB2frhxC07pur7ZhcKhi/pxN3JD7SETFFWt4kEGhJp3QUsJA79dQkYEw/6NyRgTFwY'
    '35CAMbXJRIn6IxIwJla0b0jA9FeixicJmHFemRd2Vk/KTUs0ALq2ro6iRMFTHaWnUy2FYRpts2p3d22zaeHdO6cWSvfOqYXSvfNS'
    '+SQ3n1k+4+ooRU2TNeOSfxafwpmaLSPtKit1+Ixb2NzC5hY2t7C5hc0tdNVfpp1375wk8+6d7Eos3TvZym3dOzndZmR2vRoacNlq'
    '1tnW3tmxaU5pCI0rGd5Ss8Ybg7kLehTJPmP2jl577nT7BEUV1/im+9Wv590/L3+15INe/3KU+UvzGWv3l+QzevuLg8fFWvUy8g2b'
    'xZnkq5smUjw3F8/N2ZMzd3p73vuZnzyfeIZ+qPp5ilnHfLRSvqfpbEX/7In65oF4qs6eq7Mn6+zZOnu6vuUPEb0o7ekEWYzfc/VN'
    'UGknpu7b6fXTD55LnF+257U1Z5baXPCpWKBxeVoUy71Uqaqx8WAoudbPUECNUAM0eWVI85mmE+z3407NgUKVdwQLZShVsFgV9A4m'
    '8owH/xLpgiHIpRmzWAVlSCmfZ+b0GVcgnGoh5s3iOt5jWYUhSbsUZ7pb2N3C7hZ2t7C7hd0tbG5hcwubW9jcwuoWVrcwTJtiAZmx'
    'rPaWXFhuGbAzpOipgGeyW5jdwuy7yG7hmUCSW5jcwuQWJrVwq4Fb7dtq3lbrlhq31LalppkANPX51OdTnTvVqpfanku1PRPD/jhW'
    'o4dVofW5+72rwV3tdac3jcmmIdkUKq6Szqsi6VcpAVm70eLaVievLj/5LFJJ8rtC6hK6l/6RgZZMaQll/YDNyrwu+TtwQnKvp8xn'
    'eqnymR5FPhG+GOPU+EyPEp+Q/pr9VPhMjwKfzB1rp75nepT3xNXlAmb4g8/inulR23N8SIxdpT3TS2XPdBf2pMTYo65neinrmV6q'
    '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';
  static const String _wilcom_e2 =
    'eNq0vUuvJUuSnfdf7vjchr8fNaMkStRbFAcaEIRQapbEApqtRrMkSiD43xVu61u+42TeyyYHQgIZ4b732W7h4Q9zs2XL/t0vf/6X'
    'v/zhl3/757/56//zX/+vfyq/fP3yt3/813/6R3//VP5jl/7x37r093/5m1/+8L//8W/+zZ++fvnj3//xf/vzX9/i3/7xL3/+v//0'
    'z/7y57/89b/65Q9/+fv/66n76z/+3T/55Q+lt79KX7/8m7/741//6X/55Q85778aX7/8zZ/+8pc//f0/+7tf/lB7lP/8t396vlzH'
    '+qv69cu//vPf/rO//uPf/OmXP6S/av0p//H/oVz+6in+H3/z//7dv/o3v/zh3/3yj85///apPt96Pv7n/+6XvzzS/stH2Oen/3n7'
    '+rV/5XL+L/lz3z4VdZ//+zj/z+b79VXn+f/51V/r+Ornr8bXeD6Z+2v1uOTEtTRdW9X1fHvU5/r8dGtfeTzfK+Mrz3J+Mj5+LpWS'
    'RJwhQN5TkoVQpYWEpaTzzZJzXNJTquerT2vPH+f1/Ml8WltP/c7PLz0/mNMjxljPTZnPzfOH+XmS3B9B8pGsPb+f1/Pldr68H9nq'
    '8+WSm8Qqz3/5kfjX0tNXzt036Xz0fCe18+X1tZ+fKal87fMr6/mVVE8FX40G8jxNFnXS6aFcz0fltHQ+evowhDh/XbieX3muS5fB'
    'Zevbp6Ny6fHpeah9fu7p4dNzebWvFQ3Or9Md5zmjO542x6l/3v443VS/TrfPZyDMeLGno58eqOdJ61eNjs4aAPw3vp6efP5/+uH5'
    '/+nv8//TVTWGy/O4pwNrjKmn0M59in9P408xqp67/dztuMvnC7nqfp77FfelPPfPf3E/zv2M+0eoFJKd+37uh377NNJU3+dLODUz'
    'z0+oD468Sf1YT3c896ofR5QhUft67mOcPPenvvMIR/JGk+3T5Lv5M/6fbuhn1O74kafF08Z6LucnUw7h8tNLej3lay0NyX0+f95p'
    'Tmf8PQPsfOm5Gdyc+XPmwZnn+XRbeSTK9dycyRAjsmTNwfirFCP7GXhHnHymZfboj/lwBnSJ52yamaedHJ16xuQjcsym88hPH55f'
    '+vUM4/O2n0FTzhh93kaOYfXMsXVmy5l9S3N+nnHy/N04s3xrmp/hl9WHTTMuP29ME2IlP3F59UGa52Zrgj2jNgb5nBr8z0+fVs8v'
    'hvyVF/3M4hjkS1OnnHd3ZIlFLMXC9rTfotUf39kj09JcOa2cGTA1H59iPqvSKVd9HE+w6fN5nqipfOqjzIpU+fysKKdcNmX6ONbP'
    'p5z5vcznmd/L/pzfO9dTTvxerMNN3RZlfX466ylufXqWy1PKUXpeySmd/julrhKfqZmpz6Yamfpsqomhz4ZaGPrszJSzlpwenZqe'
    'T//emczMOZVl6bOz3JSv0x3P5SxFz1w/U/y5nHf23FYNs/PTzw+eDmY3aloAnsszS8+IOy/luZxZ9/zt2dWey1kQns9jH4m5/WuX'
    'SM/ljJFnCB2Rnst5hudxjkjP5Qyc54mPSM/lTOGnG45IU5vg0rpwhsoZMT1Eei5ncXm69oj0XE6fbYm06boVIj0X7VIlZDrXGevD'
    '1DL0XGcs10/bRddYzrJ2g3ON9eNZEGJdea6raFsY7+3h6VltgtqzzwCdSdfYJp6BOrOusQ49ry7Wp+ca28rz/CHnc92xZhRtP8/1'
    'DKezGMyla8zQgZzPdQ9tS2dMxfYU69yWnM/1bJ1nq15N17M2/npWj5jSzzVG81kRQ9JYGWPwzBi7OebleaYzppOuMSHObn4Wq9jV'
    '09J+vL0vp62V5UyKWGFiTz8rzND1rFHPQqal5ly1KuXOTWgGycvvuTk6yFFN4iZG7/kop/cSfRbtkOXcnFF8VButbo1Vt9ShJyqV'
    'pSXaioX93NSYJfRL3LTYF6q6rhyNooXsWytA3LQmtWYvHqLFOp14vLN4TW0Y6pEp3ag8P3neaKzGoSw9PxCL7/Nfji3x+Tje4a5s'
    'MfEC4p2h4+kdNakl2gBW4SWFmnjfdKzqRz+Lm6rXlJ+hGSrkGS5SqGJDiZumFxWaVUyRkbQt5mdC5cHg1JbXq1TQI+aZOqEW5Zgo'
    'bWrVDe0wpsrThbH+5mdlydIVll79eUtZ0+WMitBcni9PJpoUvKNuxpQprPfni1k629nhYlY/X9b0HtoLzgKfNcEz22FOUmhP34RK'
    'erotNuXTxzGozms/8+KsJvlobufVxEpetUWdzT+2sK3xdN7LmebnbZzd71y3VrEYS+edxPbQ2dJQsid68rN0nLce2/oZRud6ps15'
    'B2cUnesZZ51BdK5niHRGyHM94+rXxvhoR5kvUhfO6HiuZ0r+Wrc09ed6BubZrGNkPM94BuivTwfFuHiuJeZz16h4urvEtMsaE8+1'
    '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'
    'VMwmoc8yrQvY/MXvBw0NLK6RnoyQiGUeWTiMFwkPokwEz0SeiTxnWG4Ixxb6zybWYjlhETGSC9jvJiJqkStjk3hoQWi7IX8JD7Xk'
    'EXYCTEWUYafNkkfJQvNls43rIiRzO6doVqRTlPm8LMqSNyKZTrk2ypOy5I3Qw02YYpR5nxFpQ4oalxfYiH9iq8SzSv4WNqL/Tv6Z'
    '/qmBiUX4k6SVQUlTlf1Pufy+ZGaIZE6hDcyv8aLUzZ9smUHSqyVwfHOK75dPfGtz+BI1UI14OUGowp7QyPd5lswk1kiyfJLQZYq+'
    'V4mXHPxYyPIpylHl/BGvo7J8Ur8d/FhIv6n1NCy6wmN8hVlXrsqvYCXtkmFkp/eMNJwEP4YhNBnoNpuDH4sCHqdkWEd+OZ+0p1wS'
    '6W8Eu8URizyeoxl5cEU6JrokciXJD1+IkNx6AoVO6skipBJ3VYRaIkVAFcMIK6MNyMj609K28E6JPWkJK/Qq1W+VU2rxxud/XBDO'
    'hyO5HW1RCPeOm+GAnrXfN2lduhTRFnFtXP3FJUsnnIGEhhuQxJ6ieOim9E7PJTSSr9IUFaUkwnE5LIlVKKC4TpJHnVW2kkWx2IGt'
    'm34jqSs3EYyIxUo3AXyqNseazHVtG3G3T/rbfJOmho+bIJbaxL+Ib70aKFDfKZY6jrD2unbexoQx+jjxoORbkOYvUxmm8mY5bM0u'
    'HBBSbX08JP07n8965xOCDNDXUqEp1fWcEuJ6mFoB+ipkW3Smj9ZAEuggjFpOBtqUfk10TDwTHBsuhQJDXszt0rdv/jTCgyxIhKem'
    'i0su8dlSOtBTInHLUuD0xqedxTmUydKRITK6WUqmGIoCgY1VRkRHZmscsErMy1Yx6ivJThvGaw3HNN6b8jEvbQJ6Jvl/BkfajmtM'
    'gYk4mw7O7ePU6tX+K7NSvP1X9eO/MtPmN/9V/fivoKT47r9yug/7r+oP/iuTdGzgXImYpCQTWku3vvPwk+veP/bK9eZ8nEHpW3qN'
    '/SbOuE6l/M7SsX8g39i63jQf+wfyDq1zH3IPDb1PGpGt6yUHUVbXTxoSTu+XXMR+uHr9cn2+05zYj1evX89JPK7fr33vV/ez+3G9'
    '+/kA6zeBDUQ3qUxsWMGUeazHExghXqIKj4ZWMEhYcqPcKNNepr0DrN+6qpwpK9DlqGkLq0LF1LrIkFahtVhEvlUcPipLniB828TK'
    'Qtvp9VTlRBltYEiec63AsRZJNkSVoP45V5WRpyNPQ56GvA15GvJU5IGkJuCaW9cKrafK1k6QpzhRe5W15kDTyFPGieVcui6sGWf1'
    'A1MvpB1waHUQ/cXr422qxLtV11c9eVVHMC4YJowaBlFTnzWJ3NTjTQ/c9Xxdj9vVelfrQ60PSTbU+lDrU61PtT7V+lTrS60vtb7U'
    '+lLrS60vtb7V+iZPtVrfvKpExyR6JvHqEkMv82ozrzrz6t2vhaFR8n1VP746kFw3R6ezujiHX0CHF++/OCeJbjrZapQVLjlbTXIK'
    'QKh3S7UZWJ6sCqHfcraD6ZrumrP8VyeZNSAnajaMhIvyoNygTAhX8CQDaiIIQ0jJuA4kjAMwdAI8lnOKVNwA6gPixQWgD0eja6pr'
    'imuMQtsOMl+vjNMF2CkBflEGCrTnt7wwyyrzVZagUXrlhVlWuW+s8Xoj5fY7FU25SXwdUFyqU2IQ+fgBQdY3PrKaIqFawmYJmyVs'
    '/U2jEKhKS9gtYbeE3RJ2Szj8nWEJhyUclnD4KW5en2nynDld46dY/s4qb4KdT26N+hrZG4ZiDQEPlmwepMWY90ivd8STVtOk+1Bc'
    'kJaKS4YTquJAFGfpr4TwBuljJI+E+vKrRCb4RytReE8h6uVcM7X69CkRKRNOg68Cwji0Bf1MMAPtKJGN9ujJMBzVuGYalgA5stA6'
    'Gy1EKGSqzZKULLZZJiwy3DrzsIIsoAghTNmZoRRbkkHfC3OfX8FS4nlNNxNv/vTqGu+S+zi+Eh3BsImOvvkrY6BkD5cYJNlDJd5F'
    '5o382EBxWA7aeGEnAsCl8kWSDMpT5YrNxI7FyueVzxufN2KmT1RUVSqES8gbew+fdz7v2JDCxI3t8JQHbDKDzweUqcPsNTzPBIA2'
    'eZ7J8yyeZyHvQt6FvNs2IOTZyLOHCXtN1pouhW9zjbnB0nYNUuXbzQbGfbhe3dPZXf2ZrMUvw72d3d3Z/Z3d4eEoWcB3VdMsYbOE'
    'zjgSMVfVecd0FrWE3RJ2S9gt4bCE5gY6GwQ1lnBawmkJpyWclnBZwpVd011zsz5YwmUJTSSkU3gDjaSa9Um7ouGZPF7TdM00FspD'
    'OtsZnj2ob/6QwlOImo6zODU3a0vy1Lipf5trDH+syzXrU5PNIxjglu81fOdnQ7bdpmHxFifNTzXpp4+MsCljusbmADFFoBEISYlB'
    'AQY/p3poy0Tf/Y098I09xbT13IzvN8+L7PDnlMr5twjvaRWqQZkcDvTlZDvjMgOZmbD7vNgvoM/kh92JdLoJErvhhMMn5eED6HBi'
    'xUuXPJ18cdrXP+95er5T9PRq9kKTTEeNwYzbEm5LuE3huC3hvnSa2yQgJtRMlxbElJoJCYvP+wrDi5rpmuEjf/aZP7vGp/6ChMWI'
    'qGLgavHJvxgtXOp2jSX0qbU0S+hzbfFBt/jkWwxhLT4bF7vOi0/PxTBWjcyosYQ+gRdDWV81DFF91L7V6Dsywf/XmOCPLvhbJnhm'
    'Q+Xafij7c9NBTfAR22Dp3N8V68tSNE8qOLU9E0AaNNtIMB3tm4qnfbvZH6Ksn3BqzJfGdKn1TfdcL90zHYbNAhOGzS7GxHnKeMa8'
    'OGl6hWZif+hePTw8OvaLYqHXS73Q5wtX0YZwHN+f0tMu9fdNN0FYdQccOw9Sbx5i5xfA8CZZcRIWwijrvklYDNq6pK9IOZF68BSX'
    'NJanHDz1QKBLOutkW05vm1/Jt45dB3kvqS3ymPTW6ORLios8dbw5xhY83ibN3T+jCUnu4hCbSjKWd9mfuz5CIBb2EeAUDrnBYxkh'
    'Nwrcafu3OMqac8WL4l2IiBHdqww5Q9NDhW8Md+KHI/35FGvczqQIyD+QynElk0AmlUBYsNKLvoTU4xGMVLX1akGqt8znP/Wg/75D'
    'F9SxhH0r+/MEamQBCOnj0qt1zBSB+RD0o4smBZiKjHzzS6ADE91necgMgYwBA34yhZ2cMBacSY0zbzIHqSJfA9RQ+4cl/ZORHQ5z'
    'wUaqHOWntOuHFxz+sMvbnTGmEW+3SIhbYTOJnQ+e8MgwlH7go4Zp5vJV8wpuRmyzr5jvuuLm6C+2Fdve4aIosFBctpVcPnzbFXdJ'
    '/7CthJzO+F3f/N3tw77ijOH1xf+9YBNZ/ZNx3Owr5hOvb37x/GFfMR95ffOTlw/7ivnM65vfvH7YV5xRvb740Vv7sK84I3t98atf'
    'thXH75mNJX/42uvL91HMxlI+fO/1zf9eP+wr/c22Yv749mFfMd98/fDP737JV6Cqr5e4HiKbNS/Ffb2E95DYzHWp8eslyofAxiT6'
    'ULFIPshrIN/v/ZKvdNEr1kva39S6Cf3zJV+B+r9+EgGUS77SZXmtnwQCXqvt2dJgou95NXp2+iV20PmOJI/IZrOP/JpNP9LekeRi'
    'P1m/EUkegdUfCpJXJPl4R0ynd2B1f4dcR5sfHpJXmHY0+mEieYV2z1fQd9gWXmQkn0DxWKNfOXBfweX7FXYe4SA3IH29QtVFRvKK'
    'Yx/fotyzwOeOgc8Kes+QhmSFxNNpt7gv2iG/iudDaYn/jbXE8ZvUsmG2CoTZAdzE3a06MQrhQyuBkCux3p/kleFgC768eKSs+JBf'
    'LZXxs2Syi2gnksme6+IaxBSlOiq4QnoYN8M3CxNnicgVI9FvQJ+V2Gzyf6gAO2xxwbRYHXbHSW9xHTiR23g7lzvOZl9JQQodVyy0'
    'hQWSQOuFQ/5N1bHg8RCPoX+sEtNwnMtfQqMe/31Ma6sxZj8KTXUwkWRdDKaec7g6ithJZ3ps30dJBDITqbdICepUoICMNPSSCXGK'
    'B2OAlAsBBgkUvxzxaZvaP5uJH5LbIKlkN1rOWllITyGaXFc0qzyuMMtvIkvnIv/LnNaYJPpUdVOTMYaS+buhFs6h6B5ShNDXpb3X'
    'GKgRwf510JUNQptxs6MU5f05CXn1TmLsJi0jJzXr6fZG3pWwDjZQLzG2Wyx+6fI7HDTOr0rOFjGZoZOFMfUrvNsHRHwA1l8Bh21J'
    '0+W4sMP+ft5ziaXsWGiOyTf+Plg/SgAdciy1NTJ6l/BF13CqlxBZyVNLgAZqJAgskQJPatlhlYgRNaLFEZvEOJjKs87ViKw83RgB'
    'OSPY+VaMsXnifc4UH0oOd+IbAl3ezmL2yDmDwyjFz84ONigLZCUCjyz69RGLQ3Cwn/cWAGWQSVm64VwsGqF7K8ThQpQm4NCiDGNT'
    'QezC7quBeteBKDaygheFhwacZMV2B9O4isqJ3PGXkFak4zVp+nQQjHkoGMmgVIRTPsUJr+vQpxNO2CG36aShqYC0hRhTny4amhJy'
    'I8YCpAalwsKbmmhpsyElBNl8np0IPRUqmismFdskDfk6dakYVJjGofCNWlyBH/iyQlRi7NrNvw7fTDMtLqG52b0dqX1Jg0MForvH'
    'M6lKsvv8oDcneHtVDB7O/X4+UYWbnYjuvj+L9BzeRZbU3emYJVXwcNvNLkTfbnZL9OKXkOn1iOIpML6qYruCb/g1HG1eFeYjdUru'
    '4nBfer34NRyj1nRiYQUEJyrcbO23Yl9yTVv2HEM8x7eKz5/M9XsQluqbkb7dONi4VQfTONS5VWeWBYrRgJ60rai0VjE/CVQVJgNM'
    'Ak6e2ww1MfTEIeLOi2OoSv7BZOG8OP0VuPIyedy8OO0HaIyhNIbW1B9MLIbilB9MMuO7yeZid15WnWvn6T9hgGyvze0ds1lvcF59'
    'GY6KbboXVOQkRFrv6jbfbX2FiNvm8kmvZqvMKz+xbbrNEtqy87I6jx+tziP9ZHXuP1mdb801q2MFf9X0lxXzvzWQ+FkJfsuKCZKv'
    'GtFXvpfLD/UDYq4FgnDvH3jGNhGPiwDdQehhIyZNnZ6+CK69GYS+FVX62YEBv5gprdsPZX/eiZGbJh0zHVme75tePK0AyXSWkVYu'
    'U8KlijBRAag8swLotRBUZqseUXPpRRnRv+5AdFCdXzKfexCqg/qXV5hCZutr4yuUv9kA+8dGSGLp7zbE/rExWthvNsh+J3xHnu82'
    'zP5lN8dAnu82UBJNnzLyfLeh9kumu8YrAs/l805S+fEtFf40G3/Ie+umlt6OEuymlr4MEt3U0ttRgg4XvDwU/bOmbDph97dh+CPk'
    'xnJuW/3GGYU/5qeROrBRdbIzNhiEXfbnDfhwA0/cABg3EMdiuuKKRh14VIGWz2XqwhTjN2VwD6P9BtUvhL/Q/kL+7/2miIuoCfIV'
    'L2nskblUlwmfki45Q7dUubLAX1qmLbqmQhLGQnq/MOPVF70TjYT57l3+fP83Eb1no+/krTedlMv+3Oa8hvnR6f0E3f2YwxrmS5ur'
    'mqybJFUM8zQWoOnUo/opUHtxYBFSOg438V8WcazJj2IZUUQGCmIXfVbWCsSAjkSkMmEUpzwSJ+DNeVQvcW02TSQWjVeSaCU62tsp'
    'o6MU1g7nXwpLyyZhU1hJPhmbrsGlOpqCyojnifXk2+MiC4yq3aS5Sln1a5y4Ik9VCFe2k1b9amYm2a7xKahJxr3ejej7tKCJm/dE'
    'X8YTQOMa4ChZvbGwv5JX/ZrNYhwYl1f6ql85KGntytgbdLn9oc6Z37pDRhhhFr6BLUHCArQVWBDYZ5HqBii0qotZviETAFDKbsS+'
    '1tQCYNSuFoCqdrUw1EJXC8Bch4CRQy0MASOByE61PgWanGp9qYUlyONS60utb+Eht1rfan0DhkxqfgODBfYbGUSJiVUZbCaw4exR'
    'ZthqBptZ3M90NNDVYJjbWKihZlV53OPTqK/rSCBmyWCZNqtug59/XN59IyeMu1AZeDMvLjJpgt1YMJ+qzEsHM1o8JMCURibPjecB'
    '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'
    '5fOFPeOxNVxGMduZhf/bf/v/Aa/dZ7Q=';
  static const String _wilcom_e3 =
    'eNrM/VnP9MiWpIf+l7x+s0Cf3etO56g1z61zdCEIwlZpSyqgutSoLk1o9H8X17LHGIzcmQVBNxKQ+THI4Bt0kj6swZbZv/7lb//7'
    'X/76l//tb//ub/7nf/Hf/rn98vPL3//pX/z53/qH++A/894/+3vv/cM//t0vf/0//Onv/tWff3750z/86b/72795dv/+T//4t//r'
    'n//5P/7tP/7N//TLX//jP/wv97G/+dO//Pd++es6xl9dP7/8q3/5p7/583/1y1+XMv5q/fzyd3/+x3/88z/883/5y1837f/t3//5'
    'PrnN81f755d/8bd//8//5k9/9+df/vr6qz7u/T/97+zXv7p3/8e/+z/+5f/0r37563/9y78V//xv9+Fef365v/6v//Uv/3i39r+/'
    'G3v/9H+9fn6dP2X+/Lp/6v1vudjJ463//Hp+7p+/P4/682sdP+P8/HofmPdJs/+s6+fX1X/OvbfGz91wbePvYju3tuv+fuyfstv9'
    'x/cV9v0jtf2U+LvxU+PP7gvXNnK3rrxSLXGpeW/Lfa17e91/vdf9V3n6/eHe+bXU+3fXfWbp8eE+tcxzX/k+Ny5Txn1yve4PPX61'
    '3RdvcfFxf6hxR73/lPjhev95NCdOyeaVxhfX/bvxTOpV77+54qtyf4hrn/i5aM39HMr9fH8t8bv3/3ez4tpxTlw7Lpkf4s/zw1X0'
    'YVe2R7cSTSj3Teely7yf3RXf7P5qg1vlZuZvnPtl9GjJ/W7isve141WVtvPNlfth9vj+un7a/f0uP3cLf531J55Cv++150PP177V'
    'D6Ktg504/t/8m5/vvlPju/LTSrTjJx7E/fDY83d3o1vLS99vIlqy1s+8TznnZ+Y9378d7b2f3o57vzvViXbueAbVjz9+M55ozY4T'
    'j7/73eWH5fdLJ6zlPhL3X+/vS3bs6DnZPe7HFE8lH1HJZxe/07Mx0bvi6vHy533/Z93dLsZD1R/fj7aW+2/vG8nO3Ka+v9sVHSdu'
    'PH8gem1Tp77isdyn3z/162jq+zEmtn6+rHw7903OuHCMjpHP4f6THq28L6Mue8XAygdx/1WJR9PcK+L9NR5EjI4aF6zRTe4f3tld'
    '7jOyRfse2vkUmp5vucdldpT7N07RM4hHGVegifFi7wcQryvuv+Xt33/2a4uGRIPyL9bzzuOOy0+PE8vP/d+vS+efqgmjqZvHMIq+'
    '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'
    's0KGH/2jkLHcsF1fGhoUARwyDQ9Jhlgq3PS7Dx2YFxVbv2jYOT5AkZpj7TH168B2OL6BZWs+4II3Gha2dB5wJD0MxAT5mL0jHIpj'
    'kkmHD4+1lR1elDTl5QPwiHb0chMptJiFO3wEx0wnPoCT9JS6vY9wjpbu//BJuc0/9Ink8CjRYveHPb6rSt5Acq/U2+MT/R6VxXxR'
    'WYwPlcWTnPsUtwkf0hUBprBsE8i7rAsHAr5IK/Wo0nFrikLIbcAr04BjGIGIHiey5gs9dbCICPdAJv2rq/GtJrxfcgcbBPShMA4p'
    '1vrSu2oAFYWAc1RLyMfxBv2NYtnQ9WKoseAKRUyaR8JV2JAzLiz62V6CFG0+2nkNCVoZO+03NXo6L/psbn+TnqMmJbqhSfm//cb+'
    'G7/RcVtioa1QNGBVHYsFbldz2jDL0TKcG2s2saaHic4xwWJ5BjCqp4E42eY4rCTLJPUDW/FYvCRVXBVK5xKAs9FomKR+hZ06RMGK'
    'iKu3EijZBQYyPS5dyBZOkXepbktx0iFspOlICKx2MBJTFAt7wZiAFGNFfKTilFf723rIS8+e3NjHGSei8OSo2jt7Nd95LSW5nPJy'
    'Bqx/58fWV/YsExKv3Fpz5m3jfdfv3Er9zq3sx/v+ndxKO191Yr/NrVyP9/17uZXyeN+/l1upj/f9e7mV9njfv5db6Y/3/f9obqX/'
    'k7mV8U/mVuYf5VbwAr671/XHhWY0Rppy/1S+c/xfy3ee/2v5zvZ/I99Z/ijfua7/F+Q733mq8Z3FOl85rifltX/70gbcmCLIk8d4'
    'ZB2k9BvSc5XcgqZ15VSG8HsNkeQfaSQlDgBI4kCHGe/vQA/bsekbcKdjvXDP0ACrERw2XqKiE2JwWHIZUq9zSWAmF0OE0huKtx3d'
    'mS7E1vj4Cl34QIvYpHssXpoBanxqTY4nEK7DVF3EpM54JSNlruSpQi+58wXK5T5zieZTMDT5UxuHZkvsYEOhdTdpFgSFBLwNGOUZ'
    'ZtxxWd6jewRJ/4WSeHaH8yqMKwMV+gqlFlUYRZjw6BENvqJNJKOhTH0ATXQQVwfq1Q5r8jm/kSOwRz4uY3sQ0nsSboUQ4ED2Sp73'
    'bdlPANciHwp6b8vSV0KM05Z9+rpLxIgpS594s/vxrvG2jTZiV5t3Fpb9tiy9BE0Fe39p4ZEjPcMYpoJm3YUNdUnGKi37gd7qcXDn'
    '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'
    'PqTgGd+Dm155eWsQsL/YJ+1s3skGv2zE9XJ/wjdLYzqt6TSn055BewbtGbTHJOUDvemw5GJ/0p5JeybtnbR30Z5FexbtXbR3mxaT'
    '9mzau2nvoT2H9pzx8Gpqn/ac4+fZ/ED9BC8/wmt/UvP1oZXUkeUjTt9Xv7VqtY86fQSrtrTH8rUtvO2FRXBI9vK0BU1LsypwoHis'
    'I53Gf87p5oTv3e/b5zSf04aPPOdcPmKliupz6vCR4iM+p0zjsKeP+JzCQ5BuOcskR6qP+GE+uuXHD/M4Sn38UrZf03769dPR3fO3'
    'h8L22Fjjo4jOEb+U5dc0uQvpnzeqAQeZSh0ZfrnDLfS7KH4X6XQPvO9q6k2OuIV+F8XvovhdZKxLR3wXfhfZbVQWfPB2qrE6FrW4'
    'jyhE8p8+WLz1T3CzQm/u8jnqVD7fBdxDS4MIp6qwTcm/qoLFBjMknGhac01R9iOmEOWRNFs7VGnSn0UaBqLexirUKN10/WRbVsjN'
    'KVmLa2irid9jIFyimJz0YMpHD6a9kpGTWonFIr8pc6AOMQMjV7UejNVfGoaRShIqN6PU+zHCzcnoCyi28iHbPM3Rr2q3kDVuvj7E'
    'UKrdsUbxX1RI38V1XX4joPN6fjxPRh5gqK7YcIbONbtmfHsTXcucAbEXoqUb4t8O7XXc4aPRoUB8huabI+CTKSSFDh4tixwQF4oT'
    'j5Rnht3H+OjXGB2xsEOpkZWFLUs9K8ahu1kftqamWI94iTVfN9UAdYVEAdru8apnsqz3gojOUYmlSH7nHQ2olKNUM3tPlG4aYV2V'
    '/L6Iw2dsp6Ev8sgSZh9K379/sWZdrgwm8KA+tCygcqhrOTg4Uge6QHZG3xD1eryKbMZxiHVugzUPfSijvM38mpNKQWXFjS2NCHYa'
    'JUO9NMY2eWUFF+m9D83xUukZ81aS1SfpfKOItqaoVWRyAZKJ/PBui1Rv843DStOlLZQpCRX27YzAEGNX8VTK3j8lkMHvrzREBl9i'
    'KCH2MpGb6DgpiyrrjBO6PP9Rg2we09dbm/L4DZkcJYt3MnbUrF5SLXO6rV7yCJ/6nDqtVbKtXmLtlATwZHWfpaZUZndZWHNaavOg'
    'QlXGR4a3lLdQr//4S70ET3V3q5dU1EsO6iXnN+ol861eMvXT1+KxddRMrF5SUDPpDFghdRLdhyFhzZxOZdV+V2dUiWgW2MTClli4'
    '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';
  static const String _wilcom_e4 =
    'eNrMvVnvLEt23fdd7nORiHnoN9mWLc8DPTwIgtGm2hYBiiaotmWD0Hd3xV6/FZV17rlkCzAMP5xTlVH1r4zMjGEPa6/197/81b/8'
    '5Xe//Nu/+uu//N//9f/8h/bL65e/+f2//sM/+bt34z/10T/9Gx/93R//+pff/a+//+t/84fXL7//u9//L3/1l/fwb37/x7/6P//w'
    'F3/8qz/+5b/65Xd//Lv/4932l7//23/2y+9KH3+eXr/8m7/9/V/+4X/65Xe51j8vr1/++g9//OMf/u4v/vaX39X+5+t9/Fd/84f3'
    'l+vM59N//Vd/8xd/+fu//sMvv0t/3vr7+Pf/F8flz9+H/9tf/99/+6/+zS+/+/tf/sn579+ek7z/6v3xP//7X/747u2/fHf2/dP/'
    'fL3+LM/X+/8S/9fH+3f7fLes83/f5/+Vz/85lfi4tHh5nz3X9+sYr5Lfr6u/6vu4pPpq72+XvF+jv19rfq32fm35lVO8ma9cxnmz'
    'Xzm+elrG4jvrtNTyKvHl96+cf392js5Pvc/zPl/dnLg19aS8/0XP9Obd03jz7ni8vi8jXt+XqS+cPy2vP3sfvq85XlpceLy+Lz1e'
    'R9Lr+ZX4/PxsvDknKoVT53Nv3pda0nmz6ivvc4q93teSziW8L2q8v1zetym3c4veV39+4v3m/Z3U1bLOLSnpNc7V5vTq50R7vs5f'
    '5HcXatdpajrnfV9APAtek16XXoZe+NL5zvtv3+dM8f953CVeeo2X2eLl3evzks9tiKudca73ddRzqbnE8z2njK69Xyevcb3not73'
    'VW+q3/TJm0l3z31Rv89j1Zvz57nTkirfOW+m38TvnDfxy+dN5k2c/P0anXm/9qrX6tepX3fnfdx5jVO8XzevOftN9ZvuN3PzZu9n'
    'l8+buGW18ea01HjT9GbzOqte37MyXmvxF99/GU+ptBgIGmAxYN/HnQE3OF4cb76vLhRuaAzx5lvc3z8dFz3ff3zGQJ7ny0mTisE6'
    'ddNjaM4zIvO5+/nMyfdY6edNebe0xLwtjNqctlrOHTlfmXGcXvqR8uox8turx2k0fMt7IrUzl8/Ia3qNMdZTLDTvIR+j/P1ng5GX'
    '4haOmIzn4D0Rzm3RQY2D9/Q6y8pgFP9JA/1rgDNm3nOmLc32wfHkeDcd57iN74a4D9ES13NaNOLfLbPQspZaYkWLRURDf+kpnBOf'
    'teF0RM/wLE9f42n7WZ6G82Z72kRDpyG5IakhDRrOm2jIbsjRcJ57NMSbaChu0OhS50/DeRMN1Q1VDZOOxZvN+FFDoyG5QR07S7ca'
    'xqAhu4GOdXes07HujnU61tyxRseaO9boWHXHKh2rzQ10rLpjlY4Vd710GtyxQseyO5bpenbHMh1L7lii68kdS+rYpl9bHd/0aqtT'
    'mz4tdXrRo6UOLfqz1J3JjZzqzKQvU10Z9GSoI4N+DHWj042uE3VO1NWNTje67kzjRE0napyoqRuVm1J1osqJqk5UPHI9gt4vWxNy'
    'PKfn+3vn7o4wRV5nY35P/LM7n+n5/mbM6tgG0+v07r2YjHg5B1sH+xUrVBy8V6NzsHSwzsG7R+fg/YMpFtc4GOfgfUXn4H1BKXbO'
    'OIifPovMOYif7jrp+yalMBDiIH566KQjfnqoO+8bn2LNPwczfnqqOzN+eumkK65nqTsrfnrrpCt+eqs7O64nJ320p464Cyl+/SxM'
    'Ohw6VKcyd8x3Kcc5cqkcbh2qa1n3LdfC4dKhuperTsT9yu/ncR5M86fvNew8k6Ix0eIJnkmsw/46g/19j2Jvfd/SMGren279UWxT'
    '+dXi8b735HM4tFe8h2nOMoVi9L1/JOzP98SImT/ORn1GQHrJxFsxmvLWoD3Lcay2m+X9bIJVe1GM9feDCav0fedirTlW39MUW9qj'
    'yvve9SE7NMbVe+SGffCer3XLyhtxnvKSsdc18U4/pmy+wZYb2+r7fsY8fU+Jc55jDcS+e/p1JkKVnXU2j/M7x/adU/0cUzZzmJnv'
    'ZUf7dZW9/e73DCu7v8Kkfi9P8b13J3bSBn/WlNi74/s9lpzyvhk7vq+V6fgPZ3D92bFzw0Q4s1W2+dKSVnrTqne2Jr3pXethtOTq'
    'li4TN0yst/fzymHan5az70VLPJNomW6ZtFR/J2yIaPF3aqOlFc5Vl1sGLS3Tn7jtp8+tcxV9cF1t0XIeYXl/Mbabc+k5nJn3zTnj'
    'Mu5W7GalnT/fGhex4cmbKTahth5B7HThCpxtM4yqMPTTxuN5D/mwGI4XkXcMjIUploastHLm2jFFStjIW37SGah/djb0Es/iLKKr'
    'aTyFRxJW2oqZcGwEW3LnWZ8xefqtGxVb//vMJZ7OueQwDdeSdRKXE/bCwtyNzsdmtqocqZI6RsZ7qBWZenQsrM/YGN6/cb73bjm2'
    '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'
    'ONbpMVmnfiA7NfsBL3ROe94smwvLI+J27Xb20/3/twZL475mxxJEXAHxeBQrRX56mYp8uuVwm4ucvJizyC2Zlk1DaFEVoYWzIIJx'
    'XJdPrJ48hlNS7CxeOz0O76WiMvV5tt+P1HfS0Z4IxV4m1FaemJEKZDYwIzQsjgd0qv2J9nIZAVV8l0WmIN3TyK27MMxFbYkxclg7'
    'YYNosHwqYbJe5lZtIHzM49ahnjQ/a8ciGmYZhcVqwPoZr0eDwSyl9GfSn0l/lllO6c+iP4v+bLOkEiTd9GfTn01/txFJ6ZKxmlcr'
    'mbA10ScSJt0Jk0Ut6S0qPS3lksOac6uYQLbQNxIm3QmT5YRJd8JkOWFiXp5kd6B1ewEO80WL0xr9EuO6h91X0X0Vwz0c7uHwVQxf'
    'xfR3pr8zfRXTV7F8FctXsXwVqz24ydTiq9iX4K89W07eQ3PCb9pdA9yy7wKavAZ0JB0aa3WEgNfyquBQfyA1TgSlJMvjYQBKk6EO'
    'txS3QL1WinUbAl+DJUhLpeWsScVhxIU9SEtzS3JLouWIPERLcg9PWURBhkJVYpseRl3dwjykhR7GliPpQNeWreoWehhUN9Eyl1ua'
    'W+jhsRbVMrZbulu6W7Jb3MPuHvbxqWyjxT1s7uGtfmvuYXMPq3tY3cPqHlb3sLiHxT0s7mFxD0tyC/dZMmBfJfnZV5Hzp0i/3Azn'
    'GhYpzA8Svr2uvJiOLTfGFSw6t+jbomuLni06tujXpFuTXk06NenToEuDHg06NOhPpz+d/nT60+lPoz+N/jRuZ+NuNvrT6E+lv5X+'
    'Vj6vHq+eLJ4rHqy+h76FU9vgkmRI1RbXNPcmAmhW2fOj/vypUtAIkFSOrcpHwvU/Ja7wnra/EVaIkIZL4cPV5OhXn0UASVmUKYtx'
    'Oqbx4JXuk/o2fS0mKGCMT/UtMg2ICylCP7VuTRmsU1HfqSE8b9JzxTdG+aAXc1AkmflQhIdSHAAQqSCDCUxSI+YAMrJRlzf2rc9T'
    'zKIQy9i3v1/XYUr3ReAb9YIIN1tJ4MGvrb/quhk1fXlj0b2XaAADwRYHXQcjDpYO9no50rw/ubXGYdfh5HDFYZjOpGCoS7xaqH4e'
    'JoSbFLFPc99SmHslNS2SSTRPQZd5w0q+oP5z9zJ93Mth97I/3cv+dC/7073sT/dSZKsf0N3HvRQp/wd093EvewQqP6C7j3upEPoH'
    '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'
    '/P/8P/8vmvr1rw==';
}

class _ShapedGlyphToken {
  final String shaped;
  final String dotForm; // Ink/Stitch Arabic glyph name e.g. ط.init, ا.fina, لا.isol
  final String base;
  final bool connectsLeft;
  final bool connectsRight;
  final bool isSpace;

  const _ShapedGlyphToken({
    required this.shaped,
    this.dotForm = '',
    required this.base,
    this.connectsLeft = false,
    this.connectsRight = false,
    this.isSpace = false,
  });
}

/// مشكّل الحروف العربية السياقي (منفصل / أول / وسط / آخر + لام ألف المتصلة والمنفصلة)
class ArabicShaper {
  // [isolated, final, initial, medial] — empty string means cannot connect left
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
    0x0640: ['\u0640', '\u0640', '\u0640', '\u0640'], // ـ (تطويل)
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

  static List<_ShapedGlyphToken> shapeLine(String line, {required bool isRtl}) {
    final List<int> cps = line.runes.where((cp) => !_isTashkeel(cp)).toList();
    final List<_ShapedGlyphToken> out = [];

    int i = 0;
    while (i < cps.length) {
      final int cp = cps[i];
      if (cp == 0x20 || cp == 0x09) {
        out.add(const _ShapedGlyphToken(shaped: ' ', base: ' ', isSpace: true));
        i++;
        continue;
      }

      if (!_isArabicLetter(cp)) {
        final s = String.fromCharCode(cp);
        out.add(_ShapedGlyphToken(shaped: s, base: s));
        i++;
        continue;
      }

      final bool prevConn = i > 0 && _canConnectLeft(cps[i - 1]);

      // Lam-Alef ligature check (يدعم صيغة Ink/Stitch مثل لا.isol و لا.fina)
      if (cp == 0x0644 && i + 1 < cps.length && _lamAlef.containsKey(cps[i + 1])) {
        final lig = _lamAlef[cps[i + 1]]!;
        final String shaped = prevConn ? lig[1] : lig[0];
        final String baseLig = 'ل${String.fromCharCode(cps[i + 1])}';
        final String dotLig = '$baseLig.${prevConn ? 'fina' : 'isol'}';
        out.add(_ShapedGlyphToken(
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
      out.add(_ShapedGlyphToken(
        shaped: shaped,
        dotForm: '$baseChar.$suffix',
        base: baseChar,
        connectsLeft: leftConn,
        connectsRight: rightConn,
      ));
      i++;
    }

    // في الأسطر العربية، عكس المقاطع الإنجليزية أو الأرقام المدمجة لتُقرأ من اليسار لليمين بشكل صحيح
    if (isRtl) {
      int k = 0;
      while (k < out.length) {
        final cp = out[k].base.isNotEmpty ? out[k].base.codeUnitAt(0) : 0;
        final bool isLtrRun = (cp >= 0x30 && cp <= 0x39) || (cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A);
        if (!isLtrRun) {
          k++;
          continue;
        }
        int end = k + 1;
        while (end < out.length) {
          final ecp = out[end].base.isNotEmpty ? out[end].base.codeUnitAt(0) : 0;
          final bool ok = (ecp >= 0x30 && ecp <= 0x39) ||
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

/// محرك توليد غرز تطريز حقيقية من مكتبات Ink/Stitch و StitchFoundry (فستون بأعمدة ورنجات + تبطين + تقصير تلقائي)
class InkStitchFontEngine {
  static Future<VectorDesignData?> generate({
    required EmbFontMeta meta,
    required String text,
    double letterHeightCm = 2.5,
    double? targetWidthCm,
    double? targetHeightCm,
    double densityMm = 0.42,
    double extraSpacingMm = 0.0,
    int underlayMode = 1, // 0 = بدون، 1 = درز وسط تلقائي، 2 = حواف + وسط
    int colorArgb = 0xFFFF1744,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final rawJson = await InkStitchFontCatalog.loadRawFontJson(meta);
    if (rawJson == null || rawJson.isEmpty) return null;

    return await Isolate.run(() {
      final raw = _generateSync(
        rawJson: rawJson,
        text: trimmed,
        letterHeightCm: letterHeightCm,
        densityMm: densityMm,
        extraSpacingMm: extraSpacingMm,
        underlayMode: underlayMode,
        colorArgb: colorArgb,
      );
      if (raw == null) return null;
      double sx = 1.0, sy = 1.0;
      if (targetWidthCm != null || targetHeightCm != null) {
        final double curW = (raw.widthMm ?? 0.0) / 10.0;
        final double curH = (raw.heightMm ?? 0.0) / 10.0;
        if (curW > 0.1 && curH > 0.1) {
          sx = targetWidthCm != null ? (targetWidthCm / curW).clamp(0.25, 4.0) : (targetHeightCm! / curH).clamp(0.25, 4.0);
          sy = targetHeightCm != null ? (targetHeightCm / curH).clamp(0.25, 4.0) : sx;
        }
      }
      final bool isWilcomNative = raw.machineType.contains('Wilcom');
      final double dFactor = isWilcomNative ? (0.45 / densityMm.clamp(0.25, 1.0)).clamp(0.5, 2.0) : 1.0;
      if ((sx - 1.0).abs() > 0.015 || (sy - 1.0).abs() > 0.015 || (dFactor - 1.0).abs() > 0.04) {
        return VectorDesignEditor.transform(
          raw,
          scaleX: sx,
          scaleY: sy,
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
    required int underlayMode,
    required int colorArgb,
  }) {
    final Map<String, dynamic> font = jsonDecode(rawJson);
    final Map<String, dynamic> glyphs = (font['glyphs'] as Map<String, dynamic>?) ?? const {};
    if (glyphs.isEmpty) return null;

    final bool fontRtl = font['rtl'] == true;
    final bool textHasAr = ArabicShaper.containsArabic(text);
    final bool isRtl = fontRtl && textHasAr;

    final double capH = ((font['capH'] as num?)?.toDouble() ?? 150.0).clamp(20.0, 2000.0);
    final double targetCapUnits = (letterHeightCm * 100.0).clamp(40.0, 1200.0);
    final double scale = targetCapUnits / capH;

    final double spaceW = ((font['spaceW'] as num?)?.toDouble() ?? (capH * 0.65)) * scale;
    final double baseLetterSp = ((font['letterSp'] as num?)?.toDouble() ?? (capH * 0.11)) * scale;
    final double extraSpUnits = extraSpacingMm * 10.0;
    final double lineH = ((font['lineH'] as num?)?.toDouble() ?? (capH * 1.45)) * scale;
    final double densityUnits = (densityMm * 10.0).clamp(2.5, 10.0);
    final double rawJoinOv = (font['joinOverlap'] as num?)?.toDouble() ?? 2.2;
    final double arabicJoinOverlap = (rawJoinOv * scale).clamp(1.0, 28.0);

    Map<String, dynamic>? lookupGlyph(_ShapedGlyphToken tok) {
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

    final stX = _Float32Buf(8192);
    final stY = _Float32Buf(8192);
    final stMove = _Uint8Buf(8192);
    final stColor = _Uint8Buf(8192);

    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    int jumpCount = 0;
    double curNeedleX = 0.0, curNeedleY = 0.0;
    bool hasNeedle = false;

    void addPt(double ux, double uy, bool isMove) {
      bool actualMove = isMove;
      if (isMove && hasNeedle) {
        final double d = math.sqrt((ux - curNeedleX) * (ux - curNeedleX) + (uy - curNeedleY) * (uy - curNeedleY));
        if (d < 36.0) {
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

      final tokens = ArabicShaper.shapeLine(lineStr, isRtl: isRtl);
      final List<(Map<String, dynamic>?, _ShapedGlyphToken, double)> placed = [];

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
            adv = math.max(gw * 0.4, (metaAdv ?? gw) - arabicJoinOverlap + (extraSpUnits * 0.35));
          } else {
            adv = math.max(gw * 0.4, (metaAdv ?? (gw + baseLetterSp)) + extraSpUnits);
          }
        }
        placed.add((g, tok, adv));
        totalW += adv;
      }

      if (placed.isEmpty) continue;

      final double baselineY = lineIdx * lineH;
      double cursorX = isRtl ? (totalW * 0.5) : (-totalW * 0.5);

      for (int pIdx = 0; pIdx < placed.length; pIdx++) {
        final (g, tok, adv) = placed[pIdx];
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

          // نقطة بداية العنصر التالي (لتحسين اتجاه التطريز وتقليل القفزات)
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
              addPt: addPt,
            );
          }
        }

        cursorX += isRtl ? -adv : adv;
      }
    }

    if (stX.length < 2) return null;

    final bool isWilcomNative = font['nativeStitch'] == true;
    final String fontName = (font['nameEn'] ?? 'Ink/Stitch Satin').toString();
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

  static (double, double)? _elementFirstPt(Map<String, dynamic> el, double ox, double oy, double scale) {
    final List<dynamic>? arr = (el['r1'] ?? el['p']) as List<dynamic>?;
    if (arr == null || arr.length < 2) return null;
    return (ox + (arr[0] as num).toDouble() * scale, oy + (arr[1] as num).toDouble() * scale);
  }

  static (List<double>, List<double>, double) _buildScaledPoly(List<dynamic> flat, double ox, double oy, double scale) {
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

  static (double, double) _samplePoly(List<double> pts, List<double> cum, double total, double u) {
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
    final double x = pts[lo * 2] + (pts[hi * 2] - pts[lo * 2]) * t;
    final double y = pts[lo * 2 + 1] + (pts[hi * 2 + 1] - pts[lo * 2 + 1]) * t;
    return (x, y);
  }

  static void _emitSatinColumn({
    required Map<String, dynamic> el,
    required double ox,
    required double oy,
    required double scale,
    required double densityUnits,
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

    final (p1, c1, len1) = _buildScaledPoly(rawR1, ox, oy, scale);
    final (p2, c2, len2) = _buildScaledPoly(rawR2, ox, oy, scale);
    final double maxLen = math.max(len1, len2);
    if (maxLen < 1.0) return;

    // بناء مقاطع متزامنة عبر الرنجات (Rungs)
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

    // تحديد اتجاه التطريز الأمثل لتقليل القفزات بين أعمدة الحرف
    final s0a = _samplePoly(p1, c1, len1, 0.0);
    final s0b = _samplePoly(p2, c2, len2, 0.0);
    final s1a = _samplePoly(p1, c1, len1, 1.0);
    final s1b = _samplePoly(p2, c2, len2, 1.0);
    final double mid0x = (s0a.$1 + s0b.$1) * 0.5, mid0y = (s0a.$2 + s0b.$2) * 0.5;
    final double mid1x = (s1a.$1 + s1b.$1) * 0.5, mid1y = (s1a.$2 + s1b.$2) * 0.5;

    bool satinForward = true;
    if (nextAnchor != null) {
      final d0Next = (mid0x - nextAnchor.$1) * (mid0x - nextAnchor.$1) + (mid0y - nextAnchor.$2) * (mid0y - nextAnchor.$2);
      final d1Next = (mid1x - nextAnchor.$1) * (mid1x - nextAnchor.$1) + (mid1y - nextAnchor.$2) * (mid1y - nextAnchor.$2);
      satinForward = d1Next <= d0Next;
    } else if (hasNeedle && underlayMode == 0) {
      final d0Cur = (mid0x - curNeedleX) * (mid0x - curNeedleX) + (mid0y - curNeedleY) * (mid0y - curNeedleY);
      final d1Cur = (mid1x - curNeedleX) * (mid1x - curNeedleX) + (mid1y - curNeedleY) * (mid1y - curNeedleY);
      satinForward = d0Cur <= d1Cur;
    }

    // دالة مساعدة لأخذ نقطة متزامنة عند t في [0..1]
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

    // 1) التبطين (Underlay) قبل غرز الفستون العلوية
    final int fontUnderlay = (el['u'] as num?)?.toInt() ?? 1;
    final bool doCenterWalk = underlayMode >= 1 && fontUnderlay != 0 && maxLen >= 18.0;
    final bool doContour = underlayMode >= 2 && maxLen >= 25.0;

    if (doCenterWalk) {
      // نمشي بدرز التبطين عكس اتجاه الفستون النهائي بحيث ينتهي التبطين بالضبط عند بداية الفستون بدون أي قفزة!
      final int uSteps = math.max(2, (maxLen / 22.0).ceil());
      final double tStart = satinForward ? 0.94 : 0.06;
      final double tEnd = satinForward ? 0.04 : 0.96;
      for (int k = 0; k <= uSteps; k++) {
        final double t = tStart + (tEnd - tStart) * (k / uSteps);
        final (a, b) = pairAt(t);
        addPt((a.$1 + b.$1) * 0.5, (a.$2 + b.$2) * 0.5, firstStitchOfCol);
        firstStitchOfCol = false;
      }
    }

    if (doContour) {
      // تبطين حواف داخلي (18% للداخل) للأعمدة العريضة
      final int cSteps = math.max(3, (maxLen / 24.0).ceil());
      final double tA = satinForward ? 0.05 : 0.95;
      final double tB = satinForward ? 0.95 : 0.05;
      for (int k = 0; k <= cSteps; k++) {
        final double t = tA + (tB - tA) * (k / cSteps);
        final (a, b) = pairAt(t);
        addPt(a.$1 + (b.$1 - a.$1) * 0.18, a.$2 + (b.$2 - a.$2) * 0.18, firstStitchOfCol);
        firstStitchOfCol = false;
      }
      for (int k = 0; k <= cSteps; k++) {
        final double t = tB + (tA - tB) * (k / cSteps);
        final (a, b) = pairAt(t);
        addPt(b.$1 + (a.$1 - b.$1) * 0.18, b.$2 + (a.$2 - b.$2) * 0.18, false);
      }
    }

    // 2) غرز الفستون العلوية (Top Satin) مع تعويض السحب + تقصير المنحنيات الحادة + تقسيم الغرز الطويلة جداً
    final List<(double, double)> orderedAnchors = satinForward ? anchors : anchors.reversed.toList();
    double? prevAx, prevAy, prevBx, prevBy;
    int stitchRow = 0;

    for (int sIdx = 0; sIdx < orderedAnchors.length - 1; sIdx++) {
      final double u1a = orderedAnchors[sIdx].$1;
      final double u2a = orderedAnchors[sIdx].$2;
      final double u1b = orderedAnchors[sIdx + 1].$1;
      final double u2b = orderedAnchors[sIdx + 1].$2;

      final double segLen1 = (u1b - u1a).abs() * len1;
      final double segLen2 = (u2b - u2a).abs() * len2;
      final double segMax = math.max(segLen1, segLen2);
      if (segMax < 0.3) continue;

      final int steps = math.max(2, (segMax / densityUnits).ceil());
      final int startK = sIdx == 0 ? 0 : 1;

      for (int k = startK; k <= steps; k++) {
        final double frac = k / steps;
        final double u1 = u1a + (u1b - u1a) * frac;
        final double u2 = u2a + (u2b - u2a) * frac;
        final aRaw = _samplePoly(p1, c1, len1, u1);
        final bRaw = _samplePoly(p2, c2, len2, u2);

        double ax = aRaw.$1, ay = aRaw.$2;
        double bx = bRaw.$1, by = bRaw.$2;

        // تعويض شد القماش (Pull Compensation ~0.12 mm لكل طرف)
        final double dx = bx - ax;
        final double dy = by - ay;
        final double width = math.sqrt(dx * dx + dy * dy);
        if (width > 4.0) {
          final double pc = width > 14.0 ? 1.3 : 0.8;
          final double ux = dx / width;
          final double uy = dy / width;
          ax -= ux * pc;
          ay -= uy * pc;
          bx += ux * pc;
          by += uy * pc;
        }

        // تقصير الغرز الداخلية تلقائياً في اللفات الحادة (Auto Shortening)
        double emitAx = ax, emitAy = ay, emitBx = bx, emitBy = by;
        if (prevAx != null && prevAy != null && prevBx != null && prevBy != null && (stitchRow & 1) == 1) {
          final double dA = math.sqrt((ax - prevAx) * (ax - prevAx) + (ay - prevAy) * (ay - prevAy));
          final double dB = math.sqrt((bx - prevBx) * (bx - prevBx) + (by - prevBy) * (by - prevBy));
          if (dA < 3.4 && dB > 4.2 && width > 10.0) {
            emitAx = ax + (bx - ax) * 0.28;
            emitAy = ay + (by - ay) * 0.28;
          } else if (dB < 3.4 && dA > 4.2 && width > 10.0) {
            emitBx = bx + (ax - bx) * 0.28;
            emitBy = by + (ay - by) * 0.28;
          }
        }

        // تقسيم الغرز الطويلة جداً (> 9.5 مم) تلقائياً لمنع الشد أو التنتيش (Auto-Split Satin)
        if (width > 95.0) {
          final double splitPos = (stitchRow % 3 == 0) ? 0.35 : ((stitchRow % 3 == 1) ? 0.55 : 0.45);
          final double mx = emitAx + (emitBx - emitAx) * splitPos;
          final double my = emitAy + (emitBy - emitAy) * splitPos;
          addPt(emitAx, emitAy, firstStitchOfCol);
          firstStitchOfCol = false;
          addPt(mx, my, false);
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
    const double stepUnits = 22.0; // 2.2 مم

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

  static void _emitDigitizedRun({
    required Map<String, dynamic> el,
    required double ox,
    required double oy,
    required double scale,
    required void Function(double, double, bool) addPt,
  }) {
    final List<dynamic>? rawP = el['p'] as List<dynamic>?;
    if (rawP == null || rawP.length < 4) return;
    final int n = rawP.length ~/ 2;
    for (int i = 0; i < n; i++) {
      final double px = ox + (rawP[i * 2] as num).toDouble() * scale;
      final double py = oy + (rawP[i * 2 + 1] as num).toDouble() * scale;
      addPt(px, py, i == 0);
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
          final double x = xs[i] + (y - y0) * (xs[j] - xs[i]) / (y1 - y0);
          hits.add(x);
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

// === TARIK_INKSTITCH_FONT_ENGINE_END ===


// === TARIK_WILCOM_OBJECT_EDITOR_START ===

class DesignObject {
  final int id;
  final int colorIndex;
  final List<(int, int)> ranges; // [start, end) indices inside VectorDesignData
  final double minX, maxX, minY, maxY;
  final int stitchCount;

  const DesignObject({
    required this.id,
    required this.colorIndex,
    required this.ranges,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.stitchCount,
  });

  double get centerX => (minX + maxX) * 0.5;
  double get centerY => (minY + maxY) * 0.5;
  double get widthMm => (maxX - minX) / 10.0;
  double get heightMm => (maxY - minY) / 10.0;
}

class DesignObjectTransform {
  final int sourceObjectId;
  double dx; // in 0.1 mm units
  double dy;
  double scaleX;
  double scaleY;
  double rotationDeg;
  bool flipH;
  bool flipV;
  bool deleted;

  DesignObjectTransform({
    required this.sourceObjectId,
    this.dx = 0.0,
    this.dy = 0.0,
    this.scaleX = 1.0,
    this.scaleY = 1.0,
    this.rotationDeg = 0.0,
    this.flipH = false,
    this.flipV = false,
    this.deleted = false,
  });

  DesignObjectTransform copyWith({
    double? dx,
    double? dy,
    double? scaleX,
    double? scaleY,
    double? rotationDeg,
    bool? flipH,
    bool? flipV,
    bool? deleted,
  }) {
    return DesignObjectTransform(
      sourceObjectId: sourceObjectId,
      dx: dx ?? this.dx,
      dy: dy ?? this.dy,
      scaleX: scaleX ?? this.scaleX,
      scaleY: scaleY ?? this.scaleY,
      rotationDeg: rotationDeg ?? this.rotationDeg,
      flipH: flipH ?? this.flipH,
      flipV: flipV ?? this.flipV,
      deleted: deleted ?? this.deleted,
    );
  }

  /// حساب الصندوق المحيط للعنصر بعد تطبيق التحريك والتكبير والدوران
  (double, double, double, double) transformedBounds(DesignObject obj) {
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

/// محرك تقسيم التصميم إلى عناصر قابلة للتحديد والتحريك والتكبير والدوران والنسخ والحذف (مثل برنامج ويلكم)
class DesignObjectEditor {
  /// تقسيم ملف التطريز تلقائياً إلى عناصر مستقلة (حسب القفزات والألوان وتقارب الكتل)
  static List<DesignObject> segment(VectorDesignData data) {
    final int n = data.stX.length;
    if (n < 2) return const [];

    // 1) استخراج المقاطع المتصلة (Runs) المفصولة بـ Move أو Color Change
    final List<({int color, int start, int end, double minX, double maxX, double minY, double maxY})> runs = [];
    int rStart = 0;
    int rColor = data.stColor[0];
    double rMinX = data.stX[0], rMaxX = data.stX[0];
    double rMinY = data.stY[0], rMaxY = data.stY[0];

    void closeRun(int endIdx) {
      if (endIdx - rStart >= 2) {
        runs.add((color: rColor, start: rStart, end: endIdx, minX: rMinX, maxX: rMaxX, minY: rMinY, maxY: rMaxY));
      }
    }

    for (int i = 1; i < n; i++) {
      final double x = data.stX[i], y = data.stY[i];
      final int c = data.stColor[i];
      final bool isJump = data.stMove[i] != 0 || c != rColor;
      final double dPrev = math.sqrt((x - data.stX[i - 1]) * (x - data.stX[i - 1]) + (y - data.stY[i - 1]) * (y - data.stY[i - 1]));

      if (isJump || dPrev > 48.0) {
        closeRun(i);
        rStart = i;
        rColor = c;
        rMinX = rMaxX = x;
        rMinY = rMaxY = y;
      } else {
        if (x < rMinX) rMinX = x;
        if (x > rMaxX) rMaxX = x;
        if (y < rMinY) rMinY = y;
        if (y > rMaxY) rMaxY = y;
      }
    }
    closeRun(n);

    if (runs.isEmpty) return const [];

    // 2) دمج المقاطع المتتالية من نفس اللون والمتداخلة مكانياً (<= 2.5 مم) لتشكيل عنصر واحد منطقي (حرف / وردة / وحدة)
    const double mergePad = 25.0; // 2.5 mm
    final List<DesignObject> objects = [];

    int curColor = runs[0].color;
    List<(int, int)> curRanges = [(runs[0].start, runs[0].end)];
    double cMinX = runs[0].minX, cMaxX = runs[0].maxX;
    double cMinY = runs[0].minY, cMaxY = runs[0].maxY;
    int cStitches = runs[0].end - runs[0].start;

    void flushObj() {
      objects.add(DesignObject(
        id: objects.length,
        colorIndex: curColor,
        ranges: List.from(curRanges),
        minX: cMinX,
        maxX: cMaxX,
        minY: cMinY,
        maxY: cMaxY,
        stitchCount: cStitches,
      ));
    }

    for (int i = 1; i < runs.length; i++) {
      final r = runs[i];
      final bool sameColor = r.color == curColor;
      final bool overlaps = r.minX <= cMaxX + mergePad &&
          r.maxX >= cMinX - mergePad &&
          r.minY <= cMaxY + mergePad &&
          r.maxY >= cMinY - mergePad;

      if (sameColor && overlaps && objects.length + (runs.length - i) > 1) {
        curRanges.add((r.start, r.end));
        if (r.minX < cMinX) cMinX = r.minX;
        if (r.maxX > cMaxX) cMaxX = r.maxX;
        if (r.minY < cMinY) cMinY = r.minY;
        if (r.maxY > cMaxY) cMaxY = r.maxY;
        cStitches += (r.end - r.start);
      } else {
        flushObj();
        curColor = r.color;
        curRanges = [(r.start, r.end)];
        cMinX = r.minX;
        cMaxX = r.maxX;
        cMinY = r.minY;
        cMaxY = r.maxY;
        cStitches = r.end - r.start;
      }
    }
    flushObj();

    return objects;
  }

  /// تحديد العنصر الذي ضغط عليه المستخدم بدقة (يختار أصغر صندوق محيط يقع داخله النقر)
  static int? hitTest(
    List<DesignObject> objects,
    List<DesignObjectTransform> transforms,
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

  /// بناء التصميم الجديد بعد تطبيق جميع تعديلات العناصر الفردية (تحريك، تكبير، تدوير، قلب، تكرار، حذف)
  static VectorDesignData apply(
    VectorDesignData src,
    List<DesignObject> objects,
    List<DesignObjectTransform> transforms,
  ) {
    final stX = _Float32Buf(math.max(256, src.stX.length));
    final stY = _Float32Buf(math.max(256, src.stY.length));
    final stMove = _Uint8Buf(math.max(256, src.stX.length));
    final stColor = _Uint8Buf(math.max(256, src.stX.length));

    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    final Set<int> usedColors = {};

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

          final int mv = (firstOfObj || i == s) ? 1 : src.stMove[i];
          final int c = src.stColor[i];

          stX.add(rx);
          stY.add(ry);
          stMove.add(mv);
          stColor.add(c);
          usedColors.add(c);
          firstOfObj = false;

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
    }

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
      paletteArgb: src.paletteArgb,
      stitches: stX.length,
      colorCount: math.max(1, usedColors.length),
      stopsCount: usedColors.length > 1 ? usedColors.length - 1 : 0,
      jumpsCount: src.jumpsCount,
      sequinsCount: 0,
      beadsCount: 0,
      trimsCount: src.trimsCount,
      minX: hasBounds ? minX : 0,
      maxX: hasBounds ? maxX : 0,
      minY: hasBounds ? minY : 0,
      maxY: hasBounds ? maxY : 0,
      hasBounds: hasBounds,
      machineType: src.machineType,
    );
  }
}

// === TARIK_WILCOM_OBJECT_EDITOR_END ===
