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
    'vfPxXjecQQff+YZLZ0h2Ge6jMd95wrtgxdwpUy2AOE3h6HEwjYhDOL4ONRt+pseCNuingDD6A5/Qhs9QGI/AXWhwni9HoIf3JyPQ'
    'Az90BPqQrZ03Ms72ERs/8fQaEeg3fBJq2ISEOcp8iEDfFCi+o88wi+mwsI7UWDciN5cI9BFBJzSfG4PTx6yKRQhuFIxA3xmBPt0Y'
    'WD4QiU4niwAagGbcYCcEMzCAF8I4iKUIhkFBYAiwi0K4ogA2KYQrECIQueKYIo7pIhsXakaeh80ZHt0ImMAvPpBtFADv0LkjLsp3'
    'vnChQ1hp2mZ4uqhIVkXBp4hd1St2tfhTVvoG2BVr+3iNXRFSaoKUGiGlpjGshJSqRrGytqq2ENkqGv1CJouYLGSyiMlMNrLYyGQy'
    'i8lENpLYSGQykckNLjaZ2OBhk4UFDhYZWOh/sXsOoMYPJvTxb6MCQy++B7RK0FXhCxNA9Z9c0kQeQ/ICoGo6mGnVWeG3wK+Fl808'
    'hzElab1aleDqWPKYqgqHNjLPrgAK4piHOUYjFIMoCjNrMCFuisGEZI1jKSIcpfdeJepD0ZhKcUAMauqmJhury0Aw+pGR+ZDNfNyU'
    'phu4acXNTLqBA/ZUUnfcwGErbkbRzdKTW9KTW82+GYzQhZuwvmAVKFmU4jbFbYrbFLfJbpPdJrtNdpvkNsltktsktUGCyqDghpRs'
    'itsst1lus9xmuc10m+k2022m2wy3GW4z3Ga4TXeb7jbdbbrb4KXgGG6aUkwpolS3qW5T3aa6TXGb4jbFbYrbZLfJbpPdJrtNcpvk'
    'NsltktrgTL10Ha6TUkxxm+U2y22W2yy3mW4z3Wa6zXSb4TbDbYbbDLfpbtPdprtNdxuPc/E4F49z8TgXj3PxOBePc/E4F49z8TgT'
    'Jj3P7EBJonici0e+eD4TgO2yIyFFcwOqNCiMZaasUaR0UXDimQSnlfNsLglQIyWb4r8azRT35RHLfl+AUEippiRRGMqw0N3gTgHg'
    'iXxV2RS5JCBqICn6K65RW2H6mOF2mTJM8XNgk2jEm5QkSvNfAV3JzO4rins3jIqgb6AUAYclu/eoIsXPgQGpAtWJkkVJbpPcJpnD'
    'pDYW5D8HHi+KQ6Dss40B4WUEJgRVABQrmVIc/f/0UtkKV4BzBMNHwK6HjmFpVboeI8wjO5Rz1zDr4XZI0qnngOJIAFNGJ/lMYjNl'
    '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'
    'okytwojjxXUX+L9lov+aQAXQwLa3OtbtXBa7Bf5vmfnSpklpNADFgoePNjXdT1qm+OhSf2yZHovyv3talPkri7IomQJVHCDfBD4D'
    'aMTSG1zscObuJE6OLk9kLDyz8AZRroK//biDJkp3tjUHDqoO679nFWgwvaIjjXhBte8g5CJLbUdAa5/XfV6wYsHiBXIUiFTwmQWf'
    'GViLfFeBz4xgsRALlG7SUnLIHLAKCgKVjBt2mKMke+4IGNHn33G1GxzhDTYNvf0qu4cfvSLgVPG3tH+qY/UF1ty5zAHvRQYB+AYu'
    '38Vk23IC1v5SqL2zcAV2H8Ah9jI7+RgWYoViBr1lB/sKoQiQFl+qMgFIErI3FiDSEai3oPamIHQoyeZNSmYyVVZNIxpJ8OIQt03Y'
    'TyxXexHvUrFDTDQVo1yYmXOYiWKopHoqj1veVjuP8/Er26Hbj788XS557LvUtcK6VrauFY85yT1KGKOuFda1snWtsK6VrWuFda1s'
    'XSusa2XrWmFdK1vXCuta2bpWWNfK1rXCula2rhXWtbJ1rbCuZYbBHta1snWtsK6VrWuFda1sXSusa2XrWmFdK1vXCuta2bpWWNfK'
    '1rXCula2rhXWtbJ1rbCula1rhXWtbF0rrGtl61phXStb1wrrWtm6VljXyta1wrpWtq4V1rWyda2wrpWta4V1rWxdK6xrGXzXZeDs'
    '6ZKQula2rhXWtbJ1rbCula1rhXWtbF3LUHQEZO5GGDAHdrWE1RKesvRiCQ8uQbGEYQnDEoYlDEvoJyX7Scl+UqhrZetaYV0rW9cK'
    '61rZulZY18rStUK6VpauFdK1snStkK6VpWuFdK0kXSukayXpWiFdSykznXVU0J26Y4JTbdG2dUIiUddK0rXM8ibCyiQA3BHStbRp'
    '4TUtlLuiavD9MK0pXSuka1XqWk3wY1NAt10ZwUjrrqomz0r8zoxlNqK2vgvvEE8mkKXI+qurQHhWKlfEx21y3jeiflUxdVaOVjnv'
    'K/Nzq5z3heRz8l6bmq5IfYp1kRBnMaEqDpBFLyEysywuVR4uprpDepeop5nlLlFPkx+agGGCDyOYmKDFCDRmXmGsrzp1JMiYrA7R'
    'EqLfZ6bIEP2eNHakqRKNHTmsmEW6Nap5SIYZkRanXZiDDsnV+F/kBHzhiXGYdCDKUApzGATzhechuIs3XrRPDPeoRajGARDZXBWz'
    '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'
    'bVEeFCreJvbx4ueQxqib1wigX8mIyYkJqTzJ8kLvlFa8DGOJMxxoE8iIG4oOFfgunI98PoeZskG3R+ARUKGpYDDWDYJ5Kv2aJ02U'
    'Ykg6Hs6PHoJM11pSVuDRddarnoKikz59Qt4XfnIVEDzeofBLFycvF6czk6/TeV1bQeDdW3SCQh1Dd5g1khlyfegkOR2sT50k+RPD'
    'Jf/wSz9FPcIDaFvKcbatnG3aZlui0r/TTSEPKuiTOEvEU1I8ax+RZ/5xHEybhKm3c9xwt22zvrBYG9mdmcfVedwvJJ5s4y3PT3Z/'
    '/WT31092f/1k99dPdn/9ZPfXT3Z//WT31092f/1k99dPdn/9ZPfXT3Z//WT31092f/1k99dPdn99tfvri91fX+z++mL3V9n98WL3'
    'x0/a/eUbuz/J7g/a/WW92P1Tdn/+xu6vsvtDdn/+g3b/+Mbunz+0+8fT7s8/tPvTD+1+eQXSl3Y/rPKev7T7y93uh/ct5EF9tfvT'
    'F3a/rHJo9692v5OB4wd2P3WN8qXdD59Aql/a/bA7VvvS7ofdMfvxJf9uuz+vV7vfrsLL7s/r1e5nz93uz+vV7s/r1e63N/Ky+/N6'
    'tftPBsWx+/N6tfvp3rzb/XZ4XnY/e+52P2Mdd7s/r1e7P69Xu98+1cvuz+tp9+f1tPvzetr9ef1Buz/J7p9/Zru/yO6Pp90/1ovd'
    'X76x+8tP2v3ld9r9/cXuzz+2+9OXdn9+2v35p+z+8qXdb1Og/sDuf+ZxPO3+/oXdb4qh8YXdL59Amt/a/QgdLf5OV07HT1r9+2PH'
    '/LHVf/I7gJQnqPO/kNVf19Pqr+tp9df1tPrrelr9dT2t/rqeVn9dT6u/rqfVX9fT6q/rafXX9bT663pa/XU9rf66nlZ/XU+rv66n'
    '1V/Xw+qv627113W3+uu6W/113a3+uu5Wf2XdD2oYvrP6mWwFy/47q5+OgVV+r9Xfvrf663E4/aTVP+9Wf3y2+tO3Vn91qO6T1d9u'
    'wbovrP6XYN18sfrTi9X/vz+s/o8r/FWwrvGaUJ3LPG71kHQji/EXKK50VU9qbHitnfcbEiPg4FY2YvZdqrxCb1uhkk2cJPutDFej'
    'evChAN2peV8iuc88rvUEJ1l6MpsUgrWe0CRrPZFJ1noCk6z1xCVZ6wlLstYTlWStJyjJEhxPE+L4Wk9IEn+/pszKtZ6AJGs98UjY'
    '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'
    '5J7EntXYsYPxQR9MyDpEe/teBn0wbIfaWnX/KLs9RH8zND70ed3j+ryu8S4Zm8a7JMRFrdC6cb2qvsJWD7ePpCjfsimJddegDfpy'
    'gK+Li0llDgC7O68FMbymNM/E8Q3ayzoG3gyAe8ZPJ45XUUMJ3LaJRXbPDvjfGVjnHdl0VQVYvf07hCINIY4G0tFP3Bzp6Mh8gTug'
    '3aPo2+nER6kyldNguBPPXn7gm+Qbvkl5MxIuiwLyDd+kvhkHl/gm+YZvAm/Eialj9RNTx+pJqyesnuLgm+QbvgkcTascfJN8wzep'
    'd3fVoINqnQh7fkTY8y3CTpdUv7ukDr4JVtcVhAF8wzeZDwcVJLvhm3zroIKP5oq3Y/XoJ4U/31L4sboDK4imXCn8WF1ZHqgUuVL4'
    '9+JrOYU/O4X/W2fVXvTCN8k3fJN8wzfJN3yTfMM3yTd8k3zDN8k3fJOvHVd7rSuFP99S+PMthT/fUvjzDd8kX/gm+eCbfOfC+lcP'
    'F9bHA/KFnUgmRiqhjS6jStKGj58ONZwDxvLH/sH8fBKVbNuaKuv+o76v2EIYbm+ig0AeqLNaPNStRe/DdvQ1ZEbsg5I29o+3DQ+y'
    'Emx1dR/3E7kvVyJrQaVOCbfGztmirmkChMIcXYzuvZ7aKv428xdAwJTlapXhEnhEgEUMqgce5N9Rru2uWGzXt+M3nfjFJyyDATtj'
    'wCrYdg5MqwWE5IqbZ6/ZcbE68Zr2bgqcZEScyhtzd9XYAleo9gG/4sYCxs2x91h4YAtusQJIrX1VGr5cwg1WIQA+o6LN+og9/74I'
    'G5VpxplQU3s5MNQA9GsXJ+qGoKmGd7G8lJlCsdpiyvFmq8EahzqqOs6MpA4bGs6j3RsSOwQa1rPpMMYpgFSHKyJvBbDdJSPsKCc5'
    'lx1FghULViRYsWBFgh0LKCRYWDCjmYUFyxIsW7AswbIFSxIsWbAkwZKWXZRrSaxFqZaKkxdlWhLpY+fqxCRjk/JMLTYozZAwg7IM'
    'XYFOSboW6pQDVdABRUHJfUiB/7iweG3LKvx4Q+6NAHfsgtts749749tvrw/VD6N8ULeDbu+YzpIIecdpVQdT3bc7AbbwW6fHYVI5'
    'aHQMTqgGndEa6CcGQ0NpFYPThd5kegMT/pT7cJmGHc932HH6NEjUJph2wo4LpJ0kbV868vq3jrzxnSMPHr75m7Dj//oZY/hygxaj'
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
    'RWDATNM+IM1CQRnw77HoDML1867lw9LxxRfyCHpVcZi807eKw+AZcHGYfLhcHCaNXxeHAf+lisNgI1BxmHkrDtNdHAZlX27FYdaP'
    'xWECxWGqisMgrCC3DfjuURwGrvtcDXtW1cIF4Ur7VRwmQ55QHCa3syQcycGEMoiYAOIgykJsR0gPARehQABjGhEShHRlZBQJ0PBJ'
    'RFUQSpfWEhr44E4kBhsqCiNuvLDuCBr46NFMEMEszcS6JqlA08kIRCyEiAkJS8v1gYgRbFrxD0DEODrKz4gYgaoQUNVVUkdAVed1'
    '676KHG0abcTLmvCySiGrhKwUskrISjGqxCgUskjIQjEKxTiQ8VBEhGXm//hRIcHWL8xSQFwewSaogrlhc9BpEzz9WVoGIBjWnVyW'
    'INjkomPeSTb+y//wCNf4eqJ+CtdY+QGoRZkBGkhkDSWyBj48FOwZ+HSUD0ULY0Nj+ElQlRIthHkoVBHlV/Onq1to3WbpT+iyiSdW'
    'xYsHzZKporAhdlcUOR5iC+zkYw3SFAJxWA66GNUB+ltvim0YKpFD9gDKRZlQDnYFLDvTb5Lc06wWOAQGWViZ/pJHKeCGfIPQ3CU1'
    'F2+A4i3lGOcbOFLxpovNtefqeLP1yVH0ybhcfIPVp95kUVUMoaeoB7x/2YM36KnuqeqpnlM9p3pO9ZziOcVziucUzUHt3uzhG/RU'
    '93jO9pztOdtztucsz1meszxnec70nOk503Om5wzPGZ4zPGd4TnhOeE54TnhO95zuOd1zuucA0YPHb7mnuaepp3pO9ZzqOdVziucU'
    'zymeUzQHXvsWct+zp7nHc7bnbM/ZnrM9Z3nO8pzlOctzpudMz5meMz1neM7wnOE5w3PCc8JzwnPCc7rndM/pntM9x9e5+ToTz0PP'
    'NUdPQfP93HzlYUKzJ9RTwj36TcnPeZQyxZ7qHj1xMPubgjbZs/RX/PMQXwd7/FfTlZn8XFTfmdW/F9PU0NPdI5mJZEoxvPd09WR8'
    'NHr6Uc9a7vFfreIe/xWSvNCjCHEA5aSZVt4ggHL2hHv8V00c7MioQ0/16hf6Wr166+7x6jnEHn9OtYTFf1X8ycVzShEWcyQhwpLZ'
    'Y2jxeM4WSAwCM/aEehKnQ1rMNg6VFsF28k83grNVNpaZeXA/GJACGj6cyzSd2CNSNMJYIW2E7KCzm0/1Apu6MlP69TnynQDYQgIV'
    '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'
    'nnzTuepd55p3navaD5g6F0nb97jrXIiPQA7bu84FNhyFDy9oyAoZkc7Fn3kBY1A59glIUAQ+SeT70rl454y7zgWWJPEewd09qBfO'
    'bzrX/KARvAF6Z0l0qFxQptaPKheyiQY1qQ+Se2cKtrWwNLREEFgYOkyVC98k9kvl2i+Va79Urv1SufZL5dqXyvXGr15Y84cq136p'
    'XPumcu27yrXvKte+q1z7rnLtu8q1bypXIydmo+cPpXxYDxsJrmEKN2kJ+8lys29Kg0ZvLDf7yXKznyw3+8lys1+qTNeoFR2VqZYa'
    '1BRJbCVJZaqtQpUrztj61r6pX6qlLeWsSEirbhSSet2hENL4KCB1wU0BpCVSOOmPXFx0AFxaOicXpjY6uaz0VFUk31Zn96Xbqor5'
    'sQq8L32Yi0pTVlmjf/mPD7Vsld/KGgEqC2d6VKHDYuk/vLly3ybHWSOCJehqkuUR0bOCfic9CFcwSyUsfOjiWQyRGIjW+dqvUD/x'
    'AyXg8sGAF/RDUHUnh2u+ZDG+wHXv8rDhtTv/TFHe6ZgSeyLzYSdJWgs9cnk2NUW2NUW2dUW2hQLbpuLapoLPpqLapoLapmLahkLa'
    'hiLahkLThuLZQiFkoVC10OeFQs9C87vGu0LRer+3xSs04jWuULauULbn/Pb97yRHUyhbVyhbUyhbVyhb3a7zzBC1qlC2rlC2qlC2'
    'plC2qlC2rlC2qlC2plC2qlC2rlA2X39FsimQTXFsCitzVJmCyhTn5ZAyR5Q5oEzxZM2VkhQF5tAxx5J1BY51RZJ1Lda1WtdyXeuF'
    '1gutF1ov9i1HvS7lqJM9GG3FpU2FVE6tPyXPrLfx23xvml176tCeKktraPjcRgcvzlhqcnRoFEcIXob2VNmBQ3uqrESzE8iGHNpT'
    'ZWEO7amyP4f2VFmnQ3uqbNehPVWW7dCeKrt3aE+VVTy4p9JiHtxTaUsP7qm0sgf3VNrfg3sqLfPBPZU2++CeSmt+cE+lnT+4pxIB'
    'GNxTiQ0M7qlEDQb3VOIJg3sqkYbOjDb+MPmCvajj2RsIT1/4WckWCJ9YYQQZFDvEYDFpCpZcbaJsbCB9hD+GO6j3UxApIK1f/OCd'
    'MDE25qaNWm48btzffRuLOocsXZzNTS7Uf32/x1WxI1SDosO+WkTGl2tOyJY+MASPTOn9wacAJnmnUVCLLOmhSyoS0y6PmK5aVbEj'
    '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'
    '/asdf7EC/IEdn5+pmBiwMIiE4Uc7vsVlzs+bHf4fHnZ4/7nstym5pTTgYGxTmI5+2qZfD1FI+0EtqEqZ8/IVBKrewqXQ6GZoDMxq'
    'PGDxGirJolmvMLgtMg/FPU7OyyMNBlClTtSrDMG61Q61NV4O26yPCoOF7aF2VbtSxzqKQzxT7aZ2Yzu3hy3DZdFgYbuzvSgPDJdF'
    'g4Vt6XCrqM37Jw0WlvAeale1Jc+QPEPyDMkzJE9InpA8IXlC8rCqMQ2XpfhNxXGyLXm65LniLCVPkzxN8lTJUyVPlTxV8hTJUyRP'
    'kTyF8oB6YctwUZhiU/gj20VtsSNv1T7aQ+2qNuVBbtKW4eI65VuGy6LBgvYUY9DsakueIXmG5BmSZ0ieIXmG5AnJE5InJE9Ini55'
    'uuTpkqdLniZ5muRpkqdJnip5quTR/Vx1P6fBYhontAt/DxguiwYL25TnUJxDaXQz617eFGVTEt3Iuo8XxViUQjex7mHdwrqDJwXI'
    'F+A1hIteG0E+tAnOsKAwsj0QPkJ+wc3qBYnMJEMQ3m6Ok4uWqbtsVFJFfDC0lumwpKrM4Qlu2MmPm/joVHYKEJSNvAs0EL0S5LoN'
    'pFwHPz+wmKj0OqTolIg1KDs/uuOjGz+6Ma6JH83AmCoa3XUXnd8DX4BknIzvjql03YFQFtbmDub54tQIWIATp0bA9zqB/jIuf+LU'
    'CP4Jom4CBUom0l0iHtedJZwraj90kh8iRAuoNLggOyK6yKFFitHkisKngFtXITCgb0s3MTn5GvKFmQvWcEk7JMvsCaT2TxwHDAif'
    '3ZKtm5STtZh5gshjvKXTWLdp5UZsO5RSSDKJTxE/8/TSKUhv9XeT9y3GFLmcOlEbdI7W648xpjCVW/uRWwOGbHWgIsMWtQJ0jiad'
    'o8F70Er5scIJNJ5T/3kVTrbcKmk6w+SdMnmnTd5pk3fa5J02ec2bynAgJZ626QChvZ2KKgWXJm+zyVts8rb7nCIWEpq8xSZvs8lb'
    'bPI2m7zFJm+zyVts8jabvMUmb7PJW2zyNpu8xSZvs8lbbPI2m7zFJm+zyVts8jabvMUmb7PJW2zyNpu8xSZvs8lbbPI2m7zFJm+z'
    'yVts8jo/gj2WsFvCZgmbJWyWsFnCagmrJTTvC03eYpO32eQtNnmbTd5ik7fZ5C02eZtN3mKTt9nkLTZ5m03eYpO32eQtNnmbTd5i'
    'k7fZ5C02eZtN3mKTt9nkLTZ5m03eYpO32eQtNnmbTd5ik7fZ5C02eZtN3mKTt9nkLTZ5m03eYpO32eQtNnmbTd5ik7fZ5C02eZtN'
    '3mKTt9nkLTZ5m03eYpO32eQtMnmbTN4ik7fJ5C0yeZtM3iKTt8nkLTJ5m0zeIpO30uQtKvs2CWCiPeXAXYrLnor3mWT7osnLxDO2'
    'u2zMfWGAbA9u20E6J5q8IWuzy+StMnlldrrg1GoyeTtNXiVgEKrT9xPlK03eQZMXWK2s2ErgdBJHjal8cX5Y10VgnDBt3EmTVzYu'
    'mCEZ2zMU41Plqz6qNCGH9zGvUB9q9YtH71z1cWQOA2N91cc5j/o42Nartny6qw0iyF2tLR8ltapKap1c/PDKo56Wymn9Wi0HjHk8'
    'yFA0bPFTccaYSW/emPTajUlv3Zj0+q1yznGFHHgqyVyZ75GRWly5ieljsUmcJ74AJJk2HbqEp2+cdf+H7Nv4sboS2Eu7+DcbvZ+Z'
    'UQQC1kLLW8mX55X3mTkxmy/wSRwwWTIAhZb4pmMTzQq2SzoyaI8zhZ/NxmZjEwxWVUXp6HWkvojmRmuzIRkoAssksmakvvj/6S/+'
    'o11v2g8EQOg1zQJhV8HnC3Axc3Px4eTjQNoo2U2Y1SpOEebhirODGXf0wGPEVWHnX2Bh4UiwbBZHkJqSjxG4VuC3VcYjguuu0nSs'
    'Uzdc0rrQ3X9cwW5xhIXunsQr41Yp73AE3oXPo1p7TPYtPxbi48P1KtNXy6OIXx1/P9eKRjtHRU5Dws4XbywzdS+a2cHRodHB0anR'
    'ydGpUZb1y0M1FMWl4zcU5oXzWaNb2d8aZVoycgvldVT53pBTstDUD/ksC4vjssnccTH5UGeGPhIKgJPmEoqQU2VaNjmK5BuBGsH6'
    'v3hVkcMGnRkvbDJB3aOLo8scQUpf1ygTppvIfBpTppv4apjRhhc2KZ4IgpjThpeQ87jwham6El6jvfu73L/a9Q31TP9feqbzZPpp'
    'N0NwZ2cxNhZaDsFIfANmik7gqjZFsLMH7BZxn7O7e7p6lsih8YY94Z5wT3GP6jFh9aaYdvVU9+iQTSCLPWO6xxIOSxiWMLx6WMKw'
    'hN0S9uMeS9i9ejvukRewNUuotCMkEqunqadawrrd4zmV2YGfZtkE7sXqVIdpMrixoT84nUnlr8MBl82KNfzvTQWbKwlFPplPqLB5'
    'FoVYXRVQiuKqkd2ErOsivhwSLk6JAXt6dtnMxRWFkdVTXKd5SFdmQe6toVlcwcXM3+OogEoqoNW1k2FlZ08ZN8Jv9ogg+yg9/ipD'
    'q6/gMrQuEHMVOZtquwhaU+GY9SL8Rru/CL+RDe0ytFpvxqsMLTLobmVomyPph1IzynwVdStsX2VoJW8oivaqTK6Ug6Yq6nhtg69F'
    'BdxZjXawjnvjpPF2sI4X09lV9pW7/J3rzHsrtwdtIdzXtMt9EAHBwYpdq3OXorLwPGW5JvSut1NWvGtYVAcJz5HJRUGklMQdaLCc'
    'rGrLtu9cZ/Vegvb3I5eL8hjRKcJDpOoQYbVHGD2hKFuZR6Ew3J+4zurFzv7D+dt1rXv5M+fvG9eZ2Mxi/ch1JjGGaEskxpS6JDGo'
    'rlTpK8Rr/uJxLDE2xdABR4wIdnYosFsWue9Zmeyh0HDZ9KHYcRn9oeByoQKh6PNCdgU2z4+ns05Dcr8AkBiCKgbr1OP1bzuducTS'
    'irzhmm6/RpWmScNpvFGbbtvGm7gNj/Kr6XZvvPmbHoXGB6PpMWlUTZsU1cYH6utFx/K/sw/ta6/+yYeGtLe+HXHT9WYOvUlTe9iv'
    'VORYYk8OlX2fk3Z4kXOJPWurZ233hHvCPcU9ysHH6kXagXqqe6p6hmx2vBn2NBW5mtgTljC8eljCsITdEqaONuxxYo9XB82ynE7q'
    'sYSZhw3zuvlbZGogeqrn1O0ez8khRu8GmFnplkIFhyOsIY9l8AASlRo84hpJjcg0xj8P5ZsRSK4VKdafVanOnw3c0wiN2y+UrLVj'
    '5Kp6DkIzKjn2IGpTIB0drAlvNkVtiBPnmBmgMyoKlNTVWFbpPLrxdXBQ84QlzRyP5aM0vHqWe3wsu3Yo3bqFtDrqsXLhWhsICECP'
    'a8BXn77Vx2/1+VtdcYN1FNBjpWCaKsdVN5gPlj2unUo0pUyXBt1OMLWyM5g9pR6vHl79VXTUdDxXvZOLqKeXW6lS5qRbwkuxavVW'
    '8hQ9dd7KovJzmvUpa5d8zJWx0KbfpKLnx5zaE9LO9Ziz55qDQkkKgq1+zNmztnvCPeGe4h6HyE+XuptXRGB1j7RLKN1FAbHVj7l6'
    'LGFYwvDqYQnDEnZLiKQNPebq8erNmmO3hM0SNq/eFJ0B7XvIwVz9mFc/5tWPue4WFzZE9amQ2ss5XVrz6Sr8kb+XT0vVgxsqJLvJ'
    'JEztG0AdKlzJP83ys8vf3TcAtG/qyApJgfZN6Nslc2dXxTqULhjSvkm3aT16Vnm3ytbQJDrHDqnaRwm2R8o4GOkLGIA/RfuM9h6v'
    '2sFQo+urtjDU5vmqPYy2x00qtF61i9HWfjGlho/1qpMjYoqrTg7UZD2Hoccw9BSGHsKuXaJLHj+lfkj9jPoR7VJlmhJ98RpHMJYI'
    '4wrZthbhrNHvOJbV7f1St/dN3d53dXvf1e19V7f3Xd3ed3V739XtfVe3913d3nd1e9/V7X1Xt/dd3d53dXvf1e19V7f3Xd3ed3V7'
    '39XtfVe3913d3g91ez/V7f1Ut/dT3d5PdXs/1e39VLf3U93eT3V7P9Xt/VS391Pd3k91ez/V7f1Ut/dT3d5PdXs/1e39VLf3U93e'
    'T3V7P9Xt/VS391Pd3k91ez/V7f1Ut/dT3d5PdXs/1O3YNxV1qjkvfXbf1FuJIeV3CDgbISBtv4C0/VTV91NV309VfT9V9f1U1fdT'
    'Vd9PVX0/VfV9V9Wlbv97o2Bfu99PKNhRjgc4keGYJTJFFhe+wQm/uhCK1VmqdIlNYyJggnx1dyOmNtG8iT4tv91ivhgrtU3uuAF2'
    'd9zeW8U/zWBGk7R/OBkU7oEFx8Nk9ljih0iyEljBYmchDEVVlKTsLPm27P1HfUdqfJ38UGgWNpMDRp75zsoYNcQcHaopo1oe9KFV'
    'gXpdVSBVFaszjdzh0aozCr+aFiLjCo5lNCkGihsFqwYMkQGIZIeMOGima20ojZOk0GhqobY+VAOIzY5m0/eFdsDDtpP/saoasBSR'
    'qlLAXVQ6Uj26CG1VBFh1NFnfEq2Cyqb8HFQDxQncEZBSQXibjQUSGV1e8oWhyjlLhIMQ55O5XIpLXIjjwenbGcEDBoV+yAC7xEoP'
    'ZyEyFBry60jyF7xdFsNJB7lRKm6aINJUSSPJNM48vsZRnUYWglpM1x1kjmE5NVwdVn8a09QxAffswgmWRzvpSALlAXDb4oMGvS8N'
    'Pt5BolHGPI9iH8wkpKbjqrMxPpgOA6gIf2Mm/JKfJnQofWrwxAzynqoS3eAD5IJ0zZR+oMtoiGtDRcJK7UQMj650h0AFUQ5OOssF'
    'Aw25AJvC2IfoBFG6r6tUYGFQa6qJIF8oU9V/G/kYi0oINrAPs8yeVBWWJuysAkw+o08RJ0FY+KabkM8M36oirg3qhM7MalIf27hl'
    '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'
    '/ek0FvO1K/oliYiu6HTka5bRqASWIlMVwupj56fWweSx5D/zr+Yf/WI1f8U1ff/2f1a3VQBiqCmbjNOwepblSUkKdZqI6d3V56fD'
    'VoFpwt8K5Z/Mvy4+F+wEN5Sg6Ci4TQbivUEPcG6H1iWMgYembGcZywVjWQbgO/ts2c6bXYXFn86urHIMwPP87GwQt+1sULalZam3'
    'T52cI0FTVurESp2yQyd2qAzAwAA8j0pScL198v4YgCdt1tmgYNvZNIWo6OjpaNd2NgTIOhsiKYR8Ov1JnQ2NR51N08Ows3EjGxsS'
    'VGiYdNSj3KXX9ADsbNCZpWitU6rW2TQ99zqbRmcym0YbIZumx11ng2oTWqmynWWH4qMU+SgFH6XIRyn4KEU+SsFHKfJRCj7KiTV0'
    'Nk2PNbRYOirpnU3TA62zaXqadTZNj7LOpuk51tk0Pc06m0ZFPptG9JwNalRowHZprKsqLXfyGDg95Z7gnejc5NSUa4JnovOS01Jn'
    'JSelnJIhnvX6tl/kWhALVQFPEIGk9uutRyZtU8MqC1/oOfPn1JxfQF2ThVPi34C6ZosJlL3fAOqaakMF6p6i+wXuXkkFeVWSSGQQ'
    'dkOTwCA5rNzLd2jx/pW8lZ/o8cT5OCajamnAPH6qayYuR5YljOoqghdp6u7B/Mda9j3CfsWwXzE8Eh7xmmfar5geqR6x/b1tAduC'
    'Clu3YRsqbN2GrduwdRu2o8LWbdiSyt5V+RW2v23dhq1bVZ8jq86I7W9bt1krLL/CR9hfvpOP0NZt2LrNEoiKjisjPkJbtxngrdvt'
    'o1aPqK4Jk1/hIwwfoa3bsHUbNsLyH8sJzookBCM+QvuBYes27AeGrduwH1hs3hb7gcUGbrEfWGzi5j+Wi2EqOsDFpQH4Fba/7QcW'
    '+4HFfmCZbz2x7W/7gZ96YvuBqiferhWeUHMqihH4FT7CFypqP7DYDyz2A4v9wGI/sNgPLPYDS33rmt5KJx+h/cBiP7D4SsnM9HLR'
    'cEUXurhEE7/CPoyvlGOnyrPgR7YX6Mtk886LD7B5X18i/lUWB+/fZFKIPQFiTTopJrZaXhrC6MnTCDyLgafB/IDj3esXT4MbW+53'
    'PI/A86BzqFIsnp6GimzlebhfmgL4Rn10IS3SqXcufL5GhZK1MSvKO+vTSUUlgkOzTa5FVS2vdL2UzOnP2xoW81OrDBygk3Ci6qpR'
    'cI04fe7mbb2AjRXv5lFthXk3VGI/mtMtPyX5foZ1PXd70Go/YF3PswSsWioDAlX7Aet63g6g2q9iXc978Wj5VazreS9Y6ymGWNuv'
    'Y12l6/V8M/JWz0POhW+ix5zPeD6i3ulb1pEkmELZ4ywy1b78jOd3isspl5ZzaTmXlvP/RMuJC8u5sJwLy7mwnAvLubCcC8v5L4Hl'
    '1MvKuaycy8q5rJzLyrmsnMvKuaycy8q5rJzLyvkPsXLaReVcVM5F5VxUzkXlXFTOReVcVM5F5VxUzkXlXFTOtz/0S8q5pJxLyrmk'
    'nEvKuaScS8q5pJxLyrmknEvK+QUpZ1xQzgXlXFDOBeVcUM7vEpQzLyfncnIuJ+dyci4n53JyLifnf42Tsy4m52JyLibnYnIuJudi'
    'ci4m52Jy/m1Mzr6UnEvJuZScS8m5lJxLybmUnEvJuZScS8n5rSg5f/vbvwD0igs8';
  static const String _wilcom_e1 =
    'eNrkvduy7cqRHfYv53kdRt0vfJPttiTf7bbDDwqFg6ZoiRFsuoNNW3Z06N+FHJcC5lxrnwtJtdzyw95AYc41UQAKVZkjR478++9+'
    '+6++++V3//a3v/v1//k3/9tv8ncf3/3+V3/zm3/yh+vgX7n1V7936w9//N13v/w/fvW7v/vNx3e/+sOv/vff/vo0f/+rP/72//7N'
    'X//xt3/89b/57pd//MP/dR379a/+9p9998vS2y/Sx3d/97e/+vVv/tfvfpnL/EX7+O53v/njH3/zh7/+2+9+WfsvxtX+7e9/c325'
    'jvWL+vHd3/z293/961/97jff/TL9ovWr/av/R+3yi6v5r3/3//7tv/m7737599/9k/jv38ZJrlNcH/+Lv//uj1dv/9XV2eun/0X7'
    '+H58FPx//cz1/8D/a+D//PF9nmiU9THWx/e1fYyr1cvHnB/fz/axBzY5a1s7t73d27W4zalcX5jayVs7KXNn6Ss7XduS8NPx9Zzq'
    'tdP7tRN/MuNvr7Pk63u5XH9b0vWdq388Upu+05L+qk39Tq/84dx96mfvorfX331/XV+e1++3+OLEledRcCPQ1sfXZlfcvJyxKZu3'
    'cnDDv0Dz+oVSru+2+HJ83D9KXMqKbXwvXafecUnXg8grrqTFTtyXUa/TRb/XtRO3vqDf11+XEjvXn8e5cP0lLjLX2Nkfe/GTuJvl'
    'uk0rjl+3esZdXeVjbP76qDxdj+OlfzTcm2s0XL98Pfga/Z0f9erLdS/jdtf10XBNeBgfGDrcLZ1HOGpaxXd73J300a/uXBcUVxB3'
    'fsZTuu4JrvEaeAu9GXzmK555nOO6SdGla+e6+LiTeU8NpWv48alc/c64lmvkxdHvc457d31nx129vnLdvrw3Bm2Jn72uJcfdiQe6'
    'ErfnAcdd27zlehZXE0+pXVc/2Yy70fRsr6YuOB4Ithivk39VB08WA9GduZ779/vqRDyK6wbkEa9SZieWOoExcb2y38dQxpiOA3EG'
    'jP/EAzECr/YabF5/jOGcBrdF26ZtvNuxxfeiY02DMa6nsWPX0MH9jNsZT+MaByXmh2tc8EKGXpN63Y94bSZv03XHcQHXheEu53Se'
    'R4zTrFcvehzXg4vO153LuHvx6zFCMd4xFGe8y3g6iyeM28dhnhLmipIW70i8VHlgnHe/CfUjXqh4NLhZpS4NpXgg2InXh4PLH12v'
    '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'
    'uUPcsL5ccDyLUKJq5Gyy5Hjci0ItZtUxZ3O6yDmaKia/dKI1XB4dTZWi3zrR7qeyOtv7VF7PXmzmSSjfz1rtzXUbVew9W/3N1d6L'
    'Thk7PDB9QPXiq86aVf88V5/2VJz3aVU9nfn1+1mz/qjPuei9T3uq3s+75isO+KZn3WZQMnhAXfeNz7rV2bc+62aDr1KUyIMDvv1Z'
    'Nzz7AWTdclD7rH86LVdblMRz1JmLVCR4oPnA1oHt5JWq9EiLnWWldmRV5eU02R7+pv3c4ro5xZmNwQtVKUAL83ZN/T0/FJNL/nC6'
    'Y5dnOeRpDnmeoz8qR5d8KyjLc53P3M6SbwVleZrODV3yRJfFz3wF6s9Wf7b11Iy6p1MU2sh8OoWjT7XuI9R21GrrM6+zZKePOa8T'
    '64WReYumZMtVZ/vR2Y71XVWw+uz1QPTu4aGetANsHP/6ONzr2zB+VlpTd0Xz7jpL5HGqBuh/bRLmNZK+QcIsXAD4t9qq/caSY4lI'
    '1dBZbMf7g23TtjD3OGbfSnXWykXt2yy5p02ffybNU6XpBo31SZNsS4MhSSJnK89zinjYrfHryk71pmxOUjbJ3Cz9bMDz6jdHE3yb'
    '+ijwk1jvqUkyakgMKjjZTKkpjhSeea1KFKSrOPCdTxh28LI8tuUBSzoBMBWMYSmlKsIZTNstCSClEG9C2sypy8+qWFaP4hP2Tjt1'
    'w6siK0XOEDlf11zhUC2M3CpvqRQxN7Ud2i4X/0w3c/MJHTZnrcnoblvek5Qs3wSEj/ekVtmvTC8mG1o0qH1DQFhMjwA7NEzIpByW'
    'QLGUqgsTwarsJ2HauekjuaTPS6n4qmqapBaeJ5SerMMnV5Hy/HGku6pbK7ahF5HS7Ghqdnw1O5VfX87OcWzaOfME+lM+UR1NvTv6'
    '3Hl/CrQ6GJsdjM0Oxp6x6CkWeTo84onwTMyeqbOn7uy5PHtyz+vUB/DlLF/g9HemvzM9EVpvgIHEoogPjxzCpqfYfuKiXgS6J+bu'
    'qdqLXfbqd9/Mz7f3DIAzJLplTZEEP62BO1yJRDX/jjaHav8FlFapI9JuaWuk4TFQ1pnc9JfiAH4ZsfhJ/OSuCGdXcnZX3eC/MKNz'
    '/kRG5/h5jM5/OCanKr92emeda2BnFPTMPukhQpzzPQtRTkpFExAHzkJxJbtkgakiVcNVOPS2kpeHSqNM2RxNpVmaMkuaVxyvYlr6'
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
    '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';
  static const String _wilcom_e3 =
    'eNrM/VnP9MiWpIf+l7x+s0Cf3etO56g1z61zdCEIwlZpSyqgutSoLk1o9H8X17LHGIzcmQVBNxKQ+THI4Bt0kj6swZbZv/7lb//7'
    'X/76l//tb//ub/7nf/Hf/rn98vPL3//pX/z53/qH++A/894/+3vv/cM//t0vf/0//Onv/tWff3750z/86b/72795dv/+T//4t//r'
    'n//5P/7tP/7N//TLX//jP/wv97G/+dO//Pd++es6xl9dP7/8q3/5p7/583/1y1+XMv5q/fzyd3/+x3/88z/883/5y1837f/t3//5'
    'PrnN81f755d/8bd//8//5k9/9+df/vr6qz7u/T/97+zXv7p3/8e/+z/+5f/0r37563/9y78V//xv9+Fef365v/6v//Uv/3i39r+/'
    'G3v/9H9d98+vpfy08vNrvTfj59d2ec/fzftg++n959cxfkb9+XWtn3mfcs7PPPcp9fq5j/xa7ivs+9wy+8+5Ty73Trnu0+u1f0qJ'
    '36znp9z//1rvK5R6n1PvXy1Xflg/5f7//mrcJ49owH1kxMn396XGD+/7yLp/p6z7SIvWjfvIrnHt+0jPxtxH8uql/ZR53a1cP/W6'
    '//o+Lf943vvl/tv7Rspu961NfX+3q973HjeeP3Afvn/i13LdX8djuU+/f+rXcf/svi+07mZu/XxZ0YL7N+PO76Zcd7vzOdx/0qOV'
    '92VKyzu5/ygfbrSyxKNpd7tLXL3HOTyIE7cfF6wt2rN/op31us/IFu39o6fQ9HzL2D/xoMr9G6foGcSjjCvQxHix9wOI1xX33/L2'
    '7z/7tUVDokH5F+t553HH5afHieXn/u/XpfNP/Vn3T96XPnGL96nlblfsl3I4EB0mDsRf54G4bByY96+eezuycfedrzgzHlf3gcKB'
    'iwPxJ3Gg+0/ileaBxoHhM/wngzPa5EDnjOY/iXeRB/wn8eDjQPWfVM6o/pPKGbrJrg95wH9SfIb/5PIZvsrFGRd/cjjh4i+Ovj9c'
    'Yuvrw9mbbzl56dvNyUvfbk6efFvZbbkbT+b+5h6nv979Mnvb/ol7vjtBvOmf6P4/MYzuvhdH81H+5BVz4McmOvZPvrD5E+P1/tmR'
    'm7t31Ht+WLmJm74fYnSZHPR3d7qbceUmntQ9emfNTTzAu0XRxB5D9N7c08vITTzku/PNlZt7ZP56D6y5cxOv5v7B6I33Jt7P/Ucx'
    'Eu9N3NN9o6vlJvr0/XzWyE289HWPoJmbe5T9eo+u+1Nsoofck0wMmq1Bc/f3XXJzj5Rf73cRQ/HeRBcqV/nZQ9vsfffwzhdwb3s+'
    'rfuhbG17/7zU2PapKSPH673NeeK+pXy999ZzWU5l9zaGYLkbm73h3o447+7hZ2sb76D0os5zb3MC6vEeij6MnC4vzxhXvowYeNkt'
    '48PMLw798/6Qs9mMSWbpw8yXv9W140O8mJj9cnaPD7keLCa3+JAT1f0Ec3jEh5wrY2WIOT4+RM8tJ8bJ0od4MzEDa6zdH+LllBO9'
    '6NKHdZgOa9WHeEW5yuSacjFhlphBhz7s3N6XrUsfdmxjro/eER92bodmhfhwLlasnLHvo8cTdnST+BAvp0YXbnw4OZNXzT0xpceK'
    'kUtb40O8nzoK60F8iJuKD883MbPVfDHF62I03u8ufz9Xyj5ZO6MJ0YFqj+l40MoYvDXm92txI6OyrsT7y3uNblTr1iSVjyMHc+0s'
    'T/HEckTf7yJfYT7UHNXF63Q895kLJy8xX83MVxPv2W9v5rupfo1Dk3ssqvkesw9kh4olIife6CbZo/bWmyxexMu2TbC8/q6jd5nL'
    'YnaqxcuM38ilJv4032a0paTNMifrwn0H8RNatWPkx5OIDisjIxeTeDvRs+Kxyf6It7Nz0d96pWEElZwE0iLJUXt/ldNA97IVbycn'
    'grB1cmaIt5NTQRhGOTfE29FkMLEi7scWT+3XeFqydeLtaHkIU6loxS85JYT1k3PEFeZPTk6bdfZ+OzUngbCrYp64/6DmGnRdett3'
    'v06bJ95RGBYnbKA4Hmv5fZl7MNXoQvl+YgKNufmSiRVveYXtJDsxHnDYDjWXx6Y3fM8c0bNim+/3nlrC2vt1YgHc16w59R+927vZ'
    'NSf/oTd79+waXSaGRMzq9wOLLhvbfKv3Y6/ROWI4xDu9B0F08jR2Ym6/h0CMh7TpYomMVTAH+dbbvH+raozf+9lHf2rTNmzQ+/3f'
    '+9kheI93e7I7xBu60nTsuSkxZdyN6drEJHDfaqw5TXt3Q6KP9P/m3/x82+Ur/zzM1lzM4pdzJ4/HdHMv4yM+55geaf/dB+Jp308x'
    'TbSe09FimOZg6NrGChrbGBNjq09H59xH9xx/d99iztCXbv3erVrZ883EE485f051nbDMs29ei0cUzzLHU4yMHLIxCmcO68M0c/ch'
    'bP7LE+LFpJ5+QbyCzqzaZOuETa4v0qmYryklGpTTe84k+b7SLmS9k02Z02CcE9fWIu6FJT7kanl/SMMptke3kqMs59ucKwZL4O6v'
    'NrhVbmb+xpFpFt0057b72mmq391FBtWRaXAPvegPMZJiQEQHvZ9yS1vpfuj52ulhuW6zE8f/m39z955f/j/4eXGF3/Hz8hUWvcjX'
    'Zx3I193z3zS1ci0csk8xaCuT9Gb1m3qwjTfYjyagsBbSWxh63pvvc2qRTVTVD2OG15weozDNheiC19A8e7BB8gUM+THxS2mk3NvO'
    'pKv5tGl7P8zJduOSnccar37FWG45KmKpiQUqZq606ItO6PrL+/ZifomXtXITPYbN0Obu47E52kRPeppEE9t5bSemYxibacUUbQu2'
    '8r09xd28sHJeHjX5YU2+ut+VH9Pz3GRWdT/btDQqy5uGRGMxi99rg74rx7djL1W8uXTT5aYuD0eZqGGWaKaUmRhbWymV7fxs7j49'
    'Nd658sR+1JOZ2LiaP0YuLCMnF03uQ1Ocu+1KO73KyL03aQ4WrKP7lFgqGh01prd0foucupJedNebys7R5EPkG1tss5MdGdH3wpTf'
    '3+1Up4rHf2k6OFj3+ul8Wleup1qxw92PdW2zGKeXvPLGcpHvmGJpBubLyRcaZnzceN7Y3TvSUdK/J3tXxGaiW/7k2nH9NC1ZNR9W'
    'HAsnL2eR2LmnoJ4+S7evoTktd++/7uoeuXsPny4LLHfveSBn45JnRXfoRZGZjOLc41KG38p5I6zXNYncyFQd9ObLdnbj4YXVl0vm'
    'sUuyNl11MGrj1WWHD8N6yYtJ6yvWOcaU3KEpn2HYt74PyHCrzF73L6RNFgZEehXd/kZazPM9diY2udyYQ1uLHYq8r6opMlbyOWVu'
    '965tba9tKT+aNfUcwzjKbed4YQK7+9T17SfiTmr30i7f3kPk0lvFmtM862Uk9vTdyV+9n2vu1B/FbWLnbs+VkaDcSb8/OkvPcXKl'
    'ex07K690P5ku4+1KGyN27ud/qTvK776eEOHMH4gIVMvfuTI20BVxymGTOz1/Wmf1+OUrR9/9MZoWS0fMYfHDQ2fU+OuhU2pcfeqc'
    'FudMLZY9rp2hgxzLV4YK7s8jLrB0/oi/XfrNGc85us79eUUTls5f8ZvRg3q6lld2u/gct7P1+/k8t87P3pn+4mO2pLOYe3FKeorh'
    'jUc3mnl+xzXaucyGH6FYk+b2MJrSlOH3Om5orL/h8g3CbJXuOxxhHLpiuI/xaMOwyhlmacbJcOMlyzqmqFi/044rWrc7jt9kxorr'
    'ZpunnIf43dzfMuEGbmGsm0O2p/a7zKyMf8kj0P5gHzNsEzDb/P3GHQtPQ3bvYliG7Z0zxz2PbIIhaQx48b9vTSHhpm10tKp9xwo9'
    '1jz2vsaix2aMVY9dxnLHpZ5b2wwmNFbo9KPlLDsIeqanEMc5wqn8TDNMPH8xJcnY2XQFdTL9rfrCVDgoHnJ2hnuYpNE9FzbVkM2f'
    'dm9bMg2ycy47rBGb37QsY1b3PenAwV2N0O7G1dYBztgDE27zG+GV64ANkHht+Td3O49d+VwyLtt2hwuHg5lt9UqQ5rvSBU/n1g3r'
    'QCNAoVPWK05TnSPAlTj+Nb+/tMivZaNmK/gTxmAGMLpGawTalaaIhaa7RVNOiAJIm3d+P/mFmZ/B+qEwYaxvGTYaOYmkSZV/eL+Y'
    '1bSffzcUqgwvdnXtz6Pvs5MNuXK1am7LfX4vjZ7YvxSoyTCP9wsLUSRqhh5Y4/dkLHUld+79dLzCbBh8bxNw8X3V39Pc/Nn4Wnej'
    '3St3u1aYzG4oCNX91pTPyaUpXryCTdqt2tWyk31Jb1y7upAXxK0LXax5K38qAh3abdrF5A4/U8ki7Q7tcqGZ142fyN2RK2E4qNrN'
    'pSysdO0W7ZbHmE/ni2+7lulBI7tOZoWM8XdhYHVNT5ciPtrVyY1vq06ufFt1cvW3OrnYHliPtcCE9hcT3WKfrEnGhu59xYjUh8I6'
    'yqhx6cSCZc3l/mCfRNrEC5uEllbTvhJfCp/n/tR+Gsr22mJ/6WGm+XbPlbLviJ7HPsFpRcvJKYUFfrhReW0RP7UblzZ82JeD2FbG'
    'Gb0YR+BRkyj5lOibGR1MT6bgCKS92Vhji+edkqsm5pSCBOHvXhPTvumVZFz1YMpnCC5W3uNEZBiL6Q1UYnM5AZWMphGaw/HdROYO'
    'cfOYaDMuV1gc22dxHJwfbzb/rir4kudfCgX8f53yva/y+6GAmAgJgsh3ZYevjtoycp2uWuZjGunKO9zPcebMrYVYE64WfmXZSt5P'
    'BOcyq6TIZv2J4EjElzJ214ZibPezyvBYLL9xxQh9xLOPRS7eftjwaaKR+4v3l5ZN0wt19KAN+07RqPA7ZY6k1TEzn3KYAi5coWpP'
    'ryodc9/lII+R2ZKtXFOsUNHBI5p9mMTzVWdQvDJNalHLCPphpVj2GbZnx+z3mZB+vKtLc2E+i3hQsfjkipoRxgiuKfBWumKqGa3P'
    'VTF8mIXvrUB+2BLp0g97LIMmx9gkZTBJC6QjWZUPy7XwMCvzCJbsiUGwSj0jx1RVui3mv/R7b/MjbYu70YMYmBY3YgUNt7dmtOji'
    'w8Rhymh5rOMZcpbLVPxQWClqvp94OnpezY8ywpI2DNL1vJ6n8+QppoLWejpbi6pshbReHXUh6yLjoSfAIR7xIm/fgCTMYiCCnNcc'
    '6/d8OfGim1aCho/dNUHvnCliiT0RfU+faSqr3uTkx+thlXcYoObkRoQqUgU1crH5BOO5paeVtxbBjoP3EFNu33qGiVkYGQSJwE3G'
    '2TMHvNUDYxsTyWRsRuY0YR6L/aLwdIzBo4BCxrk7OYX43Xgu8ayPvIqMozvjMRx3b/r7yOFmhu5oTGRc/5LXkq4UeYFIcGyN/ezz'
    'Mc5iBMbfX4q/a044JC6qBlt4TYcoabp7U9ddSjt0wvVknmJGiVaQrAp/MwPWGsGZi85JbJBJiEwyXtGV3ZdYZ3TmEQGXx6PKYZNZ'
    'u8zMRbhL0dKd6Z6pRaXJ8J1adHLvXkll6cZe1XfMeXc3n/KJErKR30XXj9+8h/qQxxF7V0R4csA1hQyJePWcqEnWxk7eXfqnRa6H'
    'TPRwdPVYLvmw+Srkpg5l0dU/CYwpjtZZFGqu2eMinaxQcmFCzQU/7JC0HtNMsOXJZVZOxVUz7hBW4e5SSytDdL4mUzqevx7wUh4i'
    '1vIOxOXkxNQVzr6/r+osU55pwl8UUFsrR+PduhyN0S/zQtEDwgEiCrm0KLf8sVyKd86Td7Ny4U4reStWcTJafz/BWJpPBjc3C0vg'
    'BNJCyFTEFT0oFt+cQq54NWmVdBtBOtpxZotMKZl0MkQjfLQ+9mHlW1uPW8ta1cnhJwMeuDSnK9wpi7dXdmU8dxBEXdbyfSvZjEj7'
    'KInRsdiaTOq8haHg4dREl6kOmdZ58zOzFTFuM/ExW6Yw4qF1XNhLTuZw5gbXctiBJTI57L9O+QBptC4tYBHMzo63W8JFYs1OIzZS'
    'lrgsmYeJtZdlNY3b+xUqBq61K6YNeZwVgMLM/EysU5k3jtcGPmBfcnYUAawPWCtxNBGKHHJdcm28n+/GlsjVqWu8xLQ2HTFlDZ2G'
    'DEy1O9fU8XFvc72LqTk90oIHakRHHsBVFAKgCB2WxsGFs5n4hIg4KIDRHUS3a1z8x5E/KE/aP85xnDQX2Fze54NYY27Skekj20cO'
    'R5rPacVHfE4iKuJIPtU8snzkcPXuq+d0Mskw6cjhLrpxH+k+DwMlcgW5ZCDlJK4juML6wXgaG2e+yHsmH5wwDZl5rHzhAwvyUKoN'
    'kImNk1nhA8RvEnmol0249Ptj9Ms6Bs4QHSLxh2kipZl3TWXJMysjY4e8eMIJDYrJzHcG2oWKKYY1HsAL55DdzvQ1IRhlo6Op6YOF'
    'YdUZP3mDMfDq49anF5bG6sKzF+DzyL7IOFAGd+6fr8NQDgWN+udI7dsfmsfo/v4reTT/tj2a+03+jkczZYpNzScEwF57fDeVd+ra'
    'VOWdYuClazVllOWKlzH9/FfhERnLMu6UgrnHddph2gxtljZHm3TML6UjuuMGJBY6OZDu9AnbXZw+8Ygo9jgqGbTivGH6fvmop/Mn'
    'E2NUiJiYChb2uz4UABUJx2FRYxnMPj8xVGIM1EOQWoCKnBjuTgJkdvIMPhseTFWgSiE2OdaERSdBymJULHb5VG+OlSets6Hhspo8'
    'guhUFy58Yg5ifUu4STogGVSMW06/f9OlM6m5vlDE4dR34lNgDA5+XEQq2CqPJYcwtpXoHqN+aPjhqNC3hFWq2g6cpPRvFQaI7dbh'
    'qaOdk49W2cOaQ0CUebVjNMrUz1B8LD0ThEUEXWX02xt6gEYT+zljuJpxwD/kmP8gkC95Z/mumsI+Ge8mzl3ttF1aWBoum/Ffcjob'
    'odChOOu9f9jXIjAcib0eCBo+fM4cy06aTMTiN/l058L7j3Ur1+K2gWbHI8pQVAByMvgC2DiCMOmwXPrZhIQ1wKdCkQqWQPC9YzAr'
    'UdPSTtWCG47yIQvVgEeHra+3XrvBtMrvdJmiPY3BzL3KJCqkV2umYjMmWDRAuyarDqatE+Ws6sIKLnQleGXxhMPVCP06JstC5pjs'
    '9crHK1mYMVnMkOuV07jSFsyY7NDKQBCjE6qny2hXfxv3MuSWX7SWiMVFTHbIQ2bV0O54YrKG8RGTHWRaNYP18YnnLv52Zmg43qt2'
    'ZQpPWjVksE5aNXSheBqDlDD26wDBg3ULXrYoaJi7Tc1oNKOpkTyrBDQRsR3AV4jYemaVJd7Hy17nQgqUx1yQuwqUp3EPfLjIH4hd'
    'xcmP7lZR8qOL7Gzf0SV2Xn/rPle2jce58tpLAO8lJLfuUE8ywjVa7IrSvkP5vhwW8Td6pEM3qp37UyOtqLTveHZq/lrPtlU1p+th'
    '6DSeuQDUesS6nTB+fuTuhDf6o/B0mkQ/chF7jrKmtG8a6E1p3yxKkQcXPbv+CJscn3d81vkxYyntW+LPWg7o+Dzic8/PK5oAZnBF'
    'eCXmsp6uqWDFPZHBTWnfEvHnlvNcfI7z0/fV8liV2K1pMlelK7v87SKjPCzAzPXL7e7CqhRc8gH8RrZ3x/kHCN3J8Q0tXh1DYMkw'
    'GEBLqa8Z1RUTinHHqxKCXAHCtHrTJJLJPYDwFpKA87Ltqp+NBSXzUl3R7gRqCjiZa3msSUslI4UiAwEvO8AX19qQNl4s0xmkW7I/'
    'NvbGkCudNmbcVrQrOvuhyyXgFGsy283qel20U8MmA0MTAOohurhYDxPxqsCwIMcXi0wsPxnzvbAxEuK6wdGG3+MlJsZ0rkLHIOXS'
    'hHLN8bwwAAFRTh85inBln8gjtfqIz0mM5STHsPDkObK81ON3CKRcjYO+WFOHkdoZQ040NyVFB5dile+lvi27GnJKvaQAn1/sbn63'
    'a3/g8aQTEvuT/c0+PlIaDgMXtwiWlPv8fOYiY5/fl2Gh6oHc3+xzX5Pfy5h2uMIX+4d9guAJ7r33N987qyvHeMnwufftFx9gpIf2'
    'nPrOSw8qs/IALXpyzaXZtS4+wkMrjmvL6hzD2YMnDN1wqS8XG4z6wtY3gHTyvyOL1O1xqv4BEHlaCJVVXl5yJ0mS5nA+1A4Cvhrr'
    '/dQvxICSQR6h5kQPRBJouhYt82CJ2j+UE2Ty5GBa1Yqznh5JvpjEqRtquImuYPuDm08rcRjQ79eh9Ni2bx23nEGhnBZcCqew0MLR'
    'jMYrMDRwNA8Jo5ioyLcc3WBGci88TkGSE8fsS7juRbHmRfAgfkyGaIBdMtYZ8e1CvljzyCBLkyiynDeybqnJJCmGrWmeiLesIwZb'
    'dw/iAKXkiM8w9GWjd2KlLFLJHHnOqZ95Qs2Iosa8i3b5yPM7ZAv/mYHD9wv+g2wh2Mzyhmh6z7jNRGnuRGnO/Ldn7qjmvy0jsApP'
    'thzlwkk0rXxkYhvj4WJ3KW7dNOzuzVL0m7pFYuiJxRWq9n73TdZ/Y0JWpWF7EtOZLS4upCxOARcunRDOPNI35wTIcGi7gKvmj/4h'
    'sLf/IbB3UUhznoKayQcllw6YlkiX5IdO+zRDFJwrQlLCiTTmTj3h2I7PplV7qkOe6lDn5354fYl6qnI2Ck7HFihqahN2WH1wfIFJ'
    '6ar4U+GfMDLX6+0VWTGHhEQGUo6i9RnhyIk9sor5zVBqJHOKuTS086M0M8knAdC6TNyWyelOOLypkwvL2n/aC8savUHTkSJZ+acR'
    'BngwrCBllJJUmD+OD8KAWk0IyozhqX1xRxkk6RwxqkbTbZuETSP8O7XVRKpYSWzziXobDixh59yupu3gtTTVBYRJkDPzPetkyjVM'
    '4iM/RzW0lOAFloJ9oeZy/RjG3wMeA//wlMZerATtKYHqfMh1qPgIzosQesOVWBcLko5UwzKYFvXh8rAykDCPyL0nq64j/V2cmEco'
    'VzwkSw7tM/7j0LpD4zZt2zRt07JNwwRZ6Yrmxz6tWjRq0qbJ9SbXm1xvcr1JbdXgeoPrDa436iuNM4DmXGSGB5jEi0lkMHPFPtfz'
    '42/MuRUATJUZXIFOKPnlUarhOTUsN6MyY/4enSoHwELs6hP0jK6gPajDrsoPQvvpzqRzUzZ7Lfc6jo8SjDg+YUSTU6zx4shVKLH9'
    'eEsRQRNcNjMWisX1TGfU7MU9wQtVrlmCjmpaeD0BSZpMVEEsOHbP/J0SQfE5WjH0m5ExViwni9v1uadvqiSWoitVrmhG6apykLFW'
    '/8hSDZfwh8R9xIkEKxH8S8j41oQby3OwpoVOE+45hu1Ij0/Z3a6iNhDN7dkRvlrAaTB4QqgNvsmgy1QkKNHMCf3v6ep/4N6Cbq/1'
    'AnUDh9v501uxo4Q3Z3xBOc1LkYeemy8EOoB0Q9CBqxuDrkhQAY5X9CzK+gKvGfdXlY2sQOqqgPCtfKPkDJobX5C6rmb0/gXH46GV'
    'rmYMmjHUjLG/cH/zgwp84/7m/EIFLjVj0YylZuwPOPEiegd08ZKx2fsrLkYzTnvCZNjcl+zZRm4FNI7BPw7A9c/u/cgavsH1AVRG'
    'puYiPIhhfcmVe4cFh8rMqhLIlaeRMFV21xsFuh9UqNZKTWORXNJ6t7VWFvxH71eSoWN/UKmHfS43/D1wm8H3RslOvl+vJG3sK0HS'
    'Qc0almtU7caD60rCxr5vj/szvOfwvTy7Au5n2Fr5ZEJdG12og9eRYbj3c45rE/3gyIQ2hXh0ZPnI5EhzqZcfJ5ZgM46LqmId4cXh'
    '1DfDpn2kNBn0/85j0Pc/MOgzdi/Pccip++zxXVgixGLBgg6NR8KZSswopiiuhpHhP0pFExaSk5+sYGZCLXOTkrnymOkdI9x4020z'
    '/Vq2zo8/DJssVARSOwhVQoBS8KRkpi/M9PUYSs2Ytd8117eC78Vd9Y389guoRvjlqAhjT+VQxgUO97dOPqmTT+pY6XKN2LTu5w5M'
    'XZYg20W5wsAyjHirI83XO7VgIxhThKhIlq117Z/zdmyKK+I6NyLYKxbhJtatYlXNGulE2oekgPzlLAy1uHW//yTRUaYzPke06cqu'
    'ojKhzgKVaJru9QWc8wWNDdCU6wUvEfIip19m0uvzvOIxumqDFGoFCJnxjzDv+wuAX9YDyD+25S9jKQsOgYz64dRZxkdc8NGMl8hz'
    'igMueaT7SPOR61UmIpSFcQUKqVGOo9nG5xi9oUDSoA5URy4dOS5GmOyPN+DjMC02Al9HW4Dauc/tLGCRi5tZtHxxK5N7m1xv8v3k'
    'esZdTG5icFeDW+h8n8erCIae/XDnuP6zzHB/g/ZXfq8b9Mn9GJtzXl+7WMG7rIBc1Imxxi6JsfnULlw4i69lunoR19pqk4ZMWMFa'
    'OLqQq/ecCbM9ML7sgS17YO9vW6J9WRprf9sh/ctKweJ7bJjxbeFc3/bP/LaOCpnIS3NwFdA7HY5F4swOjBNpnK/iqfkVPjjyS5iz'
    'cF6rDk7YhXoW+/2qduj+eHAXRrMa6MrBfKR6dUCssKC7+IuEho0dWd0UJar8omN156OhTqVnS7ALVeEx1su2xiacauZ82dbYgyp+'
    'xBqUbY0tuPar/BLber9t6/a2rdeXbV2/bev5ZVs/j+h8V4K0rzoRYIFkhh/b+nzb1u3btt7ftnX9tq3Xd6lLeXrPV7d5dw/83+4S'
    'E/zxcb1KTmKfCOjA3x0uMbH/TYnJxF+e61VyAsL8KTm5CM655CT8fa63CSBszJjN9UwscLje4XqH6x1KWiAO2CZOciHfhUGgImMT'
    'rJSn7PgpS5k+chwjoWUqULlMbZNHHP+otE4Rmssh+uHgTXc8xiHCz5FRZQb+u8ZM3RPCH2CmWhcSKsFPwhQ/e3wXFAqUvWSPrjDo'
    'nUzGAWoW/g42KDFkYT7/KE+e9dYE6JUpnOa7UXw65w+MhzaoChH4NpFgiRqjpL5OPMYqw2dSMBAf8h1FJmL7w3w4dPyhdhf0PB+O'
    'q4y6KCEq2842fiS2uwHgr9pWtgXqDlO+HchrIvQyKNPo5CyaweBEeVsFrN21wDeloboW4wj0zszPD+X5u/h5zKXx2H71BWRgQY3s'
    'yASqsYB7bGeerge62SmJMN5VCMlcXA3CVFV/cT6m8KAj7VofcOBlNNRl+OLRL2eupZr0KKPaxrIqBZVBxeW6leO0WaciA8c1G9Fx'
    'DZso0cL7baCRchRlHgg88KU0zvpg/qjLz2AXqYwkgCOA0kyjE+ZPex4SI9WYIfK08aSOABCZBIqiiDqBeAlSWG2h1+Iedojegsdz'
    'KVghLpcfylP0Bk4xJ5Fj7qqKU3iomc4Dk9T09hkx3x3XS4TBfmnhqRVmOjUu00FCTmlcZeJ7ZspdtSGLVPlFLcchNT+cQ6N7A1Pt'
    'wng1jTjQvll2LhSEkjbJsKd+LkrR+8ktAQ+ayt/jzrJKXLDKlcYF78wVeF2AddXcdL1waA4zo9dld00o59JgqJ1iLkXKE4DtmICd'
    'OHdc3HJAERoS9g2mAZqiQwFxlyDdSpRGoFhDaVXH5ORn+mLZRQbjJ1/Uphou+/EZHlHmu1PRU3Vt2GYSPZBKCaB8XBhF+kJ8TOkf'
    'EZyB1GobPTw0s0VOWAjjLNAxeri4hmsBsM9pLt3edBeix4iG7oC5jEn6Ivr0oJmLyPHGB/GcjRdy+gEfL+aF6fpreSjVD7xy0US0'
    '2OPSbDJhlUqWUM8mA59Q4Ox8lefNa5eocSPUh3HtHVdR7FTJ43r5SP3Co5va74NZX/iE02GddCAXR+QlQnknNLxRqh8MffURt6e4'
    'zR8svtv8wesD6f5A+gmFHT+dy06fvdmLAsUNjpP5rmiEDHAQUXpAmeGBXjHnvwi5uMRiaGpWacOgeA7WxUtp2Cx9oLx/kAPLeisq'
    'YKKLLXqqCBcuSi/AQ8YUUdX/G+6hSjeuH+dPVdqxflxPkKtf2A7gSqaRusRPM4mzDnkTRSEz4oLH9pSeLMJkJleA7OApXQHQnnN5'
    'cmDoOgMoAKyYKsPeP7BmDgA8kCF1bD7QByq42T9Q4XQYcOqrspvqnI613fYDZ5wfiz4myPmy9/tXVVDlW9cM+VsqzgEoFyEjXVke'
    '8WAC/hAgEQ1SJdP6qmvK6NZT81Re9VD3BLQ/lVLijF2qIaUOdakaKCqmxW+btVcr3f4prtnEjWQ8aRyYCNOfm/qxqvzJxCudKlST'
    '3/auEbtUP1ZMkdxAHJS8UFNOZ0GqVNM6SPPsPPVqYllRT34q29qTJx+AEZYr4pRAzCHUFUCJ2rn+1NUd08RQcYdlovrFqz51ep8M'
    'm2v4lKIK/AupuELyrVC7GG9KU0gTIRow6Ka6eiCGTb4KFnOTnwKDaoKGrp/1qU9s4weEYhNCaWpm/NQ89vLUQ4JYavupldzvOsoH'
    'B6oay/FVf0neMf1uAeObQOTlVdYpNEnS/wzMcEpCl8yX9aoYXVSMuqK0UFHqitMB02OhIvWS1eMK1gJQMmJqwUtcAEruQ0y0ZgfJ'
    '1S7ykgmFKVrME2CBgXRk52dtTqOS1cZkpCIvKncb/IvRB8Iq6wJK5hocudHE5oIoyu+3GJIv8e/UoT5dYYVM/yrOKyKLqmMQwakZ'
    '16g5yqjEzbnz5BjMwuso2ZniGMvnkPsVQGUT+0Gd5iFNd+n+xUmUNy2lPACiOi3MsFQm2QYZTMW+3rcpPW1K24IetqCredkuW9nx'
    'UjfsLYlvyNKSbcIwiNg2y6Y4CRsHHpJCOBeyBUnPzo9WgyYqpaHVZzRFgISvaNgIeWD7wIbQwWf0F8ODDswP1UMeGPzo8BmDH52+'
    'ucG9TN/c5F6Wz5jcy/LNLe5l+/YXD2g/Z/Cjx2dsLnt8+5t7Ob79o3vJrqkDkwPPGfpRAeIasN1D18gecKnp1fis7KdZsWZP7tK9'
    'yKFpIOeOi8niQNWCVMd6nRF/8vSzCRuLTglU1MSzrjxVRVX+PSfX9u9GVSorbSOf0kmjeN/f+7jTKR2+gEmlwUOhmoiYukl3xYdR'
    'Xi5fsm2o0nq+68AqCM8JD0NxcamQomFhbxDAOlIei58jAm1abEEhZB/p/UVbvItp9rsKy+LAJngy2R/tM+OLKInvaTRFbA189+Ae'
    'sn6pUjExq/lbYV/UICpQxoqelclBucAJYyM1vx3eelKTsd/GK53VAFsNMpjLqTgMRILcYeh219jIbu2AW8nSd4f0qWIx8ADjzMXZ'
    '5D4JBedD69Dy5UrTAYfk8pJlhk/0vHyi5+MdPL9ewXMHiQEgyP1VWL2/gueEhwmeKzjcFFbf7+D5G79CWBhgikLG4vojv0DwvLz4'
    'AeebOXARL1dYvb+C50vNUV6EPIhSKPtNZAiXi0qUiKQXZW3K5WD5+Aql84jiGV2vFEekPIZCRA0kq3oHecZrPudX5BTUW+gd48Ab'
    'Vx43ouKuuMoQxKaGXnvqs/rnWzAstfN+yG4oCm8KrSqLvjbXmitJVR3ZmIaHaLe+k1RVuJsKKqcqc1Avg0f2U8zVn2zYk7M6dKHx'
    'Tn8l+ckn3+UAS1Gm4+Hb2uSseEVCH5XlBBc5K5IQk5yVE1zkrGjGIGc1vri6TL81yFg4f6Rm9PJFzgXWyuRcjUbCiWDCFvtGNLK2'
    'xxnq2kKT9SbrfLg7X93rt92ov+BJ18TDs5+E99jlAOU+kcsBo1UuRJ14Vuy7mnlqfwF/ykX+mgAhRGGc+7Rn057N9Tbt2bRn054D'
    'De6hPYfriWLFLMT9OEdCqYOOmIWr0CilRq5p5i5y3zpCw+Dhfri7DqmRC/aAPNJ8Tqs+0n1k+gh3IDLCONKbj7iF3Xcx3EI/d9Hk'
    '94cpfFqxxotQRLNchhTbybazrT5O3AgjSntLe+ZfdDSumI+R/eGYE5QDKNxkrE58yCICutiHWqnxfS7sF1XVA6JuCEphMNU+34cj'
    '1C/kjQYVZMqMap+yk8nNmH9h0t7J/Szaa0WeRXsW7d20d9GeTXs27d20Z9OeQ3sO7T0ObdOeJFGTCEv1keUjzzN+HrKf8vOY/ZxT'
    'XSGP+ElndbGOdB85PkLr0/ySgdx85DGZuQMpQgw+dKOWtus9+mVlCRN2myyAI27hdAunWziHj7iF0y2cbuHyXSy3cLmFyy3cvovt'
    'Fm63cLuF5wkbu4XHLfxQerozXteH5JMj7s/X8RGTgRVamB9sSZUHddUv01mYmlxHlo+4IKrxnPODMf0ccQu7h1M3f0h3C7tbOHwX'
    '4xlzbuF4KEFMLzDqiyQEbpC/EHMAskbv+iDovMd3IuDbCaib67fc5zIrIOKD1fMHNq7YTGXCDpUBxWyO4oVRJQCEBHJYs45vvD5k'
    'mG3IaO+eE4aCF13s65r+5AsOMgJsU3zjaCZYChGIT+vyh29JiGNhloOzoXILfjzpGpYlIeS9zJcSTn6oJni5aKm6qxkhNNUj3lVM'
    'zRwf7MVM8MPScmE7B3R2U0/5WsSbSTV23IEuvGSGs7K9Q+1/1dosbcbXa24CWPavPVdj/fv4l338EXYTFor+RUbBnhkqvtoinGYR'
    'UPNV9/MHdPvjL7scvgcYHBGrMfl3SWV54n18G6CHnpS6IdFmEDC6CkhW5QWP9+74cruUrxIoSoY3xM0uYTIa8fpCI7YHjZr3oNqH'
    'lgtlV5W7aDmyuih5+x6mfFj8KDbKKnNxX8FOgBZfx21ucqM7fnVDDQEKjE4eq5aPEzCgYRjd4Gz3b2amzsT0pnDo5UGqMbUx+XXm'
    'PmbHzuRo4Bqzpz3V8UGBF5phzJWpI86DY2MGZ47XrgzqM99cEeWUNznEh+9hPT7B+IDeHr6H/cDahrbXm+/hPLA2Bvb14nuQo/nh'
    'e5gPTml8+Hsfvof1YJxYj68338OHJ40V3QkSlnwnSIaKtI28YiI3Lmu8+PzNBlEeR3Q8BP6J+MJwwYcdad+AE5PRg98ruDXYMplL'
    '+Mojezx4NBlaINVGbhimGt/Xh/BBg2q0N0SP1hNgGGD2OJoX4WF0M/nn29S7pf+pv/2wbiAFIGqAS2U3I9EBslXhgbjy367ovaxU'
    'eCSA7SmBAmxP5iiwvfHoXAxVTQzNMtP0FZpX/wPH7fofoaGUlxuZrLuvr886DkNMh8lSMkhHEZY08zO/+ZMdd29RJxZp51Rx+GsW'
    'IFsCYH8Q/Z0QoG9LYlz+UB9RMX+Y/rAfIih/qOetoQSNOelhRCaTO1YyRZYy2l4VZ/PyCFeFGPehJb7g8L9EBnGUHtri4R1CL+U7'
    'EGn+6Dw5djItBPYPaJ5T10t+YAogFPkPsU0KfXDu+tBRdhE1YKEYXQCG5467OZ7Qcqpm/Mlz8ogt0ZfyyGNhU+mfocTuMPdl1ZfH'
    '37DiVTo4nBEGR1N+DXJMpEdEpjnC5lB2sQkkKXB0SpIpIiet1SeSZhhqhZkle/r1ZmbJPCurxMgFm1zvSNBTU7Z2XBbj7KJYLSIu'
    'GhCkqkhwiOpT2ERXxclMdF1c9HgVP3cFtHUeJagyNxUylDhHKyq3m7rNEcD8hHVkclZE9y2jGEOAggR1Cpcf2IAwTRLzlZEKVWq2'
    'CRtLyd/PHOdWXjGTDglsb/RgSFsofZyqOCcAcVxlKN7w+qh3SAtCadmHT8EMp6rzEEuU62er0PYD/d4mCYYxnvRn7i4NTvjJ7cER'
    'TJmkfaAfTtu15UwWNzXJDk0UY83Jom8XkfWFXhcsDFu85+lm91wvMtPCyVt/u/cDcTzix9auHma62F1d/lg0ywo0D6l6fxeXhPVu'
    'ymPL2JIpsK7t8QFKeWv75BKOvQQF5RCiaNUHQOU2NwzsVk5Zneqfsz1+IfA3tzwHEG0abvq8OOCGWSFjuumTiNd0w6yQ4Uf/KGQs'
    'N2zXl4YGRQAHn+IhyRBLhZt+96ED86IyMhcNO8cHKFJzhiamfh3YTuI0sGzNB1zwRsPCls4Dzr+EgZggH7N3hENxTDLpoPOxLreD'
    '0pI1vXwAHtGO1nIihRazcIeP4JjpxAdwrZ9St/cRztHS/R8+Kbf5hz6RHB65VHZ/2OO7KjcNkns52Y9P9HtUFvNFZTE+VBaPG/4p'
    'bhM+pCtvQGHZJvx7WRcOBHyRzu5RpePWFIWQ24BXpgHHMAIRLVfkExe6jWAREe6BTPpXV+NbiXq/5A42COhDYRwyvvWld9UAKgoB'
    '51iokI/jDfobxZKz68VQY8EVipg0j4SrsCFnXFj0s70EKdp8tPMa8sUydtpvavR0XvTZ3P7GEacmJbqhSfm//cb+G7/R0X4i6K1Q'
    'NGBVHYsFbldz2jDL0TKcUW02saaHic4xwWJ5BjBSnIE42eY4rKRYJfUDW/FYvCRVXBVK5xKAs9FomAR5hJ06xE6LiKu30m7ZBQYy'
    'PS5dyBZOkXepbkvR9SFspOlICMd3MBJTFAt7wZiAFGNFfKTilFf723rIS8+ejOrHGSei8GQ22zvnOd/ZUKVGnSh13rR/Z1XXV841'
    '01ivjGxzvnbjfdfvjFz9zsjtx/v+nYxcO191Yr/NyF2P9/17GbnyeN+/l5Grj/f9exm59njfv5eR64/3/f9oRq7/kxm58U9m5OYf'
    'ZeTwAr671/XHhWY0Rppy/1SWfPxfy5Kf/2tZ8vZ/I0te/ihLvq7/F2TJ39nN8Z37PF+Z0SdRun/70gbcmCLIk8d4ZB2k9BvSc5WM'
    'lKZ1ZeLQKW4IbP9IIynRI0ASBxreeH8HetiOTd+AOx1rzXuGBliNWLVRNhWdEIPDksuQep1LAjO5GApNKbSiWBsP8jR4W/YVuvCB'
    'FrFJ91i8NAPU+NSaHE8gXIepuohJnfFKRspcyWN6vvv6QlmvysBfovkUDE3+1Mah2RI72FBo3U2aBUEhAW8DRnmGGXdclvfoHkHS'
    'f6FCn93hvArjivSCU7uJVyztKWHCo0c0+Io2kYyGqvkBatNBXB2oVzusyef8Ro7AHvm4HMVHSO9J0xZCgAPZK3net2U/AVyLfCjo'
    'vZnEZPGEIWLLPn3dJWLEmATFB3Y/3jXettFG7GrzzsKy39SXIGgq2PtLC4/M+hnOVhQ06y5sqEsyVmnZD/RWj4M7T03D5QoP84lB'
    'LLhfMK+szKiwYGa4R119UXXRTCyYHPLmYi5PPcf84sdGPr0+zKR9uCDjMufBBeF21nBV58h85JEkWH9xhHNk4/9HtvHrH5HQPXmW'
    '8zbn2eO7un/IBhF0RhwR6l/itjDwKoo6JBIladCcHMaL9T3h1TlJqEbC4p56PlZ71MOJ+eEi1KPpImeTYZ6gJjhw8tTZObieUdLo'
    '9TJ8oYHa4zeG7/6N4dt9979v+J4/oJAo/xSLlP9YA/wIVaLSj4JeUt5yqg9d4vRNPVnosjNOi0siNfafOKIWSrFYdNntRZe95kuq'
    'OPHpBZIgIvKuNoazx3TRb363+dO/MzBYcyLqPmRgrr+wAccLlUUU2zYgiRFsQHiPHxuQxIhtQBIjL1TWeNmAZG9eqKx3BoaA+QuV'
    '9c7AtDd5tym2K5Xip39lYDYhetWYRxf6ysBc3xmY+Z2BKd8ZmPWdgalfGZhB2kRGTBntKwMD/3ix6G//zsDQDBlNhSdZ9GALSQJL'
    'JvIki4zrQnLBGRhTbLtihWZAM2WKbRnXptguMq7h2EZCmecoy/qogUK68QxlVW/ot6WtrKbJol7Qby9rKw+zA8yHfltaQ33Y3BtP'
    'Noas6jB2kkckFgcMTiHe6tuspPQfU/uxPost3rCqfjgsku0sw2gi2Y413STbGZOuItlG5CrYNcXOmCwZDxF3P3yOSMv4kHLPAil3'
    'qyLZhpR7XR8i7tVf5Nv7Rbgdv791PCq4FJ9Nat6HZPvEbx7rUcSPqhBG8d4my6ArigJjZhc1b4NTW7S8rP9dqQXqvbvsULiGevmI'
    'bVU9GRW+IMLVixau//ipsq9/sHBpiSImVT+fvZBBmdTefjF8caLR69eHLke5LXPeFBLubXwS7pXkKPQFw7X8KIWGeXNUrXT/vxWL'
    'Pmi4qU5bD24YaSczd6CiQW1l1twM4GDoN4t5ker3ZLoW86zVGobl+yaV82X4Q2QXarU4s+Jjuc3avKr6lYfjsH5UJIfKYQrA/aFN'
    'ZdvZJovA0kpnSN8H6G+eKH2Y/hDlAfljlz9Uf4gFVwStrvaNI2lpNQpxVC0/IUjOaE9Y7gl2idizCjEW/AQFXvSM9YpLIH0hayN1'
    'SIQm5tu2+iih6aJa6vjBDYJ9Yc9KqRMK7WCC9VpVWR27SvJZ9gANDCSqUOSSTcKMPTQJk7pWazRtqVdXDdaqlEVWCU369/mU3xMA'
    'zO3i+0Mh49mIgFHB6dtpxDAj3dCEV8rUG8QbfToNSLEBIubJGt+EQUz1m+Wqhaea5dBrs06KyL0KuUJRqUFjXh1+1IdUpacSNtkp'
    'alYQsL7ryMWR6AJisFg+Mnyk+0hAxgfqb6qN4sBmf7LvodTYr/7+MxywOnObmjRHLBqOSutD4+7KoLBMOjbnzeCQlVvwKyU5R974'
    'mI6oFdVAVBVNU7iWN96+oIRx42KDReMqb/xC/ljkIIWioQOOa9cPqCyFDKDebtNF0XrF0zy1FGg/EVv8uKLYppPO8NvGcEEtIScZ'
    'MUxvisHuNkzrFUOqPYCPbJBAjUre9bxh3fl4iMNewcEuezjq9dp4hQUvjQI9MflxMlnbM0hRlusUhnedLe11xUdXQQQazjR2oVAr'
    '2j2SptGODG+QSW06GJt4Brk3DwykQNhkRIglYC4H0MYTTbP1acrT8UTTsFplz8jsIZoGQEQxM11RwUEMIgibMIguk6GONxnqeJOh'
    'jocMdb8ML0RQPmSoj7Fmm+4hQ30MPNuBDxnqYxQ+xuP1bVn2L7vzxYU6vrlQx4uvyRZt/bJ30QR/rOHybSvPb0v6+razibXSjBcX'
    '6njRDo9GIgY6pm3qYPdQkapkjuddynJ95LG0CDoThPDugFltQtRSqf7XRDGIyePR5kQSaM+Cnv2GkqIJtTEfXWXxGzzEG4gFTKss'
    'nxcXQU5esHyszxhLuUg4ByrEG4oRipkxvKesJo2iVNTqFotgw3/KkGMgBXGtF5wBjWG4CSBlvGuKDumRSJ4Eh+Ynf7GRnraG+97f'
    'b6g2T8+6/vdcMZgr8Cft1pZvP5Zve3s4Yd9+rKFbeLntoV9A4LLTF6w6NT65DPBvtXxJRTmXUcqXCBX4tyeXQbcX5O1RjnIuo33p'
    'StmthT5vG3t2fbm1az5EvePFl8cImush+R0vvjyaAV8emLInl9GeF/G8mP7Sph/XM+BULjOgZnANouAzMVxzEQma+aLRbHDDAGUq'
    'ivMq/vmYDBT5rFYxMC16gSytOBSKWnVMNsRzSbBmwvHSh+kAbyF/kro4CAweKZ1nfFjT3bqIHi/l/CjGLAKRrP6JPC9xry1Qbkv8'
    'OpOo2DxPTDsWv6ng2CR8OEVTH7UOTSinTR68CQ0VhnMXu0BsN8LMDeZwGAWahAYOsvB4uMdlMU0gnUXVjBI8hwR7R7sgw9yTsqBh'
    'rDzVQSgjwydjHhaS46D6Pgel4STMUaYQpqufsHIuk+CjUPLkhQHYH8hgOhkKUxJR0V0hkWtQHMS2IpixLBcNIfuqD6G7EPodO1lW'
    'pKAERbeQfskGu8RbWnpLyk8Qvo1tKoihKBrbhsreHkCSRCaQns8iAR0daCOsTMKqkFPO13AgRThgCyJgflBEG5edy8WHJ0HxQJEG'
    'DInJlJCjYSD7Iboyx85jBFUPpXRrk79SbFswDaVnqOJrO2muPU+RkMkaLFGVZv2XCKYU+BNf2i4T/OKiHC1di0xdWHYAl8CKnQNu'
    'pvyQJz8G+qy21Lst9WHPZNozWRA5xRI9H+Q5gsI68pwT1ryONAvMbo6k744yFEf6hyJKR+JDsXugI8NHLh8xsVT49xORXo64hcUt'
    'vNzCyy283MKLFiamYxrcoSPdR2hhcmlN09QVACgcGT5y+QgtTF90OmquI8VHCkcmLcwPOlJ95HFy3MKvN3g5/nH5DRYSQEl9oTe4'
    '7JmTYEkGAr1Bm13zwTM4yC016UYY4vHQwh8vBK+rLS+khoNT8YlZYIWlfm++wYxiVFgUMqdwObkgwqwFyVeyc1hw7MC0VCVhCb1K'
    'vkpF6VFye/zqxLcdbLPaeJXwmsEGmVDdfcyGZuUmg4qqMnMuUNtwqqRy03Z8oeKqFdtnyYaW5E0LQvBaDYROGy/DVE4gPqPyeZWf'
    'l0vWkSPuot3dr7v7dXfR7i7a3f26u19zF23uos3dr7n7VXfR6i5a3f2qu19xC4tbWNzC4hZebuHlFl5u4eUWXm6hueEODTy079C8'
    'Q+s2jdu0bdO0TcsWY2cxdBbNWrRq0vBJuydNmrRo0OhBmwftGbRn0OBBezvt6bSn095OexvtabSn0d7m6chz4TMVeib0xON5xz3B'
    'HcFP0A+Q++F2+JYvNX6byHgao5mGKtD8nzjQfPU/KGBQhcIEn6jP83cBi7Dxrz9g41dkiBwk0lrFOcsjMu6IE0lLrYuVrVNPXqW5'
    '8LDvJJPXVPAtxuAAQ9ceKj5gF9gKmkI6Mwlibp3tRPfxURO/OF/KiDCmlQeuK8ztE5I6fKj+8PCg9G5qx4sPFbhlzmHijbMhMP2h'
    'P/yy1pG7+J3NNiaToaK0NIGOcQRZFGJj4kKh4JD83SAMFktdGn1l4CrXH5epyvVLArnYnWo2OuFTtw653NQViGNReP9b4XP9Un/3'
    'mhdsb6hrQZdXLqBY8FyUfr6lq46lraBIC+b9I/Djgl1lkzBMm66ZLKBQ/3/AKS6AiWbdbJihzZM5BaImnWS3se/60cn+hmsm2ne5'
    'OvyZTi8gag+pjo4sH9nTV+HIZx1sD83OefWqbebQbOrZXoAgFEtK513eXDqBut0Fc7lAJFwU88xaiusDdMqhtjCPWco6NFMd4uLo'
    'rgWXrGvGTm/nTPfFqTdRzVstYSU5uVQdpdO6SC8cpMBxKysgTsFMCCFgxDTy6NIXbQ81SQWxYgCvq3b6S7uhXj9cRTgapf8X4ICk'
    'ihMStHwT6pSHUKe+IAZQ3RPpFDXTUJTIUMHrgxQcVLtlqQjFbh9mHbP1v4SdqHwD+bkc5VThk0L1uTMd5Xwko0CaKmQ33vlcgg0K'
    'RXxLPjUzFhPl/Eg+6aKCca75lnzSRZWs3rqowikwuSjBfXRRhWFggAFueoHzUwDnUTFTNj3ZqPsn1/5bwSfghuTpfyv4BNyQHP9v'
    'BJ+g9Dc+4LeCTzSj798VfKIZg+BP+ScFn65/SvAJ0GVsf0/wyZ1iP911ukIWtYzEhYcZx+Ao/VPtG0iArW0jFQc77iRB51ILYE8u'
    'wcAry+xs1mjIkJ/VKC+Z8ZPMXiWcmmFRpxqKyGNirq5W/EVCo1ICv6gob1jxIlEm7HkQZroIex4JMMXxhtm+Oe5nUxGPrfb97InU'
    'FxbbddLtmyzJKN3xjdQu30jt+Y3Urk+ddFfg+S2e5bpVY7F1IcOB0dKyDlcBx319CW9d8wmeO7rZtdwhT/Ol/9WeznJ995nnOeGn'
    'Cjp4PdDtdIy2GLFjQj4cH0jdZpRxLahnKYtboo/PmqYLBdyMhEwjPsMCsJ50pu1nITdg+yQ4VedbcgkN0pQgMKeP0toGXAZfaZMt'
    'CcdPkU5DM2dbExThw8vfIGeoxYqsVrJc0CpWBQk/4q3Vog6mAopsuEnjGny1x8LczQxxiywj1EXvAjgVeb54GA+lsBth5cNT2qAj'
    'Dg9pUTCzeUbhbw6RqecjmsSbFhG+eB9h0izSmdZdX2Qkk9RPxRcFJtuM+MXfpTgjlI6OpyYJe8PIlnCrInwuTpyK8CVH0hLGeSM9'
    '37V8pcecBXVychKn2UyrcUTy2EA7R+Qyg7DXJ1CafOjUxyyc/U9UVBZ5hkWrrS2zCmLuWCdC9PLag2x+PAFUfemAamcfUvCM78FN'
    'r7y8NQjYX+yTdjbvZINfNuJ6uT/hm6UxndZ0mtNpz6A9g/YM2mOS8oHedFhysT9pz6Q9k/ZO2rtoz6I9i/Yu2rtNi0l7Nu3dtPfQ'
    'nkN7znh4NbVPe87x82x+oH6Clx/htT+p+foQyOjI8hGn76vfWrXaR50+glVb2mP52hbe9sIiOCR7edqCpqVZFThQPNaRTuM/53Rz'
    'wvfu9+1zms9pw0eecy4fsVJF9Tl1+EjxEZ9TpnHY00d8TuEhSLecZZIj1Uf8MB/d8uOHeRylPn4p269pP/366eju+dtDYXtsrPFR'
    'ROeIX8rya5rchfTPG9WAg0yljgy/3OEW+l0Uv4t0ugfedzXJDkfcQr+L4ndR/C4y1qUjvgu/i+w2Kgs+eDvVWB2LWtxHFCL5Tx8s'
    '3vojJfN2/UBv7vI56lQ+3wXcQ0uDaMqqsE3JtKSCxQafKEx6WnNNbPcjphDlkTRbO1RpqqhFGgai3sYq1CjddP1kW1bIzSlZi2to'
    'q4nfYyBcopic9GDKRw+mvZKRk1qJxSK/KXOgDjEDI1e1HozVXxqGkUoSKjej1Psxws3J6AsotvIh2zzN0a9qt5A1br4+xFCq3bFG'
    '8V9USN/FdV1+I6Dzen48T0YeYKiu2HCGzjW7Znx7E13LnAGxF6KlG+LfDu113OGj0aFAfIbmmyPgkykkhQ4eLYscEBeKE4+UZ4bd'
    'x/jo1xgdsbBDqZGVhS1LPSvGobtZH7ampliPeIk1XzfVAHWFRAHa7vGqZ7Ks94K+0FGJpUh+5x0NqJSjVDN7T5RuGmFdlfy+iMNn'
    'bKehL/LIEmYfSt+/f3GtXa4MJvCgPrQsoHKoazk4OFIHukB2Rt8Q9Xq8imzGcYh1boM1D30oo7zNrKyTSkFlxY0tjQh2GiVDvTTG'
    'NnllBRfpvQ+h2VLpGfNWktUn6XyjiLamqFVkcgGSiTLzbotUb/ONw0rTpS2UKQkV9u2MwBBjV/FUyt4/JZDB7680RAZfYigh9jKR'
    'm+g4KYsq64wTujz/UYNsHtPXW5vy+A2ZHCWLdzJ21KxeUi1zuq1e8gif+pw6rVWyrV5i7ZQE8GR1n6WmVGZ3WVhzWmrzoEJVxkeG'
    't5S3UK//+Eu9BE91d6uXVNRLDuol5zfqJfOtXjL109fisXXUTKxeUlAz6QxYIXUS3YchYc2cTmXVfldnVIloFtjEwpZYuHYNBoaF'
    'mk+DqmHhArby0TzO3o9m13S+a3yQTmGui3bY6ibXTyHMOonZKU3RUDdRmiBZ4bAFNGUjXR82KJCagWOIETGwD8iJDvJfQ33TYiad'
    'IAtiJqZMg8UICT0x3w7JlSwQM+WnvCv/9lMePD+1IHDnGAxXAQwDlavtS8yk7EfMpBAafImZXPtbzATFFbG+nf1omYiHy1om4o23'
    'lgnyJSqplF9nLZOSUJihUtwiiYUhGq9UL1G14p6PesmW5tZHvQSs11BJxdLU31XYucajXjLTT2hyT6bivE0+27oePor7+S2I7sTZ'
    'A3o/52XV9M+LkFN25EfbW1omU71HOoqDegJFJyzSKDzO/ROSaFTRxhGk1pxIqt49ostIdh5KOFgm0TLpPwmyzDHfpUtE6WqWKfSf'
    '+qnnCIYNTT8xnZWUNqkIiJSUGkn5EunxkoRqmgEptG0KHAx8ZAGKzN8j8obxYdPNILXw5Se9fXxh5EswBZAvqYInI19CRXHWVcpW'
    'nBcwncz3Zbi+ozPY5fpbv2RqxYyUU6oqAO1Z1sFQivrRL0ETJT3TAa0w+iWCHrz0S9pv9EvWS7/EGmGodWUdBsXRp0Mjt1/6JUNK'
    'ZA0ViMiqt4F+SZHOSFrS8/FwKzSM2c7o14S8pVeypUI30IyIMdFVGJG2YoyYoRC/9EmmUA4J1RDRUeIgFnonIUeSI+1CJWKiZ0J2'
    '+aD3sI3RucjCJqrkWICyI3VrXvg5zD8J1Wqd05TxBa2TaSxSdVp+OlH/SOhqHPmcBNRYvq8jwyEbLd6TjLtHgvEA0CioXyqDeVHi'
    '26bXey/qucrkMj/fKvLTZfgP924cMfJcBczTFD1OPUkizXpzOW/Ewj/cnmxGLPxjWI7NUtZjW7LtsPJbOzrHSJrU0+iS5bV/LsvD'
    'OTiwLkvIoV2WgTAhUJyUyyLkjxTdsqTdUOf8lDdnPGRY129Y85LQe9nb1ig6ZqoiOcYrtUeqbzB8wrE9Vvqrpi0+27Fw9MwUEAs3'
    'vxk2dRmv1IajDehG12asTSLXcmgU6pUSuZaDp1uh7xAKyBk/0RwGwnQrBqYhEDZ1ru2HMZSW54BIJEdRQmPSWtiAkrJwZsCB9VR5'
    'yLla1aiZjkme2I5DSdhsxtrYE5v9jYCLYJuqgIzHSQjH5GSFkbePvCvKpsvPHnUPHXnG13mNrwfiNywaM5s1W9ZLAOY/c6X6fW9/'
    'EGRQbboWH7M6e4/vVKL+O1TPk3JA5bWT0emL61mbKWpiGIofrYDg+J+vbUUemXRRbNt+bYcYjRPbsUnXbA39wRSwYaw5VDVZaF5M'
    'A0neb9nVYq6kYvCVnLVutKs5JzvVav3TvK/mXqLqS3DHVS2KimaUFAGygsfiRi4lLtbXExI0w110W01F1yP22F9ETpmibt21YwXO'
    'hGTPJAa54QmabM0bVMHcvzYQMpfyOzzQ/ekDtRjQxSjwWLScJy6AJg+RbcR2sX9Is7+iNY0oQltvvorh5EyDYirgHUDGOsuO+pDs'
    '2FRuAwqWL6ND3Becf8M0nMdoAaeMbN+LHmBZmXbj62UIs++vrtNQxWziT0x/FcjqIs408ewGEddKsKXjULYXifQlpcRDSewWPfNC'
    'jWPkyYVq2tR8gcUES14iU108O030saLwEahcjKH5DTr27VMX1V51Ue1dF9XedVHtqYtSccenLqo9dVGqNgAxIE6UT11Ue9dFtXdd'
    'VHvXRbV3XVR710W1d11Ue9dFtXddVHsQA7pNEAO66Kcuqj2IAV30UxfVPogB6lheZVHthRiguOJVFtVeiAEe8qssqr0QAwXGmE9Z'
    'VHvJ2PMmXmVR7Rsx0L7Loto3YqB9CkImzXghBtoLMUAzXoiB9kEMbJrhMhWaYcQAnYISl0MznCKmkWc/+eT2Si8vdpcJJBrEMcSE'
    '2vnsQlfsKp3GT/FtFPq3T9I7QDvjszsmJ7dEHoxFaRi8tfGwQHllKMj7sV419hn3/Xrt10oNGTreRVGu3Gc2GP6eJWfy/aQ5k+8n'
    '0a7F94vfkz6DkQtNS1nsO5DE329Y2DL8MwRj/MxGclPT+hSX8kBDvVLwEdyWvAItHAN6n1JcxoFwrpXKMvbkuHuFOfMcEwwWLPUL'
    'VhPR8YURrxxSx0DP6Z++IAM9LP4MUSdT61QQVen8Y7hlhQ63ZIajYI4X2ORU0VKg5lIuapq6EKNQwsmXi1j2oYbieKGP7PcwSXUB'
    'IlOceeBI5UgUhxRQNRzxkrX8O8l6TdiJZe2BT5KZ/4jmiWT4L9e3qmrdwKI15vz2Un14f7+hRwOr3SE0zGBSRwP3Kg8h1eD7ASgp'
    'l75LIZ1UmSCqbuz35PvJ7y0r4x72h/YX52++X5y/+fvF+SJeqMLmwUeW+16vHwJQc+Omw3ANzLDl8qQlqae+rc10WPMtzRQxngWd'
    'brV8zmUBm3pcpgY8RPmHakLxpIhawGVF4mWJpurStfFi/4Wf1Mm0ZnHOWS3axJBLG1PqWabdnvihia/UEes5jeX+9cp1cqS/etzA'
    '95Fx8/zgdD50gsz+z5+04+9yV9GpzMOBCaa913dV0f5UMaLgX9LDsMQoTpUDFr5SxeLo/wq8C98itAWV8dY1b655R068QZfSxNjW'
    'xa8dNq5kaKcyJUNkcgO2hyzTMtfbq8a8gcSESXmQLJqmTGN920xgjxdRTGXWTDOrKemYmnTgtWey8bJrfrnO57IP+pRw/GWyEcJU'
    'pYWSl7RQnoBg7tUB2SozU1zsOICvN5ecOV1JUeUCZkTN8LWex8RT4xkuUX4dSuFKBQ1/wOROgD+VXCfo+AmpmN/e8zbz3S4xkKXk'
    'Kr78VGiBMhpFxiSu+5SHuB5LLnW4xEOZ58ywNaJKkRrsEPgPsXNllOypsXoyqI1vUjMzGxgsu5YAqbZJVOWUGb3CWrapQRNkejjG'
    'FDOCzHynfKLydmnRzPyzKMZEsMXKXZGNL8sLipIQLrqBPLxadlhQr3aePPoQhUObJGuZVig8LcOzglVTFZaJx1YFI1JU7hDxUIiw'
    '6eElCceViHqC9IrTXYrJJBkGOtmbOtok3KE49ACEm4/0HcWpC9x8JLiUWZzWDVQt5hD9c7wDkkYpwmwlWqqWlNcFKHA61pWi/jIf'
    'GrZGOrsIf2uIZvhrDOfmhkCgfZI5m7woZ7aq0ODXQAldYNUkoqUxE7rY9oqimFhh/iBAPVRfkcUkWkwjq7FzYtzyhBaKegniElEi'
    'K1aT59+RHFfg8KJu1gV6kBl1i3VDChMDqU9KjQ5PlW0dDgV30xjNd/FW/pYr+odL+b3opMa3AncXQ6cYm6SApJXMcsQ4nzqcG23L'
    'SVxjkxTdJRygI4sj9p414CZyAjnV9uecxZGMm0zgfRk3EcHSsanYPYIRpM5pXUn+p6nUIWdTp8mRRCPeHcv1naayGg69kAXjciyX'
    'euGETi+bpRk8sPiYQp2Xay/qC53y0X67LldAcglVkdavWO6k2jJjua4rrZerhzzDVXieVZccaYPfxHKXyhPTQbqqy3b7Vyy3/jaW'
    'G1H938Ry11/Ecrt6owLRBVjXJ5bbDJT4juWOv4jl1ncsd6Fo+4nlbtINn1jucb2jY7kVJoTfxnLXX8Ry+zuWW/84lru+Yrn9Hct1'
    'nFbE6AakZAh3W8y5ycriyHOO/6r4nOK/Kj6n+FqX21PcwszvVA/zSQqouGxyaH2sGOt555vsjMuVN1mkQyR8kWaK15PwEIoGNwW9'
    'kS5Lvq+hdzSxWuJVjfaBrCRMTZljQaimeoLTfYHbib6S8DxxCueC38HYhOXUlbUUEHVgQ0yt2FlzbvmjrTRgEyt25lIG+uw5EBp8'
    '703A3yP572qu1A1/VRkftdPhdASD1u0s5dEWFMBV4/4pB9TE0CmE6po5OjQDqNznsI+AS0494VjvzCZPMr8rOf8GRlcEDDW1NdHj'
    'j4++QhAKs27IGUCQsCkLtmCeUJbMZY6SCVoP4VRs8fJzL7+rnFnzu8qZNa9XSaeWvF457EVEOWPvrG9dNksGDsSMKBbDqPKCGDET'
    '9EhBdeIfct/CqYw/FuBwCg6QQYsO98cPC6JGi2izLnna+qUIf8tG2kI+D+HFt3g9hkTfMyct4AWAmHlZi3wJs9dVOZWw9pE+eVDp'
    'oqyh9XyqCzcRrk9RTlRRhUD0VlXxNQXCH2KZ6DjKYz3UUEmNcqV5NaBBnwJr8KdZQLYSkwPBVzz7iotamR0bVRfd0BvHnKCAVVgm'
    'kwzHVlT3Cu01O7+axQYWJRGCUHk9Th6QiS+iI92QLq/QlzOpgll1PET7vRnbsoktmFVVgOpjyukNC1VF4Y9yIMVRKIFfJbTFcr0w'
    'UBTbEtdkhrZcKziVUT1gvad5oQ64qq0VWDirC6IosYImJyDUhRtWbUW4qCChZCamnQXlYQP1ttBEcAY14yoh0ELp0YIotyKmk308'
    'kQVab+VtF5iX6PWRXMVQmBYRW1ppvVIWs1Bvwg9Nq6ygi1NuyoLrcGZ8NSt1kCXirwaFqBMSRrI6iB+O60OMHMH/Iwsa1KZ224+Z'
    'iUj+kefpLrslfr7IpxFdXy/VQ+qNqiBb1d/q5MK3Rb9c+DbcoJfQeREYLOJocBRJmaCfh4/7EFO7EmS2FRo+SRwWj01Fu0VZilj+'
    'Ijwp6oBh+doc2Flyo1rUKfhexB1FhJgGuxJuQ1C/tX87W3xPBAPTfkpQcUIuE70kdhF4TDJ++lKpYkginxmxaDEdbHBoW2mXDXvT'
    'VvrlAE5ON7Ch8NJzeKxmIn4hIlcz95POW7C2FsZ27k/L/lKJVHk7+ZcLUiAV6qMr1gDGFQBryrFeaPQ9mtIXE9G07O5lflJHyy7o'
    'cych5QPk1BUvBz7HiLwBrxGl0CXU07H8+NaaftCaSooiq+8tFTbFs90s06N8aqcHEsa7U6gFkcBWRY0U27HuY/ROyIPDtl/1cQkT'
    'x7TwQdIgElWkvPYmi93USA2YiGXSK7ywDi9VrO6Yi49ZJI4qhQRPhde2UuSw5Vq6wijGVBU2WQYSQZZkGSowf0qOIq8DVWn3ZcTL'
    '0nFcmkI1Sfmukqu+IYSOWGKalF2ILQczThqOXfjrJrQ8bnDspQ8v/gyZsItIk1yBJXM7907uxVSVxrTQGS1PXwqs/heGWqz1B5QX'
    '80dafhWyrtyZ4kGVdGHiDdOVUhV5VwXqbBb87bAWS/L3fIrJC7GIgvgsoUy5ZXDOF8X4Yru7RRm6CynAAWipvlyueAjEZgpEdkPh'
    'yLyc3qjE1/sjZmIsRNWlMog83pjXhsCY7LAj9OeWptWcxmZKymSSqioMW8ogSdsfgbGoG6ggLNJmoagtZhLLY23pw4lbDuQAvAKP'
    'GiAyFlnfM9ECEj1WDIxVzI6MapFYzuIH52XNi2JWSGtVVLir9JxTpoo66k1abrLtwOAr29emaUMh0NFmqTpIjBouCxKjxlb3yqJs'
    'SrPXq8OJlbGpqnqImxFy4wCHAfLv853dJs+DXvuRzZiZM4Wpk4GNelMzsQ3JpDRqYp8SNrJiLmut2JTno7F6ISSp7H4sT8d0gmYh'
    'bQ+h/qBWdlETu6nYJ3+E/kPaDNmR3dlV/QW/sJJAySVXoFdqaA6oCxzo6D75xyS8G06Q7pfEYMG6HEpXhPM8sVyNWKoUmPT2Ictt'
    'UOlewqcf2Da35CYWqcIxf+ibnZFG4bESgClGccScvfKHpv5QBL1tkAlPPYs0KTpCr0kPGB8zWQ+iHVSDdgQmwKSlvJx++4Ps+rQU'
    'VRP9qhDxjWsIPqK+9ZGimo8UlaDwHymq+UhRqTkSHZi6KFJUao7UH5YuihSVmvORopqPFJWa85Gimg95rprzkaKaL/JcnsJLimq+'
    'yHPJvL6kqOaLPNfFMx6CMKZ29ifMqQf7vYiSPHkBlraLyN9xdVcxSZA9BsVDL6fUdnM2xnXQ5qgsTq99BE+7/JNC/UWBu5/3m0sN'
    'ikqDkoZBdm2Q13ZB7qDq0UxDk8DXZPo1lnEJf7NIrC7Vvi2KJ7cmoyxOqZLBDYUiTj5iA93M1odvqcnM6eNMNJzwBc8GtleU7yvX'
    'Z4aDmqmRmR8E5hoKAQP1m2434v/um5zaThaH9DAb5KbJgtFMw2Mte/FH7uk3aerPvl/IwkoPA4bYnxv+PICdT/OAzhabqnVqSXAe'
    'i1g1OFLTPE5YfpaROe+bgd6GZSwj23QKbdkON7lk9worcknDIItViTpUBaJTwpjRvaZ8T3XZLsaDJu7Bmpt8WukejGr6S2tiDSoT'
    'sqmVyuAyLcRbn2Ud8T+lrSZJgEQKNIwqlUGY/lVkfGjKcATUdn7VLM2VR1b1ke4jzzlopOZA1ZHDL2/yV2l9LRg51ObwERe6SRxZ'
    'WrQScyM+6EMVbK5M2AwyVwopssTBzPYqlMsVbqIEiXS5syVJfIGyo/I5SYVNjbggO+1ZDi2w21xed00LnlMfIwiR1XgvN7UBO1Ic'
    'qrgSMKM3Ll6XRn3BjiooyT3avaU54UdEJ6GcAPJPcaSJlNQG1n8AiW1UzA65okzNhHNLNmlRDaoc0GF1Z5WPfZJNAnkdQF4dEJi8'
    '8QoRcu5TvDyoM5jMGOLUPA/LeFoJ984keJaPDj70mC8yFPfUQimXXMd+OLHFyAlZT9Qv8jVsMuV1dhnalXh6VVVaknH7nWj5cSqo'
    'wL7togX1n4YkCSzo+rabkKadF782RoP0HrNQcb4IaVhkjTZkCTbdNgu0kYo4GeAYF4V1ptvu7AoDObFwTbfNem38JM0w3TbNMPbS'
    'KCuYnmiG6expJKjORjMsHdq+awPPd21gf1Ylmw1YEV50frsYTX8PqZXMdO4mwp1EtRTOGlozL6jS0PjLwJYWXEuop4dF+AYhxo0r'
    'ddR/N+5ZMEg1eLelSDAnEBJFxNJLwx1bAj4uQsNLJN2T5MLUiJrMh1HUKYCwiJ0p8qPmDczjQMAwPKot7yF5ysgFNJk+XepMWf0m'
    'E/TMj1gmeo6PliZLaXVqeBJfbk4Mswoe+JQNTTN3ssFcVNABVHMwhjQOhOAkS57vUp9Ov/vZy+8UbvjnDjeM+QfhhpjHhNGRfa0d'
    'BD0vGPcUBJJ2nrwiyWyFu57POfkiKG4cXptJA7jOcAgW1HmqiXgrHyrEQyFDGgndpImtmkkJVW25Z10AmvihATRO5FGW+FMkOCPu'
    'hUpjWP0yop8gkAfyUXHU6lubPte8/khku3yseT2r6MZrAXlyBqNTzb1+XOs1zfeFzmFOhh3KtARi0BCbcQacGtAHq1UF391Agzdk'
    'tKX61Bm8qgFPv7WINTD7U0QTk5sWfKHzIh2S/iby/yZoZhNbIhxsTVFrhICHWFWnuN+WCjpUDbI6Paeq3jFrdkE9XyiRe3XWK22w'
    'OnnYburvExtzUZOx8cjneMHgh+UqBMGJF/gU+iD9kAtthxqyPvo6FgfPV/2ghLs1N64nU4UA5YFebrMQLq/DLuUAh14hwRiXa0FY'
    'ohZWOeDLQRVHA222KPGZ5CFykr1/ZG/HHyysdYGiLZ6/03Z2LdBCFXiCeunAzTqQ7CJ3sCVsT1BbqahJcb0pI8js31Uz36TOlsp3'
    'CSxU9OdTT+HiimGixmaixqlv5GtPFRhNyfghFZ1V6uh6zEyldC2dI3FSXUmXGEnimoTH/8rpKLEATZIq6p8ppCT5uaq7VrR5KOer'
    '4ZOdMULLSsVnAL0LUCbJv5a9dvxAqJyW6A9p9qxOyZh6zisMkvOTUZYl5YYZNVMZV08vVmVrLVPO8lBbblQ33lJLRYIqwcYQAeSt'
    'wGQsnNnzWzKWqhsCDa8i5VCWQ6ocaSwnaPYoXFIUHFdwFK41Ued1T3XA/V1CW5CSsrtoWH0fHxXry4toIwZHQoLoTf5eFk+BPSgw'
    'tQ1l5PP3ElYFMLSSEBkkQkohoSKGIu0vuXQTDGPYA1kAjfLHAtG//D3nW417c/7m9ze/f/y9Ezqw9SbW/3Fpj2yZYRrb9I6rHVGL'
    '1nUWr4I/Er/V30jxs1jVKu/kHCPHWTpE5ddk9R070PWttHLZp7UUyzVw6MNkITMJ3y00i5fNjQ438UVBRdzAtsN94cUmO3NI0S25'
    'yYtSpgPMT6lA2JwHCiwBkgT5Pql5spiYtdI3wkCDIqgFqFpRWcoDJhmLSjp7Ur7gcFCsOCClBMoS7DUe1zBWGuHtAYK+Qr8hcOal'
    'pbST2434COEAg7uLuT3sjRe1Q1P2gsdosX+U3tZ8E943hafZV7ag8Buqm71+QNNpNzPAYWMMcKQsSAORgGJ35ylFlRkz7M2Db5SF'
    'MmQ8RHzbnGyUgqbREeguSrYHRCtpvrQBjytAgYYTWbQ4JUUrNfGN8nJXspuvewANtOTwBMMxYIr6dlo3Tq2NoqPwVpUbELCQRdlW'
    'OsPBzALaJNfy2F/kpqr2N/e192u/KOgXv5fAiyp+jgCZ5P6T07obkN57fbitppb5solPDER3KiMt7lmRgWUB8YmBEfNjQ4zqOGOW'
    'fvFT6JR4VhhzzzRCtRpQcxyatTOdv1tc+fSwC13bcFaCbtkDusuXr/kOtVzXKxeRI/9YAyjVJqfTFNfXOfv1508n7Jc/DLqh/ors'
    '5n9pd+O+x99xNyqhg2qF72MRD8uN6vvsa7VgYNFnKu9yaBHLx1PMrNSul12XfAYXdbib7WSbGNsGrVhFSq1eVPSR84wST8gJMz+0'
    'XAaytO+ykMr3RftHu1t7U3tDe017VXua0TQji/RII131TBpN+0eFEJojNeWSz1ras+A2kSntEaeSIBgDAx3vpjUBub2mQDkK4B11'
    'YkHTuy6O1h7eMlJ7Q1dHVGzq6iiOTV0dObKlq6NVtnR1hMyWro7K2daSggTa5tbVsqOrI552dPWDpNlVWObqA6nf0Ad0cG02o7vX'
    'KlIT3WvTJnbCWqR9IPp1s89a1ag4Q1GuNF5Fsyoh7UGPrlA4ULol2GgPVm+h9DJjRkNr4sbd6+OlnDBp76Q9k/Ys2rNo73LXoD2b'
    'jrMtPUd79nok1cX8YeE6szOvR5B9w+XnLIMLISznvvdLFg/b4KOap/Y+onoVsrOqFFKFmSlHaEGPHghdhe30Jes3H6X5oT0Wp6M9'
    'k7V02FvM2mYaN5YeEb1Bz11QME21I5Y6lpZWXkvfRD+yCHKZ++eleo+Dk22jqZ3rDdoz2kcyIvfJ/k7aM7nepL2T9izas7j3Zynk'
    'ettLJe3ZtHdzvUN7trPNtPfUF//FrCxIXqrm4wovs9xVI0GggtYRP/VCs8rz3GvxkfVeMCcZgzzSTLXzsO615/X56s1Xb8g/6Zzv'
    'r7a5KiFceB3ROfcC9b0cmQu0sD3f+/37cKP7juu1dcXsAmprE7dBHochdHQ6OLwhiGPVuVCQq9RVYhRVuYSYKwRzi02gKIjWbgIH'
    'G7q63C5sost1TiBiq+EktTll2JwqAXoh1CxZDpeMT+C0nZJxIU2kNBGnMVh5GChmvPbS3s1wiPa+zpS58P97eGfOH/DOpIWplqLf'
    '+drju7q/pL2l6a25oejMlJdMn+yJUd1jDZVkEGB67A1eC8HORiIdMgWwBTlPXSMBB8nCwZtWYUnvJBsH6jkBJ5wdhRbTsKuYuxk3'
    'hCRiJg+nyV3Sbr5MFFX5mSwcSlvQnCV5JD9UU2CGdahcHwDs/OXqDKqYTpwhtI+5MZ4mCb4B103GB4HdnwzDbFXaZpRZgK3o7SJE'
    '6+K27eLjaKIPlDy3EjlZuw6Ct9G0Rlst0d24m2atOKhrxvdutXRbhafqrdSTpTdUzJgotQq4pIhEFzXJlLpOWnEPISfFC51cQdMj'
    'X8sBauzxdOWd2tGHxbmZHhWW+3lhpJirw3GZA512RyrEvEpDb4fsFsixBBtVwzLmIzhg8sdp9FJVqU1W2k4SupPO2ZilO9nT0j7h'
    'obgphaHGT0bpADU2lUOMTtxIBmNV/FcYmpJXbG/M4fqBaKoTemgv/34Jy30ugIcZW6wMu8wW4g4gXtVhoKjlpQbcISzq3/IZ51s+'
    'Y3zJZyjH9pHPgDqkfKlpWO5GObZH0Rw1DXJnFZ2cYnENNeOyuIYudNFIYYAyFNyf5GWYWsozKNV3UHE5Subt+a2mAYGuIElZlvGS'
    'bVlIbwjKVBDPURlo2pCd+eUi7AKjqflNX2IyiPUUPeeMlbyEaBD5KYJjJZPpS8TGLL8Q1iBEYgEchEhMdoMQicVzLEYEUQ5CJKbR'
    'ucaXLM9FM5QkPvMl6HPUBhH37PUSAdq6vsh+ltomefTVX5JCU+0SdRDK6ysT2cSrIswkHSOBpHsOqJj5ZoIsu5zHkRGerrV+CON/'
    'P5hRnrB1U7TGYeup0PTB4lBomrA1QWzljIAEELaOILbi4yksJtps1fgITmWqrVzR78NZQT9VA5ySFYsKpAADZgrxisGvUqaWRABT'
    'BDM7TEzhquTOqjAqYhmRMnTgOoq6NuzSkYCTprFLupxZjRpExaoF+BG2rJtbWbGPDmi4PxVeaRUuqr866iimVZ0y9gosMh2RXtur'
    'nqYr3GsZyCaw/QSqHdhW0jgDx83RdCQBKGQTst+tJHCddKdLyaMJKeRA+mQidhxGaSZS4J83xfRC/HgidrwgSF2EfZdRzA7nV+3H'
    'tpIIyn3+/iDYe8CwHhDKhzKsw+99E0FMaw9XRhxHDkcKV5Xen3VspolSKoNaRx4UVp0+siyLYznhVj9CORx5pHPcwv7AcNtHhJgj'
    'buHwXQy3cLiFY72w2ZXZT0emWziN37YyTQaMJyFejriFy3fhd5JarZUpmiO+i+2rH7fwuIXHd3H8fM4xup4WCqnVbR48Fp5ZjaaJ'
    'R2p/046W5SM8HyG17NU47soRWpi4QoWGffU2fIQWSqHL2W8dcQsf+YDuu+jnJShg1Lq+Gu31lXnxEmP9fYRz5DP8/81MU39XM9TI'
    '6mZTgtit95/v4e43fGjwdq0PtWCB2dRCHxUeHNgtLuzDKuyyFOaZowDjMUelFXmRnyvAHi7G+IWtdlEtxEIILsTKTv2ymtB5Efcc'
    'BJ1fwiqVzjIt61LMc5HTd7dycdIxmz5/XyYaMfBwGtIosK51ki6ojuwpxGxY0a68QOwXtBvlukOCqBvtD5NFodxtSUTUWueTdX+T'
    '0xF0VUwgMVxVV3KplPGoXrVCSSUcBzxw8JPV/jIXQV8MwdceJbrzg8jOINdPsGnQvZd6jQAFOL3Xo3ZRIKJTDmQr4V9VTpeDjCTA'
    'fPh/qMswNwU6dA9/BEi3Oa0Ujlbqtrg0fCbMExU6TlGRDCF07lVYiM9Llbxbmg3pYF3qMovIoPETQppuZdcmOOrgjKSIM99AABZg'
    'UthoNzQYcDfZuo4BuSFI6BbRHTpPpmN5oDtfEVRn5Vp7mFQ74PADZHgAejsIsGUurJIKbZD7F8jCsKeebGYlC3gBW4MQVihlBt4U'
    '6z1liaqXPtgeWT3ZAbbhyU+yyuDeJqODjHAu1bjPvKUFwehWinNCnbQVzDOt7BL6fJBfX4L2ZHpcae94IQMqvimDLFnCVKWXTOv1'
    'ya1vCv+rrNbNpFQ1GEkPyMoi+TXkNrqsuTwE8wftlSzQGTx3jXYSWhtc7vpB8lh4qZ80zlVOgHFVQH53vku20DQB0X3TazmKs1AK'
    'laAyyoAu0RPJAnQOrn0ucimko4CgPd1GOJAoJ1QGvxr3n5hzz2kdgGDDlEWsrqPbk1AI3PxOJ0hiN/R9LkTtOrWQF9xY6QGgBrKQ'
    'Ipr1BV0AJwNnWkIVwlKENCNBhws0l4kKNwDrAGFO1azk6z/UhG7m6nTzk+q9GbaPjXps0FzGKbreNVUJP0YhBO+CwpfrxZy7XFDQ'
    'qK8uC0ISog0XgPXqCqp4zAk5qE+tydZi9SnAskSSqgjM9rdRmNcKOWBNT6NQZPJDxapaMyuW34aTSfipyTIogj7z4B0j+7vZGXOl'
    'ja9yRVrwgYgR+LI8ybA8Gbl/yHMul9c8yt1QcSTTznWZbHJaLq2aonKZob0bW//wug/Su5OYg2SLIvOrys0Gr3sphqBu8cqJuJ7M'
    'p9iBUloa1H7ysAgBblXXggC3+IvaMBs8RkrmaYrpHxaLqfjhw8pY1DGKOeXhOEqqHPNNO6teyxPguwj46K/OX0TulxGXGKE2WK/P'
    'qt3PIxtb4YPIjnoahgTL0ZBLnhH7I19mzqe4aGmxm7JKOkl78iBwemKLd9Ocqk92QHhZLc7INZkZ9h3ClRnR2y4IOd2ieNXADURd'
    'RTiX8QEoycpDV7Gag8QD92Bss5ZeLgWyvHtDCIsqHaaKzeIzwXHfI+zgGx4qbLKRbcseGKB0FiigYyCk4DAZVnNen4C134v5rqxY'
    'wP7iZYeZ/19h5rfy+0gCIqoVD6XVFyVwGz/+vqFyJsVeQ/wHBBTghtoFfSkmqVKTszigkTN9A0dlqaddXxNo3Z7DXHDUzZfREUhC'
    'OGJZ1aFRznNs3E8Td1kOJafJw0wsZZEj5qzBULU6XJL2Cc8oaiQxI1VEChpKcDnqVOorJqcmBqSwJJeJoroVAsy8WqXUdR85iLyL'
    'HfFEIQkiwXUul5ZsXsDyYE4gTtS7CYkT/DIEQ3XRFAFallJAOFt8XkntJ6aLpA4LaijkbDRZMPkUyMaWCAbivs1FdBCIqYjGb5im'
    'isa4Vp+cMMFzUOLV0JxJ8Y5GZP94JhegGSFZqYqYvTiTsJ2/+gT92/Vyy8ejv2nneVk9+2FBnuetaRLXEvHoE5twvebYv62Xqzio'
    'GalpaAJfF31WrENHyFtjsDeFCjkBAD5kkhPSvoEBNCQTnNZjRU0ZR0e2S054NecLD7rSKM/ccBIDJhyqbv4wq27cIlPk7x/qxZ7Z'
    'pH37devl1x0l3eMs/Dl48/DnRnklEwcT1fgBEzSorAQ6N4CeETvJl17x+iKN/yS14fa2FgAIreFIDYii6ao7CO6mkXxL3ttEXaUQ'
    'KZpQ/FTSAUoMoZi3C9JpKhyNDjQfTj0eJ9w7FdzIIjVQUbBYxkiCxczROITKiiVrsTyKvQECygFsHUKt5OVpqGBTLdnGSwS7CT5R'
    'LCXXPpjODStFI064KZDtZAc2NAsds3KbOrMRJ5ivPMFluKtrmQoC2sKQH7GgHoHIjxybo3T81miAmuduxdHcCKT+CKyUnLFdxDQi'
    'AlsSJYwNubboCRMQdB8mV8+zcLo1VIVixIRXbL1gwCP1Z1qsMlDgc0UldKQuTjBcQIWOemaN+FoT7UIz+5rE/np9nLtNjUBVogES'
    'u5whBnRoQ8Y8sABzedzbw602hblPg81VWx7Ikv2zJSudruXUd0xZijxQtSAXmBjSBf+wddnVW4cLQoWFIZRU5WpX04QB9gME2BRP'
    'ebihRXrkZb1LeTIF2RS5n0iQXaKsmSIXSO8SxbhM5lyPwt1UWDB49QRSp1e4j4zvR6PcUhphq6t3gbdfkpTbzNpbKPANgmUrbnGI'
    'Ch7CFgdp0jPNiX5ZAN6AhYvqlodmN308pdcuikpKd7F1NwvTNqR9U3RVKY/LD5dNnu6g/uVY/rhcOG63zRa2XmZHRis/FLttwx9U'
    'Dm56lUF0NWP56SYNsjXF9Kzp2hUQ4vCYk7ERs/kT1LdR9rCZ1eIce3VQvxLLl/IkNcRlv7EZlZm5zOGgvq286Q/VCgXTH+r2Qv5o'
    'xXiFeMhh28Mti89SDEIT22zGVm09rPalajxRF6uPvMKFu9WsWhux/EVMk7jIITicqKptc8R2SbM1s5HRUGX2sKh5Zlr8ocNVw1fN'
    'ZdzbzNik48Rja/OoW9R8O6XQuxWJ3ebuuxCa12S+KaluyaNu1aDtXMcj3mahJwh/IfD8cPA8gmrXtqpSsw60WfiPtbrPsQM/zJmL'
    'i5c9IQ32c1ksaNrtn/TV6FHH+aKHkfa63toQC2XBNPKml+0cyxMxuWSkvf5P1t5sSXJYi677obwRmIc/kfRmW/Ko0ZLt33fj7LVB'
    'Znf1VSikl84is7oSSYLAGfZgvY5BgUPFgvM4DMwJ5JTYKfKEoG0aFkWAhqzY9+wEA9NSqfE22pNhQJzp99+WnbS5KqJioVGbi2Po'
    'jNZFZk+nNrRR7M3btSE0vdT1YEWS+1p2tShRdIjly6ocGBeiuXyUjQuL4NQGHzWIs0hONURDgiyCSywWz2N9WnUBsVuqR5xmXgjX'
    'NUmUnW7ImZZHW7bAOFpi2EXCNZikA7Wxa+89pCXbmaCdjKQj4xptfVtdinQmIfWqqXkSHPt2blTZK0rfWzt9SKKFBV/UUXD2tnZ0'
    'tvoyVppDmmnZos5F2rjxKCwljIE+jIlYUc7XNWqaVRWtZs2fKZW1eSVtS3P+ufRxjVcZY0m6N1pSkv4pcsahCIU9X8F+8HzdjuhU'
    'Jt/rr7yvYdXXSOTO5ezCqkXC23HE7MwTSz13psm5XcPOn6KOh77bQOL33O7zANmKe6KFfKcFYskxbaQTFCnswqNhSQtO0057dZnS'
    'vY9pcabreUTOa7U9+QRAVayUUiaBrVwxz4MxIXDJufw8PNN2v6Jln0zeatAWqClzW3nGYtILORRNivMwL8RfJPp/HvgIx482YLOm'
    '9YJ5phrBWTiWV5BG3aOogrGR8T4L0LJNYrMO93be19iqVVk4PzS26uKaa+mW6HbNVeLfZ9FUzXVYe/7XW9umkVcOfF9/aRbosnHx'
    'kUD4sa6+1hsdDlZNNN5KZ6uuot1UzaMwZksANMtgq64JcTz5URwvtwRrp4z2ro8UOVioMZ2AwUsx8MAeb8FvYLxZ1dqsUhoM6UJ1'
    'dpln5xbV3Mwqxwq8SkTuTCQAdFXKHlReSuR2SyA6/cFjbi35k+Iz59NjZcl/VGH5YxcSoD2aw2FoKvVjVFsKgjWVklcF0iiu5Hwc'
    'qhGHkA/uUEIlQr1kHiRPRH5AKhU1zfIkNYNoaVFYCTBLQzNKgWvHwDWq+QMcnvbKc2bS0dROVN0uT4Qrp3S/EA1FWVoVqKlFc9gr'
    'V8vtoC43NIlj2dIwVY/jdoYY++x+Vun869E6S9LGoqrYDF4zryYmyln2InQ6hXeJzWQmgQ1Doxw+bMzYhysF2c9qR6O+gWKPFWdj'
    '+3GeuWD4D62v14m4EydkBx7VngEnGtwmVcbjvrPLZ9kWJMmFsI0mUABVN6XtiHKT9ZlOQF4c/2QqSsovSn6r+eWbxXdRIaZoV0cC'
    'jC83AR8NXAAGFRTVOU3ckMhvmDMCTC08YJ7rf6lr623Vtf/Fha/kn+ralcq+Y/NGRcrHft/n7VehRGQqn/71tRY1nu3+QqLQvQmt'
    'lpwOp2Tw2CybvJSMKsxSIYmCaniDJ3Pcq2Rqh3RWojSAQnGLEsS2+AQuqNbrlsdpfg2l+TZ2e50OJ3zTPYsTpQniQAtZrS4s7bLl'
    'GaSzWG0VHfqwtJaAvSwnGbRgAvbUl+3mkLbOhkFkOz6Q/k7rDy+3Tij0L6RMBipZ8fe7CjNxJwi2p0L2gtJLTY8KafA9Ks3frIrN'
    'qRrgsBCTfxcrQDjFz7aeK+XK2yGDRne+q/oRVzXRrpntJX+008duLDYpLFAiBxqCccklDRNKT6R5HZOj2p0RYn6il84WA2tBzof5'
    'g+2RKt+Dlp1kqsOZmn1tWBKsa9XSxseH4L5TMJ0NMhkamwXJ2sl3sMi8DBFlPVaY/+eRriiOLaZVpbe6UCurkOG0ZCG3v1UjDHdL'
    '2nWKMxZaH2AXgowCPUiFl1NIxEtTS9RU1SighgmYjSoYrpYM7YIydENIbhjTmGGlDje2C1K7E0/QC5Gc1fQPV9+xKVa3vm7qtf1p'
    'zS837St0g5hiUV7Y6iDKnTBbmjULuWNP9UeLxt30nNExWFSJDMZJ7mak8qgjdHo0STYkkRtvoL1WHF5s5JEXk1HNgWuHttzo3sVG'
    'TMWGthh581SOYcfH/Lh2dDInqzdpG7CLul3i6dTCyI6MDCu6JvB1RnQl40YSGVwgmSkTkxHGM352PKwnYqHslEr6fEB3K73WCPSe'
    'znRxj2s2NLMSot/5AYxErWsBGDEvqdP9RQsj1hzMC6OSwXX3feD6b13+JRcJcMvBA8IvdUYrQc+w+BFaM+Q4HOXRz7gqLDkYWbkz'
    '21HPETYuaR1oyB9rFdgqAmsNOIQkMkfBdaYuOqXukxSdDUFXGrxUVQ9sqXVVBechfa9yhNlCebf8VLnFRBjSBEMXbsr+b0qLb2IX'
    'eZQgiooM59ItiSAs9hNMFHa5F3RkNEgkSCq6WLZvJd6a1qkPxOQ2BMeefd4UCvnh7NbGJCucy/gbSjTuwuBrCcG9vrzIl3UxK9Ds'
    '5eKQM8NdDL1BeWS7cisM51Yc0pvtzBu1altuRSk3GZPTXcqNFXIsV3Adxszieq29MkP63jGDLCpcuzIyKipwEUUsC5Sdua29cFvU'
    '0nikqODSpwMhu1yvrTbhQv1crl7dQmF21jUtWlXVqLxkyzs4YonaTTDEKsCbCFRKe5U8t7l91s3UelNdvAyHt7tbNiKfyOLOfhpd'
    'yoaHUuy4w+iaTBirUKrbHay7KnPwArYD5kwzSufPbHCjtNk9AmBCHO8Xh6s2fEpQx924ay7m+Gg0F5GsKcQsSTrBWwaHU7L3XbjW'
    'A0SKyxq8zohQdzyNwG9brA9NPbEhTOhi0w15lY342CZvND1UpEe16sHEY7hwKjIpaQcJ5T05QVKCdmW9w+ALE0TcN5uBdoqFqyFq'
    'RouN6W5DI5JMN1uaTJKYCYuL/qAOBjV4a6Cha2Ypve02iL/7eZIMVVvIfEz+iwJAmugdnc4myeLz6ltuYup+4a4oDHSovv/SVN/9'
    'I9U3nqyGv3Yd2NzMe3zf39/k60F0JQk14PoHmVrsE4LvWaw3sYklnEbc15PaHRBgSNiqJigyribCimc9vJGKhr3NMDnimBYirsMt'
    'MfsdtPVuXM1kNMeVZnHzJi0vD9XdDjsWNqPwWn9J73YL7TY7T1c0SDGTpiuaMUTSxVgK0yYGmhuTykEouCwh3zXaCcW2vi77BbhX'
    'lA46kHzJnkYKwCujV8KQhMVoYOyhiWsF8EJROxh7o/qTEobYhdALwvU9oxUzLONjfSGgjIWWj+UfCyv2AL1hI4uBWK9X/UmiUDBi'
    'ivJJQiJvqz0dlcGqvWWillFZyLSNKJM/e8qEpVFBZSygn41CWMzcxYI45J8TrE+UsRZko4by1kKstiMxK9UPpKjOwrmxWmqCBm3k'
    'qTsYvg1mvyMiudmGBzqzm56rBNnxw+h4A1kIvpF55GF4NrCT7N5zJSgJWaKG3qF58IkIIywbbpotfOEu1n9sDjGlY1aUvK0rmzqc'
    'FbsjjtzzTBjBWZoTDLmFKaSXAXNPfrP2E0Le3ukUFBSHDQht8GcQMiGoYPSRh2eZvgkrb6TVZGs4h00f1JC7bfqg5nf1Qc7quj7I'
    'rJuuD7KWBvIfg68w+EIMcmb76epQH7T8rj7IcdES4WPzFRb3A8rAFpAn9hGqaMXKdGj2L7B7CAxg7p6vF9O+EjwKOo951PbS2bUy'
    '7ew4lRRzV0Mst5LQbWuC5nrSJH9t5K8xRSu1xFzXM0cxOIAUEHly2671mEGoUDW/bN2Ft0MmIEoq3RY3OdmyfbomWb6C121yVHXw'
    'Wl3n8mY/sbdT8Ip9qYL91R3OehYuq9Hv/A5er5StFbu0qyQLDBS7zNq2L9EyFfzAcmPLGFXFaZ2Q98qzZPfri1VZTsy63JSvJkQt'
    'cwqbl+ud3dO/3rT13fe3W5WwAVa62LcsfDHQpnN5k3nObBMH1x9ntqmEPwDKbwUXPnYt9/ha9oKKp2xdEVPTNomKYEentorTE7Nb'
    'hIvoJCvfbAiNiZ0zbvhhaZEsFx5Z3CCjOXn7QkDT1UdGqUIQ0O25uexIMx1hoNCkWxd3ozgFsBFzvyoj/Y0cyRab2M6nbsXK8vpn'
    '9myeGSnSSM0v7ANhuCkqtQ1Mho457gW+cQ7hLMfzVUH/V1c0Jv0USboDIlXmQgGxPcf5laeECwG9Ol47r5PXXWx95R8SuM0NDlPo'
    '7UbJbd4dtBF1VcxxsWhTYUEkLO0jarJHkSRke0XUlyK5NjkKwNSknEZPW1mj7gHupzJ/qszUqwCG8BuqHOarvujZ36UwNNUPiKjj'
    'BITNSqXdnZUBabqgs62VeVPrUzRoQ9DGbUWhJltcMeNFnxVe9UyIaE+C/Nwe/lQl6XUqsnzbBDQ36aI246sMIDtPSUJo+c5KgGlm'
    'r5+1euP7o9Jvl29idcPyI9SCFHylS4DnbQz8gw9ctK9iRzJNAKp1xUC3aPOoxiBZsyfZzwKDUIWp1gnBnVMFLpIjpVvoMjUVtJeu'
    'z9iYVApfumkLoUaZUbCO4NBc9mxacfJikUwgKeuVTxSvNc/ttROaZC+Lix13CnjjqF57sw0jXFNYSI9OlmnTYm9jgdp9cYMBPwoo'
    'BuhSWQbTZuzewobN2WnKI2ulfCDzR9FBzZ6AQyvSOUbnqrpRgBxW5fMaNZOWX73BbrerzJdQfF7Q6IhjPm/4fT5vMN7B503LcPF5'
    'k/FOPm8x3snnLca70tvrdoDsV/z0qJtmTExUoJeMqPW/rq4oIxaMOTYnX+Pkvu29yjn5NmSfuVaB93fMSfO1Fmo5YxWoM66aNf/O'
    'nVrNSmW+BaqIddvFZLcATcp8fqdCs4y3Oha5whBGjWfZdqawCzbXXKr58lGgCYtP4xXrdvS1jKgcL4Bo7K/BB1rWNCnrZeaT7UOg'
    'Bw2zU4mYDiLGNF9CDiFQIf09I1eHJWLT7QVxA2/dGFJGdmH5fOvbf9fjj4TkcmB7CgCuoab+6gVN9GfD4XsDkUiQPWVpBHmkIB2N'
    'qmBUninRbHB/Ec52ElP8GTK6o8G1LoxtYHC9FcRHMLXE5a7KDXfDV2w7c4n98ZQNVWhvSHxO1FlR6p5C+Dd6VBMbOBpTYYZLBxBS'
    '/gGs9GhODbUCzmTYalkMrSFbpYojrLMCwnIG2rW/L4WIaJhNuaI1bSyz2mMhSAFK9JsaH9jNVDVFhsSPAtAuGVZB5+bVNSshdGen'
    'iePOETuF/DvUhBJRzd2V9VJ7L8llbR4nKdpRSm7y02Q/A8nNI9SEyzVFWirx5ZG/OJVqPSRNoOWiT2paEvDiaupsQa9rWlLIg5o4'
    '73RCm5akonnc5LNCWaFpRaObKPE6FTrPz6Ggr79+IGEmdx6cmMLziOqU6bZgKahI0UIYREbuLRg4EhBu+bFRaNHOQr4pEBrF4k1B'
    'S2r6rIPL+uBUezB1EmyKnKJ8uEYn1fhwhU43LaZUONt+5MRwvmV8Za6NLre+10dMpfPnP+EB2k4DNCyY+Cnh47j8U1GE/T8Zo/Lr'
    '4v4UYU9HD4v4Cob0eJ3x76h5GtZpaB3CtPMZc++cqy6OB8dneiU0l9Tk1zHcvlDNUP9PXL+hBHfQJ10kofsllRT9VXDUZwWdkk2O'
    'Rd8ZFApNVeKlOFXXCJAV8cMey9KiP9NeIX2XDtS+ncIlj008mZL8KzIGFgHCJLIe8HM77lQL/qGt4ZV4DIzTRCko5qpbXahhpa42'
    '1nQaGEBiFz9i5Y00cFkAwCJQ28SRwaqXr6uANAHMTc0uUZwuhs5ALY+3xF8tPgNsOVvGMiACVvEQ06LQGA9S/7j0V3OWhxnT+4KF'
    'FvUfRfdIdUUBaCf3FivfXZrJ5qbEY9O/HBJp6sUVsz1Xtg6K+jVtelpPp9uuwSxL9VxY/UIsR1pUxcii5sHjBaD8vZv+sm340D2w'
    '24jsKFFki3dFz1TwFIs7dLdxw9jGD57yIrsqho5kdYRgG9vs4lBOPuMWZxRlB764OtNegCKdAbi1+TOb+lgUexIxQN/sMxTzmNpn'
    'aEYET4rv0mmYCNuQrxwzAaQ1JXzboFDiRnro3FOBTfydnvFl2FAZE6LuOO60dSUVJSim1PgsG2JGNJQC1Ew4EWClcDcobRcQOwNy'
    'RGFSuaju57MPz1U0gpuJEvoe8hDFIahj8lDkIHRmYocSma3BiAkm5poyW60fPkWH0WcJSC2qNxX/0qGibMEH2IqmGL+BuXksa3e/'
    'kouP8a3ekjblFsVyhRXgUmIalmBhRb5EW5drkGrQKoN1CS9KNL5TpBapTrmsgPvn0gyldV31o9BUCZBdF/UiD++6IZmDYRVBmERf'
    'zvLRkQVQ8NaFBilSL+jZ2fWQPqraNqrEgPqSw0+zcHxMKhjGmrlNG71K701W01rGq8wbs7V4zu4kWvU8cbICEBVqZCdZgzUpIMUJ'
    'co/s4pbmWPgCaTsKWZ15edrndV7SY+BB9EBXKVVgsImaoatEamCCKqkqC8MvrUrfMQEFAmJ1XFnnwQgNeNOKOkdFBblTt5raVPuU'
    'Jzs+QKGspBWtWeIW/nq7JHz9zSi8SgQzlu+OdELBuvisnm7B9A5EquAgPiHlQJ45t2RQqQ5tQZTYsD6IbSZIPnzuwF5oQfscsr8S'
    'tAx1lVML2/KWFpSKPWniohpiMHIzjE10Id4W6o1ArCAgx/fe7Hsb6NZm19uEPIvXwWvjtfBqiQkwGzoCozCt2wNZyxD3wfEwF5H/'
    'nNxy5hhD+wBdKeuI4wpAJAQQEkQdhIXPcWMwjdE0htMYT2c8nfF0xtMZz2A8g/EMICphtyvNVh0znsl4J+OdjGcynsV4F+NdjOfe'
    'AsazGe9mPJvxBE8noyvNme4z3We2zzhMyM2XvfmMWXNXUalU8+iqz0yf8d2rXM6HfVd9A6tH2HyLm+9x8wibR9g8wu5v0T3C7hF2'
    'j7B7hMMjHB7h8AiHRzg9wukRTo9weoTL13B5hMsjXB7h8gifdpdHuJ1KhJBS9Q8WQ9Tv/AlTEmFtJ7MwFwHk+Uifef2O35rmd87u'
    'uHrToGtmA1fGh6eg2AYnXJnoPfX1EnaeaGsP+eFEgLe4O0TGtNZx/tKGu7WwdBUVVKuuSmCg3IWapPaqT3jdnjhNCbR7N1AmyqOS'
    'FjJw0nCoirNaNS2gK08Kwl+JasNSunrwz0XBRRsvN/QKiLMhEXTgCmiubsvRa750F7vKS7frMsGHaePDausTANWQ86RUzrtuRgco'
    'Y822xi2J/Y5ve7+95Oi0Pka0ZTb3fKD783U8broZk2OAjOO1QYQcvN45lPxDQaUrnrlEbnbnmabt2u8zJq4lwFm/nXn9L2Xt//PN'
    '2tNfzBTCbeyxSJhfR7w3w6EhLNEUTGKiI6xvF9Ej9ugu38W4FroyNS5M1XVR9zzCHqHx1dACLKq6c5WcRUV2GgPGaSehqiZG5UI2'
    'guYOSGnQ1fEypSkG52VMTzGA068p1pwGWjy1OnUtluVNhkkDqZuY+w7o4J2ksNHgqEhwVDhI1hOsyV/UXzuugXTMpaqo0vKVKYDW'
    'P9SkrWTXJ4vcmwlWqZLIVVBrX/byZUqwUlpnjlENGO4Fn22w22S23jTTJu4Jmrvp7hOS+2BFdoFCMTI3aLtfA0zQpKWO/trj39Af'
    'W5BcPfcMyC3AoWTc1/Uae6J53+zmAn6KrEvdtagU3BKKUYJuCyRTNV1DHB1HagXgoSaKRXN17R2Fy+n58TgXr/bAQU8UkjKBnwK9'
    'cnlnLpeI/lZN5C9wkB6FwcbUEi7ZzfvixD7h/rRfbkxnlg9sAwdqPZH3G/8FGPZcQDt/Fxbqimyj8d8ie8zvCz65EbtDsHluYgWA'
    '0ejPYrkLiq7imgbSpaKuyHysaIagIl7x8Yr9pIo/ABZfCYbKfVL2KiJzRKs8wLZR9RarQA9QRLmiRclCQAdyGxj6fXwZGDZNwXhp'
    'ugRDdIITSmRHbFohfKEq2sxxIRM1AwwXw4YsEwQulq0C6JIk3fJFeb2t2FX2v7ZjsQ7goDEsmECyPy23iUju8t5ITWO/awtWN2R8'
    'rj1UNULPDhs1k5aoVTQ95e2RjRrWgQNgOKiFVYv/YYCiWsmmr5OppRT6PravGMhM2WAPgmCXpXzUbmhjdXD4LoMOGnALmSqhWhbW'
    'oxuAJvLRv77EpA2mhRdTpEQ3bCj9PlM2YGN2w0pmbg0VsXTCVdZkr83UfcaYg+QtJls1JLtBl/13snXnjTlFtOaCAdDszTbDjhpd'
    'schbverw3/VAb3BPzbDTZnzqivX32uOmV/+qT64/apgWU70ZeYS7LslOy9+rXlpdL+2uqcLrjRxAm/Zd/NBZiZ3XK5qYIC7kP/C6'
    '6spwt4ZKZLrDIuXY9eXLddVCm1l6m6XzsjVUKlyx4DUnf+gAMi7icrHun+VV5ddUvajz8OLphOCqlHJRVEwmnA9ZC3OiaqAbzc/N'
    'RRrOlNmaK17ABcE9+xbKLLKo7FQFiD8Pn9wkCkDNGUOoUBvm3Ra3liVgx1uLwjFdhPG1bz80hGui9tHclIlBhj2jNOmGGqnejVVo'
    'nFpNu9alKZO9ptLf2G5ade2aVJW6VEejqqQO6YBlKpG9bh7AhzC/Cp0/yt0sflvLtYhjTb83UYTtgDmejjoeFmnJj4dQbxgPPQ5D'
    '5dthqHw7DJVvhyGkBe0whCRqwpUXy1c7DBW9olPUwFraYQiBQZQnGgh2OwxRhE/6Kg10mh2GAITi9tpQhrfDUNErPYxGNm6HIahV'
    'JPSNfN4OQ+BbKQk0KgJ2GEKRiKJCo6ZghyGKDo5R2GJc3aZsQWGjsVDYYYjCB6WRRmXEDkOUTtJbO3BdhyGKL3YYKnq1wxDlG5e7'
    '6YVR71b5B4ch1YZwGFLhCIchVZVwGFLJCYch1aNwGFKxSqWspkoWVEOVuVQEa6qBqULWVCBLl2DZ4kObhtPUz9WHVrV0NZyqmbON'
    'E5AAj+Y24RCxEU8Sz1VT3BTKnqgsVpXHFy2GSL2aGqFiDTWB6obr4eGOo3q4uiryMqwbVz2x38+WoQrEPC13YUJqkLLFtK6RODXh'
    'GUPfv8Pc6VEKR9euilUNt7pKLbDjTiH1fIDZAPLppQaw4piSxV59wv7ovMvdQ+J8dM0CTa4UrmBdFMgMJOsz6u7af6PsjSZ+o76c'
    'VGqoaMYPK+hDAR7kgE2rmOre1Ml7tnib6uRXhG2gOd9JTxKa85M6N/luRzn6fIcuHIlESyw7gERHbEHUVTYEhI5scNJKH5tuFDAq'
    'jibaK2LvHGzBZysIrSg24EktZLL9LtSiVr0yB7FHLrbeU5RNUI9HI8ODeoCE/d1Tb94VI4zt9wqFqV6rIsn/4iJJyn8rkqjS9uuP'
    'S4JRP/OGdZ/jS5d0AZhYyGEpsRSL2jOyMrG8o+tubSsVIkUxdTPD6wXqYYjp0p0f7WlW9EIBolKAKKh8goNIsnTYUvMArDD0DHbF'
    'C/EnlHtMPen4L8bCl19+bMUZxFZmYG8cU5KgRYuda75uBgumMHRkosZeLfyIz48K2N1t++pMxXnxdFQ9KDUoRlzN0bB9mbY/fcvQ'
    'PcoWWwnDwOc4EqNbtqjgLhJN2UTVdX7AinHLi9b9UH8TMIf+bAXitpVBuIBi93Z49A18yfkSu78KSOBTquXi/d1ID6p0UUAz/fqs'
    's3m7YhGiQR8aK3IrFrCsCxxc7bctYn/EevNDXtkswIc9dQd0UdHXGuAPLPK9sKHe9Opp/0+zTq6hVnFRabjQVnwHLaJYLaJY4WJE'
    'nN0dcG/a5mQCiSi/XiRHdW2rOX/oYE2arejPg7Ds/dXMAHKS+MpMrB10s5dFYAPaoyE2GCLuxTmPOxgtvZ3HJuKZyp1sAvbkV4Rb'
    'rxzMJp9Pnpb/wH/MP/Af5Qv/cTH4xn+MC91zod+AfaE9nLUW4zayM9t8sR22RMs3HR5m49uhVLKT1fiP7pS5gv9o5NT15tQbI6GF'
    'brrJh8v4EFLuCT5E8kUZ/Adw1AEuY2N43CkBbzSSuySIzjIywY90kzU7FutTRc9bgyhaTSaoqYph0oDXUqFl3RoHeYNrIAWLEHU7'
    'VHM8j0Y8O40a0gCXAqngjFt5rcDpUfvwM1Ff+I8qPtKFhJVo/lz4R1F/qBrdmj+wKRsOLYZ/DGW6VtcepLn8UidLpTiF4GZ+ldyT'
    'Yu2kVHAL87FeLptb/28HtnCRI8afBGsbuMoIiLWByuqwKRZoyislIzYiDMErW3iOrqpcYF1l+TSEg20itxoO0i4cZGqnQy1lX+5L'
    'VxW0CqfZtQP8uqpDVpDimKv3tREGimpWQ6aOJVeY/6NnL1xtwGKEBtHQJY3elMo2o0FiEfiwx59BfyjwnwK2XJkiEm4Cg0QkrH5B'
    'DRmEeSPhY3ACs+fM/a9IGOkRImF7VygSpppMJAxRJWLf8kF3O47mB6epiITLBwJqFRwe7Hm1t+YrMFY7I5hMiRgTdfGsyg1sklZc'
    'kgEAXKk49SdSnsieO1IG+xnLrEODYkDJVvBU0STpyLQGzRDXprWecD3YggBRAmECGtGbSETK6rBK16uIgWhIoSNjF60cGQ9Ei2Z6'
    'jlGJEWLjOeZ9RaX/+rbu/haVEo62j/qe+lnn6YS2GB40YtqeQYswJVx2ZBK++iivFbfUZUjuObi+ijWYuERVrjikd515TpxB/YhA'
    'g5ZD2h97ZGs1m6ySi54wqL5RadiNd8NueHOGNEBPeLonbMdri16H9Da+WAP/LBBg6gnjAgXUPMIuf9v77XUxYkKyH2dzdZl/vAIA'
    'ymhBoTFVeG3j5kHxunhVM9iyjgm6g36IGdHdA+5ID1jWUT+Ewob1H6ZpmtPeR9PMEKMNKNDeaKM7gCgv0YlM2WjtR/ojesFu5LAD'
    'VvxQb9C8iH9QiWXPGaqPamYWabXIIlaWnCdga/beWfhS0JKUTna1PonbtbO7NXohKSTCsYNuakj6YXKNJM6dUNd5rhoVPDXva7Oq'
    '+rKFlpWqbwN/+kz3meYz5aof43223f3n2GiAznHl2F5p806jeK1oGRrCPlEb3eDRNs6uJ/tZ43EfHuRQZdKTJvB9t6TnB6ZQlcm7'
    '+GOVCAkPBBk1QQ09eV1stVENDgOVsHcHDm6PTmL4Qmg5UJ/oNDQXYem6veVs/Ec3L92odvUu8gsIcuPvvpw8+G4Lw+7uQXLpJFld'
    'NBVj2LvPTDdlbZ6ave1kI9/zMmLdyPfTWBBi/boybfoA2cj32o1YL85GvMEVp7VtvRrA6mZ0fy+PuTsXiq4IrqckzGjfZxsKKmOx'
    'Z50ayd39lmwlrvnuyVQj1m/fJr+hX2E7sZ2xeMWodly45jy1efC3j3QB+MUZy3bGYup5sWGDelbLfS0nTnu/c5iLT//OYV4KiH/N'
    'YQy/sqOicpjpfp1/JzllTXblSfnhq0XOwmfv/M5h8m85TLo5zMJe+iuH6evJYdBsHFj9La6ac5iJsEsHTaG+qGxoLDgTfVVW5snd'
    'a9hTDFbkCi5toOkTihoTAPJpwrtvmy3rDXAAfp37vp0V1s+nMOxV5ZKB2WrYWlEvsEBHA3tPz0U5DEtCkcifvV3zUg7jgnL/8CHm'
    'MQP5aTBN3jlMGjeHASD3ymFogCQlI6rbRwajcl66vlTqhWzylOkMRgEWGcxSrVLZivT9qupm21WWoZV0Rr1wKOT69VQptoyQcQnC'
    'DkRcGL+mjDVs45U9AFeWRkwEMFs5iwAfXRSDY1gnEFKRp85Q1YcuWVjMZ2A5KvxZZ0iwwInzrkr2HdFt1exFpZReURNkUcu4OG7/'
    'kE9Tw4b55i1Bi1Lecuq8ArFHtFlViByfgIVsJSBRUtWG1M85mK1V1QU44lWl+w6IXcz+DohdgHWHcfIob4DYJTxQAbGLd+O6mrrc'
    '6VraqlpHwR7FQsstUNGCctzqTWJaonxPkEg3RnuHy/PpVc5fRAF0dCPJ6HZnoaI7gbFPyu8JGDu5U7iVGn20lAUvmI5DXaVsR6cB'
    '/BzvCcHYURo9nzNkMiztcsrri0BpsAcuwpHJLrmAQFpRZJHULBhlm81vURTblOY2KOHNxrfX6xgl141c0yaZ28g1bck1hTYXas46'
    'wpDE277L/Plech3bsd6+Ezbh69eHQsebY7zqK9LR9uGruHBWvlpjMI3RNIbjDk5nPN16gYynM57BeAbjGYznFvsZz2A80alOIF43'
    'LffErdjA2RO3At+JrOakbgXjNQlyM57t+Dk5fi6OsXp1RG3/nJQdUTu0br5svfm6MtDQcBn7/TvN17r54jffjebbU32/qn+nZp/J'
    'NkL175ThM8VnPEfyfMwWOXMdFa0Knpbnhi1WU3usmYrzony91rPTCp2x1P32Y+72VBR648zyNFyel8sTdXrmTlvrTENPZ/HkdXV5'
    'LJ+xEfPwCLtH2D1C34vse5HvQtQ9Qt+L7Hshq59t2oBtu8Y2tcCOXo/5D+13nSn+FsUjLB5h9gjtQRzkByuwcMYjzB7hQ0r1CJNH'
    '6J5eQGoGzb5X0+/Ydkh7XsWVf3Nbfu1vxZX20fqmgqR+1nnalRmU+RfoXlLE0t+LHZiY7kSQOXYuwlSgVp3IPbNvbLJPPIfs/RO3'
    'dFC6oOjUkIWrauJluMZqZaeHnDwF4teuF+0nbeddVeEBVFKF7ge6MPRimb3Ea+G1eSl5vQrjmkiVqsFPmR82r5PXDvixGgQJ+aWh'
    '2RbB5dGChFqqXOd2FqapqngZxpNQp5MM1yJ6d23Ia9kwuPIO9Wvwa15/qGyvvX2Zz8O05OTqvcm604WqaxsXMWjAqS8JBM3MbWsG'
    'hCRHfaOoCdNmhgQCbvPk8En547gAfMOkk5wnAr2LwGgn5dEK0tGmKtZCsprztFPZMC3Hbm/x5C5fm253g2o4c8adaDMAM8bbeOoC'
    'i0bGeRxECNXtV4d4uXMULo4LvUELAQbKrNPDy4RG64ZYxlGn4ZtrmGDLbheanj3Wq/+opu989SjzfsPcxxCu7jSVmFgufY31QlYP'
    'hPtbpnEKkLcIG5Dr7Z4rdGrSVcwK0ykq13z7DbQrttvzwZ51hQaNi0II0qicI44RQeSLC7kJHs/EjSbsC8vh+mckFWBIeqYxkhUs'
    'tv0YlSHhIdl5kDERzOLqV8sLi7KoOVFfVSWS4HheIqEq9ibxDCr6rigATHVsndMLOqMSmYE1kkbT0gciBo2QKiJ8uhqbYTvzgHmO'
    'x+wL6FO/coj5lV9EI+TmHvOSa2XmOp+UZZqQG8/aiKpBDVVWzfaT7wRiSWJrR17sEn4zKiM1GovpMoQDNDLVpwitFWuO6EqgXx0G'
    'tsrjDNFQlwoAh4yCm5RqsvL+088KiKGySAmJFLpizTlln0+PTBa3XS3LKqUaU62V3g5p6tGdHNMUbZCeQmoCAp2Cto2bLotETfdv'
    'WycDUe92O4ZgUdVLlPMvsDuh2eg/qgGhnN8QSHct26O7QVfCqN4XyMX90H3R9+3dLQ3iU9QhwN5PqhRA71HYuE6oqCr1bP8M7U/q'
    'g1QtIFQConiIiYeleS3tdJH54Gw6dT/Rmeh+NwyaZ32Q+Sjh3671RtXAyHxMdS4yf34j869qgrvT443Mp4/zRuaPb2T+VW2gV3BV'
    'Hfa7YpYeZL5VIViir2rEfOTJBU5wYe8Rnqhfhb36guZn8P4vaP4tIpYvIER+lxXnF3wivWXTb3nSwocXmt+u7Or4KnzWF5yjXwej'
    '8nazfUqq9cUDqqgtAyZxaTbSqvUu37ZpUEo3cOUWzm8ZGFv6V6k4E8ycfeIByXTLpqQ3NN+8yqii7PzWqa/Z5e3OLlxonUbFutsv'
    '5krzxuDjjLlqw9DsZMXfzkMmsP7J5ZYTif/OACWDrTbU+dc9riruVZNxfvut8YSpKyPDseQTLjGKOBw6JMuJwBI5nyy36XPIJwwJ'
    'L08+f8qDZY7HnsOSor8OQ+gaCFYWYW2h4pgl4b14bDLe0RL2k2ezRin6SgYKsBD2ixNZIxXBIE7gCJO7T1gmOtn3qnKivYywVn4M'
    'RmS4ly3tTNyykNKTq7TGrQlsm+k4YXctLrAi+zjBb3RkSgQYtUhzXo+4U8dnSAFkMaoO5skqD9EjZu5ydyl6gJxQUwiD3cs8D26I'
    'OJeQTjL0kagcvP9IZLR/zuO93mJIQdlcpqGoIaWU9X8lZd0/MnmtvsNr+e3Yp/vrtTljkHZx5NC6PEX16qL6c1E9Mo60p8YmVFHj'
    'V1RCmbrEy9JLBL5Dn6BcTo5fsfy7BzhevcCJgv1iuzgJEceWAY1toQgwfsxNFtYWan0X/R4goOBjNLwxO9ZgUBND6TMBzlrBXDwv'
    'ZEpcLo7iKlkDEC7LWbSt9ajmTEGYVVq/4cC4NUa5Bih3CIlTbMj0HZbUPiuA+wzG/thhkp0VlnKG0+2TqH2m5pfedNdfi43ZSmH8'
    'vq/wSN/fptJ8jU/pUBfPBn8tWrUTmFJVMGQOn6Ieh0tHQ0cdkRs0WpE+jKsRlN3oU4g72tVjJoOVjwt8HJTPuNg6gpOj9+D/FpEA'
    'y7Lj0yjUahVL02JX+jAKddpIRrAGg5o0CjXaiHdHoUIrYeZCfTa+pF2BBd5BZBduEdowMJJHuVSopZEtffpTXynYPBXBIlTDGuCL'
    'qXGNYhw7Fk82A0ZRZBRz0lDRLLbbZHspXoa0m1pJrVCvGxe5gBQybJrClj/Kix2KL18sH9QNLxsU/ZBhRhW1x2EHURCZg6nZ6wvp'
    'ONFQ8tQ8naEkKGkIr7KnFlt8nWRq6AGTlftAR1pb4inzSv5Wj8A5liCQkKJx7PepD+sBnWKJZmR3f41PEunI8vaKFU7HzRDd6iz2'
    'anh7Mt7GIhR/F9Hv8DXM+ryKQ9OwdDyOvn2/PRcXgpxSoT6LnzznxM6NcePVaBnj+PsJu6WE11HCiyeBTN0i850wzLRxHUsYK+oj'
    'FkNZz8ozoY1B2+pvnYiuNWq3D/zz2H52o/1LUnOOCSFtUVCooRXQzQWaciWpMCC62p2ZJKQxFK9ZjcE0RtMYTtuvibbbM/HWC9jU'
    'O6sMD1Dv0IkbToodyxtDgztJTLtJ0XISxHgW41m+Oox3MZ6F+7VRHGs9kni/3tfG/7/9cyBgqTYEf9bj58hvwqd/lGKbbnOxlKTT'
    'JmqpBGCFvmFoNmVKPNB5DEt6w5SyZLUkWFHkfIEscpPSSg8geI9r1mK3qmH0XGLXyFFZq2HtVYI40yOkraG5P6VOGLoa0bU+8WSV'
    '7GP851BBPTFdVb9SPozU1HOyAxrIq63jzvHk/WXLjGQ1lezqbvWZduu9PjN9Zrs4vNxIG7447WLUCslXXK9lTvCFL20LkZDsv0gH'
    '6YvUXV5QqWx5aoFWBjd2azYOc10somxQh/FaCn5qu+o9FeKPyrTSGenobEnUPvAG6Cpr0tf1wpJKKPWhyQHn2o9KypTdhVrVYJdG'
    'fiHaQLhtzD+najk6bq+WclZIflvOKg1FS9r3Y9JCWUxdKwXF52z6qqQ6az++vROl0L5eLXO30N1Sn/R5aVm7BX9b8qj+G9jhqqmN'
    'fWNjgv4e1f7xmIm6tRCOgMLZ0hN8QQo6ynhFTL2Lo96qsnZxy1xkpYh6krGGTHMHhA0rC+OeRqX2jZNot6Yq88N3TbW9a6rBNlA3'
    'SjLjmI5VSYrDIqmSD2+QNaOAit5CDUGgZlj7iYgFdw8ISTEMfi7DTAJyopyiSnOiXGBKxJkrXfzKsP3n2QsCY39BL3IoOZB+XVYo'
    '+AqY488ew2OsGWTLKhcEQ26KEBsRQ/KwCOpv7cluGE9cue3cKUuIxnqW9aEzyBO5a7S/7r7mIwKZL35EezMnhjkVj9zmrVqAYlJH'
    'htrpI97Z3rKeqn+y4Sdtrlvc6kRt9MQWVE77C3a1v0BZpVE6QYTUxhRqllTEP7JgwxVTs6xlCRJFgCkBjFvNXfQYAO1lAT2bFFKR'
    'Vx0UZq78an+gbECtOxWvK2mCd44KqYN8pD3QOUPpYBAOXE1bfcnJHigeqr7zPc4rRwuE7sQQjkEIzlZ+QwMXhVRMrlN6JE4MLfwq'
    'pNbfCqmGKrqQ2oEyGtrYH6wj6Mf+Ml9N93fswprv71xumJlgvxVS25tj5oJsdvm1lrfGybC5QmLPUA2jfGmcbBdSr8bJeqFM6yUH'
    'kJWr5tQtF732G7/azcFbVshGxopmYbYZbDJbNVlFe7iQul6KJiqkjpeiiXC5zUhdl01bNpq3vFrU+/rfLuMq7+AvEsfMxgdLfNHF'
    'X3jjOt4q2iaPPUrbF8l81biLoRm2ZtvZ0Aw7Zu78DlYeHLU3pVRfZ3byCHFBIh6y7njAZJaBM9lQmmXgTH7/TgBnsqE0y8CZ/Pb1'
    'nVjaCkqzDJzx3RnLwJlsKA1MVM5YBz2AM74XbvlyxmW97hF2j7B5hM0jbNc43COsHmH1CKtHWD3C4hEWjzBqHS6FD9ZFnckeYfYI'
    '8y08eoTZI0weYfJ1Th6h9d03A9zjhlM6Llf8Lo4X418MzYi/ycDmuoKMOmZUk0FNxjQY0mBEgwENxtMZT2c8nfF0xtMYT2M8jfFY'
    '074ynsp4KuOpjKcynsJ1LIynMJ7CeIqvoW+g77FvH5F8ix54Fp4Sq90ztpJeqU/0QHvAsAPEH78fS38UmE8yFJ7XYeoQZPUcIN+D'
    '8Y20vERFU2WnGj5EM3Kf8wejPlHCJeuAZ2KHU+PxlKJCkadHKFRiE+2xtZQotY5Q36ihXT6iUFnD3HNEbaWGG8pQQlbOt5ghKFDD'
    'uHSGOFYNY8cp+fcaBPEpZP05CEfUyC2ErZ9qs1eh8afCRDBMuHZXyZJO4UOq8LtTSh1xFO2SCD211k/FrlXeIlPk6ar1e6rTVsT5'
    'PgtADQ2z8OcTordo6whKRRTIA0GDbUn7IOQe1S7BZaLMEbWzEM+UrFXc0gjDxJz44NoqAnokOpimhCt4AMfkdx7LcJUUwoy2WdFa'
    'r8ZA0bQd0RorsulWxyFbOSQQb5YulXFGBz0GbA5aHA+aV4I7j4OPtNV+sNAV764/pHOHtpMHkIRWRrj36D1OdpnJYXqt8qpsSaq0'
    'VUVioJoZ8dKQGAztKlTTIOdhhFhfHKYVhYigJqoB3bqddn6mJqYfqImDljyut+0xKVr1TU2cf1AT+4/URGucDfs/f1ETx4uaCOk0'
    'oDi4djSrTvbn295vj7R6iexN4bCDnCe1jrDTWsofRWExvCL3rDO7VHKJ52tHsFfDyFDGtDVC26JpH03QEvQ9PY01IE9KWnoUxsTo'
    'H2IgT/FJp5qyQ3SgoWmLZHuTknrQHw9qMSZzQqsFEZfKa/i+SHRDsE5e1YYbrlojsaAfZuaHnV+FGfEh8+NJQ+N9mIxUzYdELv+q'
    'CG7MizcpxMLERZdKfEgrMViyBEIYzwNeWABDONJ7qvj979fN8mdf9Hgua0Dda+Tu+pnzOqOtDGJ0lXdOlcxbJTioZDz2tB3tySii'
    'Gjmh4Cb72GZjG7I5YcVm5tU8topTVvxg8GMsruLJy5sRNaROyExgyhJWeCoarITB63rp7+mHCxZobtl2s+MG9ZCI1Kvve0YMQtXO'
    '/QD9JsfxvB5ZbkLNuFiT182FzWicVoFXT+Ox4BJHP3KopTfwFafwhpimxguSVOhkyQmPKBhowg+txUV9LxHii4QO4kYjzpnJaA9E'
    'iMSrWrN5KqkxNEeyKxXw6UZ223CUc3FzNwoF2WStbNUMyIoqpWJMUarixLLsNsdRpOq3RvQPu/6M5343VKiiprUANDqFSp4YsVWn'
    '92QLi9mqnGwBl+2wcitWKgUyeQFcVZBbLShKlTeHSm/GZhAQr5LthqpmZksWoV3qzW7EakEsF6Rs3YZQM3lyuGVtn9SsKKEvJi1A'
    'zE0lUSjRtT6uhSTvNlpMSbMrDiXxdnxrG/61SY3kOJTMW9HCHK9JXbM4ROqtNA6lY1gSh1IqzF2HWaOysaUkdE880Oh0JyXvOhS2'
    'zp5WkgQ5j5rXU3vbA3VOUlnRoYpLy8TFpD15PXfUen/xIE80SQ7gHtV8GzZVrLJ7eZv39Pv33EvXDOH5KsyUVOzBV6SmVQSljyMN'
    'LcYZP0qBD+SgqmE60Hfhm6G5yL3QndGBbpOulpQLq65kjeuqrohc2cKvTaw8ccyaCu9JInyCE0sKJQ7iQ7s+VOqLQx8qZcahD5Vq'
    '49SHStFx6kOl9riyRT+lBNbqZUbqQwFaajgP0LKqTPgFtFyXeYm3e3rrHquYmCfoaWQcwSRKEPO8NFb8hAYyrgIJBQG0pMDlN8p1'
    '4NkbcEtCOiuPwWrSoYbRGcZA1LJwiGQ0w5gIYjJIuqKz3wmcvufx7/OxA8Ns2BJbRs1899HeRF/RNx/Y5biCXAMOveUzopWcLG7k'
    'amFG/MjVwkJPCAxKqsS2jwDywn9u+32qqIZdurqI/LEVlK91cQaomSx+nLTddPstXN5/N+073OzgQxN7UXqMPEkeZnxANJMrwk3i'
    'dnf7sS7zLALqP6je2UVLBbnpUMDSulEfyst9t6tZ5+pdv3tlflP5Y/CIqysiObtnqS7wdGp1AtE0soAT8uqMSz6xT3bzU1z8K4ZK'
    'DquitQuXmyrRhF4SdIAOIN6/6P/IH4JGqKNxSZJ689LBOO6XJKnjS93TcWmXJKljkyR5/0WS1LFJkpYCqpckqWOTJNnle7kkSR2b'
    'JMl4XyRJHTPeyXhfJMk4fpEkdfyQJOP4RZLU8UOSjOMXSVLH4yGecQHzQ07jTH8IbDrzUNqaz7SHCMeZ9ZDlshk9zwSQI0V3Pdjl'
    '22eSNKUQ/wcpRPvRrbPCq6wQLSN2bfeYtxXapi/F4yuArEjB71rx2ALIBCyWOB7fAsgELJY4VhyBbG9hlyyWONY+CQz3vMpRYqnn'
    '9jrm/T8qFBVEtaJc4Hur3OP7Puc5ZAmAg0byPnABFoIrgvERWY2wEuMan6hBONQm1EvTy9DLqa3x1yp/vPJZlY/+fWC2c5T5gO0v'
    'BD1bzVg1fOFtv7KeqDYMFBzVVtVe20U6b/Eb+D+x36IBiY58034nOTw0ltUiDPghdpbp9e7SFrrKt2q0RaS1/c76rRq9vlSjLSJt'
    '1ej9rRrdvlSjLSJt1WiLSKMpnb5Vo8eXarRFpK0aPb9Uoy0ibdXo9a0abdDEvl3Rt2q0RaSJEtNbNhoN6WzPxEc2etpUKSnxeGSj'
    'lwmbIuK/ZKP3Wza6v2Sj0ZBGNnq8ZKPRkEY2er5ko9GQRjZ6vWSj0ZAml7AGuh75b0sN3R3dnD9tOGI043fTDrxi9Hzzc5z/8ck+'
    'eLgKLjBe6/g+9vs+75SrDXnPZHnP6KgUZN/n85+XVqN7zCIlcF6/x7/9/h+Dffzb3L75Pvb7X+Y2ld8DinrCh4iMViK7zHeVqCRS'
    'PuZ9bQf/J9vByD9vByHvd2r350rHT3EuDoP8mEP7pQY/qYW3p5zEu/5vGBh3BRJd8UCX23jHHkryj/qVqdcCuwnTziitUylpJPYF'
    'fxCznQpklng1GBkY96qy99HLqVPiDN0UA0UD5Yw25G7iq5WwSZMGZzAU7ZTeHsjH1KXe4LIzeX01Unpdg9iC6E63k1d9mZacViBi'
    'OB3YQ6nXtP4s30J2dIl22xMBP7H4n3EHPoJASMol6PPn3TAXj+/X6gVYn63s9Db5L6fkqqbF+XHyPw8CIH6MHCTqqB+pCUdL+Fwc'
    'Tb6zIqq/ETY0LbpLel56PKDqYcmJIayqYrwBVM+BaS2BhcnhJhM6WWfSiKRwasQnl4mzARiOc0BZBVyNnwVaJe8B3JEAFCPa/DGR'
    'fgs5Lsh4RsgzIyIi5LhNwq8fbJ32ih0wTvejWa8Pb/r0rk/v2T6yWezGoW04S9IjjvTp+DMNjWzo02e1pcbADXSrEphVDROBZeRr'
    'vrH06VufvvXpW5+++e5AfYPxlKGibL2ObHtuoOPZwma4BZs6Y95SNqSAMnW21QoBUX6hbCrQ4gq0+Fr+MZ6WriiuEytDxfN+Qcc7'
    '43HtEsXWCx0fjGcwnsF4BuOZjMcivJPxTObNYjyL8SymzmK8uJ5EWwJHtELUo2PGs8afTpINaHehrJbeu4ZaA+HmwfmAtGcthEd7'
    'MF47/4+FLrYsrLV+///398x7QcMwjs+qBtRckHKhlQqPyiljC4rO48H9Ltz/s6vFMfe/cL8L9/9E8HHM/T+bqI4HjxvPL/c/oPA4'
    'hsVxTxxvjhlP93VQGT5eh6D3eh/h/v/r9kn+puLh7b2xy38deeuX+xzdSxkaBiAMnBkGg2xcEZnhTy2isxQ/orsaJpuS9VCs8UGp'
    'NgJ/vTjjSEIbLlgiAoT1K/QrOmtWmaIJOoWGAaIWSHcWlDsr9fsuWvr5i0sZ7aIjsx2BJHMxs9UyXFbN9oJRKyCEPzA5DSTSrzza'
    'MtsTH6W+XzTorGBrk8RkHMAaYcqohCdcnzS/Y7UuBswrNiue38z3Qo05XqcpJVBRiikzNlzzeifrkfP+1YoUJRiH61gB0oWHQUcB'
    '7bYugFplpTaF5zcn6tek2tQv3Zyq8OmGWr3ByRxe/ZfMB+PiwwE49zt3XDpUKY6ymT27kqZBQcj5jGDGhJpylhHbriA3oavBRZq6'
    'JrBvTOpJEVeH/nfRzzUOug5GHKBDsgNHmvHyjEQVZCRihpXmC91QvM6Ulm8VE/r1fdSDXm8xIb9qC4nDdIsJ+VVbyBzmW0zIr9pC'
    '4VCJRGHlo8peLHusz82bdVEJTGYYyubOQqBDkhiGkfDFYRiJzBfhb9QENzNvl5sI51deXG89OEneVmK2Sipn41BJ5bA8n5LKQQ9D'
    'yV1wOqFQwgho5AkuJNPUBXlnXjgPbaOKCThB2uUaRmUYlcyXYSjZO6WnBu4wqX+pQw0jj2stmTRldKhhJIaR1JDO6XlcC37cr5mK'
    'n5j+C22X6Bg/Z2/bJb/bLgJA0HbJ77aLLFXkIdaEGcGnRZrndP0k+pfi3yZJDemCx0H8abQTNY+7/rT6B11XU92Doemg3sHQn1bn'
    'YOpD1TeYuqjqGtA0UEsM/Wy1y+zQVq1Omd/K+/mlb1HuhU7f11tYT8r/FZp4x+k0WquF9pyWw1OB7/yw8WbMNmmM/7wsMbAsMAR0'
    'Jfqzy/13flgUkbJ61AUt4GlTmPm57i6FbnUANLrLo9ZO7S7Fn5gB5DX1e6ua2lyRqCNK9JlwVOBvi8DW/giXJmDj3djV5O7T1DyP'
    'voabU8gYnbW8Uurd6dkHQ27fVT6cwxadRvbJpf5/VbF5yasPgZNdH2B+FZVf2mKHy5LUojvNi4mK0lQcGR3yGa29AfYiq+03cGbK'
    'skgY8tHTTqQd3de1d5kX0Lvo6iCda1okK2Nfoqp6kUUoq5hBOIcHAeXXQrLzowp0iEZdYUsTzUUTS52ZgtJ8tjsMW/U2iV+Icwrg'
    'wmABHsFxCvQCPRtspKDS/dt/XhVfYhWLvVG0NHDEexIWqmKNKWGvooypBVoh81etmHHYdDiopE65bmyc1ZI2YRutaRsOg+QCAiAB'
    'MEmvjdNWbf2rCu+Nk5JaG19VeG+c1NnVZr5V+NfGWb43zvK9cZbvjbN8b5zle+Ms3xtneW2criA/G2d5bZzru6BM+dUbJwXWue/G'
    'WZ6Nc1J2nOlunOW1cdoBON+Ns7w2TobRy904y/fGiVOVN87yvXGiiOKNs3xvnOV74yzfG2d5bZwM47Vxltd6Xt9qRluj2OutelRf'
    'ekhsHt1ybOwxxRvO1GfP4X2peJMa+twxvZcVb2wgMvry/le8GWKJKUfMpuGwgepD1aJH8l/te7QP1Nq3ESbYE6bUy6+Za1Re9eT5'
    'uD3fGrJgcNVgOI2k/5Gwqxf6CA9kDv7qYV/F9Ytzelnz2tErQua1bSxieN2JoDj95ob+c0U6v9PSnb7SUsSn9BIA36iuiqMZ45P3'
    'RHyLszPop9j99Yeen/ULWiD/nbnGv1apnzNqkboNmOFA2a/O/BV/qJe1CEZYHSs4RJPvbDJ2jJ+A1y7YGhevdvv9qjJN2EPRrLYs'
    'aKGAVjBDKHACUJDQJgeGAOUijJEL8F3A2+dZiNdto7psXaMQrLNw07QB1hXgD63I4/dQQAWXWlwJJtwoEQedHt75IepNmCpW6bWV'
    'mCFTrwfKLzu4MuV8PhXMFvS8Cz3wYoHfQVmvDFzUyrDFiCtrpTPeEhHOodBUQCmlIG8rDHgwb23vNtEOEKLhlCN7NXUKZIzAg+eM'
    'dACSdvoDukQG0+SfTtBpq62YSqv/k5m/3jN/vmb+d0EG2rcMnl6gLhBgm3kMwjJuDSDKRjzaIXtNNLeuiGbiamUTCiGaYVUgh0I7'
    'k3QrgQpbW0QRliYDKNuSsW0rtgQvAq+cMYEW0t0736GChSrTUlnVVP+Zof63iAjj+Pz9KrJwHJ8SfaDus44Pu0Q9hngNWmRVO7mD'
    'mezGUNo7vjRUHUqxeWLyDV++SsNzoVnOLCZXQ/IxEAyulsTDODGw6wisV4u6IumJJ0/hMConGw3LhqQ++lRdzmToz1oS9BRRIlGo'
    'BqOOalCRcTkLhVYcDgNghTBoB5jUae4UVHkqunTmBFbcaUp5QVIvFHX/BEXt/xUoavkBirp+hKLWbygqhwu4GVTeXUGf7c/7XUUI'
    'GXpEQKCH5+ML4tYKTFns4iw5uApYzHlLfd29eSK7DhPWf19Pe3pUQCy1YJkbhSqlPEqUek4HZYFGhUA+lsNVgXZLBNKBohHtq+B+'
    'dbvNaxRbrk9yuw3vqYPrrdxuk1yfqVAbR2Qa6/pQhehdH0ozXh86msGYzQ18nNVp7etDhZpYxXqYgDGbkZlbFwAIQX9Z8AXUoL2Q'
    'BwhbGpxpK7990ZjtBc6cHCq4LQVZ0XLRmO1BS9jqtuaLxmwP0qIxDOMwGIZRGtyPti8as73AmQyjr4vGbC9wJsMY86Ix2wucyTDm'
    'uGjM9gJntjvfPRHvxIQc0uEJN3Rx+n65mrjZdqjmEEVMoBhskgMIZPAIxYaRgyVWNpN9IkRzU4F4UaVbdEGaAl/GsQlIfh8Bj42u'
    'z3LtJDUgl3baTegbb3OqtSNLolagTKRyoIE3e+hmcJvTNIFr6VtYy5f/U2AyQScIot9NpJ7+X4HAhJ+gRfdA/5QYV+Ca3condbkM'
    'ZHXHZmehYQOw5i1lmBLdHNYd0N/9y9d9SOrYFr8utmRN/BA2whMBhomXsiJ/nacUrwFJ4OQfdt8AVOrR0r3J/bF1Fv+E/+yyfuO4'
    'P2X+ON6QvqRw8/jTQRarmCpbaeRcijxQ/MARMcubWOQyRmuTqc54TDgfjHfweXbkGut6e8exzbcm1P5p7++t48V4FmIgi88zw2Qz'
    'no11024olNAFOXu29QPVh0pXCXr4jBn+2b2qfHUeu894HmUGFhmCFBitSlDsWVVMfykuNcE1RZ3X8zF32xHb901oX/QoVYe8Z6x7'
    'lT1V+30ArQLQkxtRbo23aZqLn4/7xNzp/OdMt8sa4Td+6DGeZr1YocitoXmJ9N0D2/b9eqy8rtXd4CO22XMdz5eAchtfjlRNsnMy'
    'cgkh8bCIa7NB52giIKATJFab/uZtG+HtvGpbYGKz/JRrNby3z/B3isUsSi7WQnNUnVltFa2eELeAUJeSU4RjrOgw/BepW+gUVCdz'
    'ln3MqHuVhkayQvnQThxWLoAwVzqISOVWJ/XvuCmWgrJD6dzTGFiQiwVjOEM1AGoYEVVAlBfvNgrHG1mgAipLD9gqsRTEnsqEmMCZ'
    'kx9UZ0KbnuoEz86ZA6ICva4zJ32azUSajTb/JF4olV6QzhzMkjmCnKk+47+c+J2TDU1DvKrqW3Hi+HpUMVF03HV84L1xnDg+n9oj'
    'VIrjyIe0ROm46vh0Sc++cjLvqSVOx03HJz2u4GvjuOo4NOt6FMJ0zOdFiiZVgjg+dxUJ+4LUUBxXPu/crSpVgjiuvH/0lab0g2IG'
    'Fj4vMGECWuqY9+O6d6kUxDGfd15rlMj09XTEl6/KAc+kEkk8dOT5oqoL/XsjLeaPlfMRpfh2k+2zFuto3FqRutPqkxTlR8iQT5WA'
    'dqaHQmbQkFpuwAY7rJdhtsr4OHfO1rlFfRvrLoULHaJF/JA5s3kNZnLHSEU0dJ1/MaqnPKVgVpzXkF+ZiFhM/bVhjeFhhbdhc8Vu'
    'd5LW3Q8D16h61XYjyhHa4RgjcdNRQzHIsKVHbDYLhH4O0YdjfR+AsS4N/yjoSq00qkpYXL/uzYsL2YU3PCtS5UlDJbiy0lSWns0y'
    'hVlJf3OWjuIR4irWoRNvHp+F2DVyextALnMp2nqRaVTpaI8Sis4k9D42vzL31ROJ445+CM4P/7ByCkLSmcZm5UZHhIlqXLfGjSsd'
    '2ZhzVbRO/CNfXvqXS5Ji51pUVJgsXlSwwi1AKIoYdUWVdKzouAdhqSN6qDrSkb4DkhhxYCZjUlEscygIU7YL+VCNdxqbYBpx+Vhv'
    's2kzk17m+IBgaJYWfikKy/4wkAx8ZWf5IOca0N06XpzbaXrelLb0RBnsrHP7zdhs4JatIkgpfUkFLZJDJ2eL5IzPjSvKJFVJTMHb'
    'Ww+TUqJl13TB1cBXQv/RJW8xL2JWYJ4R+y3p40eO2U0FmawWBTR1wQeaoDtqa2ANooaHbKEeX44WBpLkvC0+lIy3h2ha12h6fCjZ'
    '7ojhkOuO+FAy3RnDIc+d8aFkuSvZHqNd10osNWI4FH92fOjWh25dg0QCnHQVEpchaZpkcuysaZKZNVlWGqet5UAbybdOuE1LzCE2'
    'Zhmd+Jp2Widwxg7UqRqtONvXgnDpBLO08dgjQMU0pM5JFpvhXiBrKCnn19ycGqQLWnPdmd6/Z/ydieAF3QJo6IGPt/npbnA1MU/d'
    'ttTg/+3FOplQetv0O/Llbpqb6UDa3Mz1xc0sHwfRmxL2Lr8pv8238lu2Y8bN+S9581rhXvZmcfoOykL+GFbR0nKy3ZhxqWCPl/Rb'
    '7Hi7WkPCqflO9tDI3gWcJZvOGGuOJDXsmDEvNdNJ1rwGwySvArMUG9u5ZlCtRDaciBVPMlNsqVCXR+crwJcxL6fhg9WSbdPQEkfU'
    'KMVaEqMWO4Pvl0jGLBYvtG/VpBusM/aBixy22iBvFkcwNsib5SW2EY/opDPMmYwLObvZZrubKMZ0b4PYKKDfwWfxHRivtT082GrY'
    'qM1GdGwj88IYCoMqfJPKsCvfo6JvWrkala/euBbNg2E0jeE0rmdnPJ3xdMbTGe/gEozySJHM8kiSTMYzGY+FfCfjmYxnMR7LAy9f'
    'HV8exrNt/M549nxuwZBmfkw+S91txrNhbv6Ha004/xJq7zBI/vW5K6I0/azzS9WYepmAbLAFdSMBvEUDDxJ3up6EON6KIlwb3N/f'
    'tIeSQKpb+rVLt2/gCrylBpyuxvRUHLMM16PgXJAiBu4eNICuR3eyai/0R/awBI01l4rLJUaforC4LJroOkWx5lIotU0b/GFaG8q+'
    '7al7hZniQjH3JbrkC8F1uTkBscCkLBda2EXWHSFOpCq9yhCh1OWnOhbj2m2jw994XDwfKSLnCxtvx+i2JiSINkvudycVddFFHCoR'
    'bbrSrHuEixOnAOXYUnY43xmQYtMuVxCPtjGezfkwmiukQSHlvB+p4zPi2LRi0Romw1fbIDWCaDV+qDAv7v5cSiQGmjsndQZ3XJCW'
    'aI/QRJaOUtW8yzAfbhG+ITK7cJ08ziMkVk82YiPbvN+yQdsWlt087pO4ddwwMMRNltjM3OsrnxnlpPKabDgdd8ADsUzBnK/7EWLG'
    '8p5ab75C2gF9WhJTltTtB4mkoi5pZDH1g3ZiIAh1pQQXnZL0jaDmgK2GViARTSWlJcREU7pY1ICCsCCdEKxd1LRSwVflYuSGUSXG'
    'HxrBYrQetWKHR9y6Qse4nktpuuM6o4YnLqdF6ihdHtVlXtpWl+pVkcvqkWDWIzlU8Fah9INCpFBbEnKeqBDb51zb3nxJLwvqKPAk'
    'mtFZK5TVpANaFtJ0+/zPIrxjEAWqZalPamTXv8AwbKldn75RzPgqcOlQHBZHI446a25++w4GYud6EoaMkPwKh+QOWaOHBA4fTe7o'
    'WV4PxFa+xLzb+LJP7CLYFQxlw1/pIjxxS32sGS06fq0bt1YGi47LJQMdO0rEwf8TzyAKxCHvZCvJipUkmvyL79PZ1BdLcy8Q7IpW'
    'ng6odYNX7ehBbCwruxA1USTutBYmS7JbHcEk8dzETDtVfM6pIybrRkC3T9aNyBi5DBTKbOUyFAQMidVLVRHLqQjMlgV8XYNFd8SI'
    'h+nC1qoXdmIv105r0F6vhWZWqY/D2Y5UCTFvmsDbmtzKuZLfnJ+3CGJ+9LzNVYX1vgA7w4nf5HxAcuwvo7hXmyV63hNZRbkqNapF'
    'tX6smCujQ+t5G6JtPW8bHcLcG+nqc9v/QP2Php73AgRugEZBrxue9BwfB/e61PCZbn2hkqWRoq6Bog4oNVe3TpbXtPMucp9OI9V6'
    '3cNCcxjpDTvLkvXN+u7VJprBmVZtphlcCYUyzeD2cc9DzeAGbPqc2F/y3RSrXvLdxXseC4qoTd1i3e7SFPuf5/lKlaJvU9zbqd47'
    'veuqiJocsnTWA3klLntX0HzO9nXJNmp5XA+VPBfHeZb3W9u7ciLOC8nG4qrhjZyMMprJnIRhZ+Nme+b19uQ4j3q/ps7UCfA4vILe'
    'Rv7VK+idLd9tdcmOz4PEuut78OFx6AJnt8jLdiOxb4t1b099kBiKLar7fuENVx3j5pcNncRirh3UFZQpptsMO14X+i1xJt3fSdZ7'
    '9cI178IlO7oLWXOAs69ELFoD//EmMOsvCYy2vRMmjsir7s+8Ib/1HnoqVXqJp7R9oo2oaku9tAXMtgfxrDYp6JrWNqOrrlsVONKu'
    'KonYGUN7dIqYsIoH0SRcgJ4akN3VL6K/0fHqtCaEBcm3uLPKO2OZro4Migcje942Zyxe7x+d9uJEZTzWJeEhz3QZ7HYd7fkGnKHx'
    'bFbHBNR2nKklf21dg/P37RevdrGb6UP1jCK94n84zg2q+1A3LKnGqFvvDCd323laaj5UXS3mNbvl1l1Y63aYsqPTy4GbBshG9X8C'
    'tumsu2pdQzec4/O0Yf9siGgrkqRmCNBCamf6ZuTN1RdU4FxxAlo4x8QGWvcF6w05OoyivFqczxM5nl9RTBigQSw166O+VeZjApNJ'
    '7hoG8hWowqCZPVBAjTijOXc18GFbIMzcW3xbiy0JbEYZbup39XavPqFWvOvLSWK0K31qt6toIE6mvEQyhNNOdl+ni2s9Wbb/mi10'
    'T7OZxbRYUpU6Kdgst0zobFfyOUzjTWlV84N2oXB1VXGq8HvRQTzSER9ppsSCUCPjyAE5jIiiBZM8oVgRLA9xPILhIX5HsDvE7Qhm'
    'h3gdweoQpyMYHeJzFEkVx48nvpLKTQANpXET/ITgLZyPjU+V1qMYD7+RF0xqKH/QHUyE6OiFqriDQeGwp2ChYF9wD7h3YpOjQgPU'
    'RS2KrRL91tAro0xzXR4ABharlxEGVm8jFPmb4Tbcu04qTLFDytoyuMkNc+mA3iDHiO2BkRT9Vk6pnN9d+OXl0hIzC/+225mcKHf3'
    'j9t1xsZUYIHW5RPTG6Bet7YVUba5QNfLhVj5xH7genp+e7kMjeso7QI2G+mFdz+xXyf2aw+HPp5AntGJhdcmKlsIrN5YkADs28ul'
    '/ebl0v7u5VL+8HIp9nJp72DQcJxcHQwaspP7azmRcfZy6GfjbAuVYYpt/cPuBDScW6aDwWGbbBdbTDjFFLuyZO7s8NDJ6PJHdBub'
    'hE2264GDu0l46OL4NCKqVRurdYeHeHHJy8XCjOq/rLcFNitmvu7tdt/Jl0i6jZqy1lG+ZNsLQdvjvVqfZHnvdzCYF5XDJxi0LfAT'
    'DN7Qz8HgDf2eYPCGfusd+s1XMPiEcU5hB3iocHIhnVxAJ6YUbOzAcXsIFaeMJCUeXSf5V8rfqcLG2rE2zZAVEgBQ/Ely5KFt1+Vy'
    'NS8pro83LTqLMtCotEkNM4pfqnkCr0bxxQ4A0jfpKgVNqUvgeT9VgWrhTmhj16aK9VAf/1SnVGyLEEp+nCOZKhph5LQlWAAtuywO'
    'kkzA0GkY9s9Th/un9R1bWcUoGz5aYd1raIQN1nuL8AH+3v1niT7A0ON/gEQfQgXtZ4m+bofQHyX6gIYzjIZQAYOswMoZBlIEV6IP'
    'SDrDKPAtGQaSy1BVM6D/Kz8H35JhJMgCDANuKlRVmZxBVBUxFZqqbNIgqYqUCkVVlFRmpAip0FNFR4Wc+i3RJ/JC/kGiT2RLfSjK'
    'A0j0iWxZ35RKJPriQyGjilJpb2nYwi9K5RNWMAk9JdXgO/vV2Z5VMI2H/RZM87tg2l4F06lsSpTspY5e0BuW2NPRZ1/CMYct3ZIp'
    'YJCot4LhcOTeKoSGuezW2rEP/Uslce1p7GxVTmT9VS9tn/aql6avemm/9VI1LYvyjyrwF43jaul5bV8nyRJmRNaINI3YuBpujq6X'
    '0lo6MVPF7FKGBaDKAZRFe1dIOHWSt+ql9lk9K3jUSysmkWR+4aVbEIyBxb8Ggvq2FtxUdWmCbk0b1U+rKhGWP7710kr91PVS8pXw'
    'RoVJ2bXIRgXCviWxhqrj99RPB/VS10/nq15KPXStV/10veqlgHG3N6P6bEZPQnRGGPtWc5ctfgV1qP90fXPb3xqpkS0eY1np88iJ'
    '2+fXqTgI4ifnEekYo+jaHq05GYKEy6/UCzSdkgUpiKc2gIulCS88x0lK5zWl7PkDGK3J5QQJUGQ/vGQ1ir0dcNmghDpZdw20Vonw'
    'WvJ1G9UUG9V0G9UYIhG1iOGydOeG6AbLwAHeRZeVS0ygVunWo6bnb3u/fVwLyXlKsJpgxiLSlODO/5lyKg1eZbxUvXR54R3iapLq'
    'ZIpS7nmJCCigffL35bXh7zt43dfO1z9cO9/uuTP9w7aLXpA2bSUYPyxbAAbjJDnGHK5OZlc0kDnYJAETBMywMtBQMSRKIOcBM347'
    'GbavwG+/DGIS0/PvHdul5AOlqFwfPe8GxWTIYyD6M51LPzAWDD9n6hEKYD8qpkSFRa6BTRWdMGKL8nn4KeQ4GswaGU2F0zLo5mwr'
    '244HnNDaqg0lTshpmSRSZ5rPDJ+ZfIgMfVwCNugJp8NJX/184QXbDadlW99l0w2aIUN1OSGwhk0QmLab8P6IjIEKJXcjXO3ZSSPk'
    'eIJWehAwDRqqidmkObCK7WLwVvSzR/+KMJuKTLRQcnxMjcf8KfSpK5OLm2hbkGy01sGMx0MeDAxoP0P6krFXxJSvAFZwAIzjgvFy'
    '1cW1898myVmULRcGlhNS+BnexiA5jJaLrrdrW5PqYjj9VXlhLZaWIYFjGS3j8RPGyoteo4iwUYOPPQ7DZupvqqXlZ4/swuir5zio'
    'onaWnUKPsULiX/QgLxmGRuk18WLJY5yECY2PnezwBRUBAgCcB0CmR/NVTsru0wqFg3dyCPBmWMGBmyRCES/PiBydHUQ2Itrjh3CO'
    'UljIJVjUKd5LIrVuvaUV+2AUFWGF/OBQ5NXOBOuKyPppSzVHamf3t25dgCiX+smyn1uCLkt9Z6pGJ+b2ebaa6okiVDegl8I6IviW'
    'hZg0FHh+QNxX9ZPPVOro8nTFq3pMyjYwoEipGsdl9Fxjf90fCHPRFM6xxrZxHZcVeUVAFJt/H0YszNiVMVxG/vEaLs/8NlweL8Pl'
    'lY2aAAelpoIEXF+Gy+NluBzphxLg/Oz3gHMzpIgT7QC/HerjAkORfZIcisqgYZvMCNBh/YCUanB1spsa6aVF3TpAE8gcpydbHRrg'
    'Xey6gxGufIxXym7Via5eyEiveuTxksQ6o5JsDpCX2hLxPrax0mkU0ThpdMVnftUPF1tsTw8DARypkLeZulwFeVupyzWQt8iTHemr'
    'rK17oY85QeZuFJ8XHsybHu/Cg9lsWtXlCnW5BPK2vIG2rqddoG2yN3KaL4qgam5ut+Zbc6svvovAS8NnIBu/6nLW7HjqcnZgKV8E'
    'jHC3GK7ULeKYsl3Iui3Z8qYIXsnM7nLTmq+2rVqy7dW2nYh7a4uN1Oe2ZBsFsQmfgroc6Y425uX+ErMquyeXLwG6m4G5kx2VDS/Y'
    '2V9nuW1rqvLIbtJWu/haMlVn0ttR+fJSrqNyfZt0XEdle5/JUdmgXoHE7Od8eUPJoUy6vpzVZ67DSHr9zi6uLroHrkjIf3kDf324'
    'i9uIkwNS0Rn/TjAVDcKexbYTlRh3FnssV+7X5MHljKHB4bHsquks9liuVE1nscdyfbFG5bFcmVqz2GP52m6bqZjru5zb/C2av0X1'
    'CKtHWD3CB43tET5obI+wXKS1R/igsT3C7BFmj/BBY3uEDxrbI7xobAZ4ocFcZEOHF4O70GKGv7i+k4EZmjwZ+mTkk0EZ2jwY9mDU'
    'gwEZGt0ZcmfEnfF0xtMYT2O8jfE0xlMZT2W8lfEYDV8Zj6HfhfEY+1QYT/Ed9CX0FfQkZDxcPk16hfxZE78qX+ELAAXn6/FteI/v'
    '0vS3+CZ8Mb5H1dfmW/Cliq550VfmGzB3ir5f0ddljjBnsr5b1lfVF9O4NCy+oq+ov2FJIWkYJY6moy6FIODi/zdVjvU3wa7/FnWz'
    '+aVuNi4GAktGK/ZU1tKGm1pHSW/Ac1xAHybEmUkbaIBi7jT9G6pIFZOuOr5b+SR5HXohe/vDd4uK3z+k2D3WS/hsvr6g/hx2OV2F'
    '9an3Nl46duO4HUWhYC/JaO3LPJ3s9JaD6ggP1uYl7fV6bXj0d9cwyKBIb5bxiRcr3l9VGVJ8sLou749miAR9sB91l7yBUqGHbjGi'
    'nVHLLh/CHbEAkch9tQnyd5sgf7UJ6nipAY2uHnJH/bnS8x35usnm9VIrbtzMma7mS7E7Jr0vsUeXYlH6QvfKdplDPzZN7Tc3JHof'
    'tXz1vnmbd3lz0nevT9+9vvru9Z/23fO7dP6naKHL7aq971dVnhI99fr1quRT1qfGr7K+NIRpBdAX0HCkIUz7gF6ChoOG8H71H2hG'
    'oCG8Xj0LGhgPKPz2Odz1uE2Q8dUiccfEDZT+3V7ZX80X92LcmllfjRvsg25bB1lomj7ofFud2pxWGkZohFvZujPP3GzaX6rYg6nu'
    'RhXABtpYsFNuk4th0AK7fL9y+2X5+4H4fYJ2OCwVoFLHp7ARNg8TFSfqQf0FbtgLQCoWDkctiKVk5NeSA03wpAVzvWmC7aENAgJY'
    'gARW+u0YxaQFDeMe631tK//ZhP/yowV1dtW4EWZ1GxRy7Pc5XwwZ2mSnI5LeoQz4fJMlOaMpbN6vazJVqOjon6mpUtWjqKIdFClr'
    'SY8BwZt6eb5Z+JeNs88B3p1SAkjdyN3mw2vJAzdDbF8K8U+BowBKLFKwcAtY8eBsMFkLvPTAvUk4rAqVZcI+6aCAp5B47X5+Mp9x'
    'OG+z1EwI2iVLKBGkb1bu98Z6pkynMGlet22vzZXO00gGJ4Ksyfu1pp8YqWuKT7gzmy2Y0Rri0ZT5BqYxOv4Lo9HRLox5kAYI88sy'
    'H6U5HsHx9kifejrOxkk2NBDP7QKJxudl/fmTQkY4o8LUwLtxqKPYH9OEpYrbjnkQogA1fIri0TvZgjjfEBXmnWk27rny7eke5Jhb'
    'Q5xtRUIj9tmDKFexsV7N+B7xCNvCKS/ETlHFAJeLZqMYLye1SplTzpuNRp3aKU2tXpm9N7VkS+h2NBUPA4MRpSpVUlTQ0rIa3ztG'
    'cugkZ6U5Hl6BqaVKNmXEFKW90xgb6plGCWyo9RWwyqHm1TyP3xTINBq4qEue4vCHpk7Ifet5XtIt7+oLwzPebhlrEmkhqFQ1s/xL'
    'rG1VBI4Kwq1quQsaCLqAO3HY3VSWiLlKshvMZdFqsQYPuSzLt5yUdai53eHDHGSvaoDxf6dmonFQU1CXYTdRkYNi2aixXCx6qkWa'
    'NYvkLAv8cr7CRJZ9a7pON5COLJxqi8JtJtGT7mqQgoF0Gq0bA5apzHCzPZ8bstCGo5i6WPSzWHJLJKfzTAeKteOWonXA8LdTds6i'
    'ms5HEX9BtMPI+kTryHRUQWc7cM4z2zcdjJMuUcjoqLMUZL6MBDS2VAArKo7Z8BAVboMTZXRUpvwJUpBGiytDAGYrHJKFRzRgK+Na'
    'WQ3pCBqlDZavWcvVOoQuZ5UXJCYAbVrYukWK4Zc0+B8F8cHu+BWx3dZf/n4bFZUjGk9lrtPUVe1uf8wValQAO2or0eZLOGcdbGQV'
    '3m+g2hJOULaCGKLPxTFx++D9iaLihDwy89PrOuHERJNs4Sg921t1IBGeTE3LTQ3Vpc8ovrI1al6fau32xodJ9urGI6LbuEg0RUmZ'
    'gPo7D9bJMpaNn63Ku7ZPUDJdOIFT+7TWgZ2IYz4YHWg1mk0k+vwfY5uRKrCKgf2Lsy2q/gtx1P5RN6l5g3ep7Pu4fZ+u+fXaeC1T'
    'r0mvSy9DL00v/A4tZ+zkbIU3tOuNfD3pFjZryfZvvDbbr62PEf2CPQJoXdp4o9dNAGLFuFFkOxavVWStozAsBwglfec4Xs/emPX7'
    'lcZqRjjaqpUE6OiCkxDOb7mOSj47Kk5TWEjFceX4jkEopwJRPrwMAJ02K7bxd/m4DpB1w1WumBogSTVoIVg3eKEo5ys12vdoe3u1'
    'QE76TBxVKDwMyruSmQDSfCPqHMdLkdyQtEjXf64yGGPNVQCmrVxxg7ofO35eKtFU6IQ6WsCotf0X9dqyg4Ein7NzdMp8eomjfpvX'
    'opfGkT6h6ROafO2bPqExKn1Ch8qrT+jKFU7pRNvukKFa0csAooTG1VBJVC9xpE+f+vSlT1/69CWJoqVP3/r0re++9elkKlHINUsJ'
    'C7fC6wCeUSjrD+LUwuvADq2YgmK+Jq8DD+hio2k4lIXXAYOlmMkCXLnwOsYL8d4YT2c8nfF2xuOOV2c8nfGCN4jpZu16XpX0vrRw'
    '/HDEZNBxeIng06dpoXDjvBb7983X+02xRGECHEFxHWucpQqZX5g8R7Fcx53jxLG+55FCjGNPy1I49qRlPJnxZMbDhD/V1ThOfF5i'
    'PInxJD4vcV23Pi8zTWKxceWN0mYcL2Tc1nwWk/KsIiox2BhlxMnY0dlQ6S0auUXDz3h+q/HQ+nJDsKAtLJh+Bl1UtLKmzGaCN3Ky'
    'Px+GkolVDz3zOO5P2BPHjKc7/KhPy/cJR7ROFdanOObzBp9nkaPJeEyBmHze5PPmfqoXIYrE91/rW/t483mbC/wthsT5s4XQAXsf'
    'F1MY/59rLLn/RmHc4pat+maaccR7v+nxwXAMzQQJtpzoSLgTyYTZ92xfV74sjrWg4hKKlmlXUQViOhN/RO7Oq1VRKiwyBEt4DfXC'
    'BrSxoV7YkNAdzeqFt6VrfaWBalw2BZrOsq0PptX6ukX6QnaxWrRImDWJ8Ex1mjty/g3CZCSBoJt2VHICJFm8o4SssXAYmNoNRfWT'
    'Anl7LJgc80/KcvNlU7jBzus+PIfI1w1q5eTZQYAHlVolErquykQVTOLXG4qYMT2joU8FyS4GjTtz4UDjuVNVWKKBInQFgjxkC5oh'
    'Jgpa1WnCW9ImGpLVudEYtlgwYm2ANdSZXV/3sBkk2iDm64fzDRqosAbbI0ZOJ9+k5g6qdACZK+gfNxPHk3HcUYCOKkBTjVN3k8BN'
    'tYyThIt8IcCX1KUbyvYv8topsan/blhBQxBh006g88H3behs2tHE3o3/xIJq/lMLqnUtqPK3BZUV5gxXeFtQPep05lVRErY0Dpmn'
    'HyLq385YIM9ViOwUzIxMoLJeSZifpDzmBFV5LMjpejXTjqnoVyhC1Pst4UM3AHNTJI2MXZSqWHN/Wy2GKvigmg/1qstIdHDFJ0zk'
    'CONrTnEIdTVpFknPELOEqeKa0ugRrqJd4DH5YTTF7SPY4q2Zo7tU7JIXd5aujvVEJIvVMe+WOEmb4IYjxO1SllHHKv7KCVxjXYn0'
    'GzWJHb/YlJqrksZd00SvSsq1B7aAbcsaVqjvYv75mb2RftdQiWiB5xZhQum2CBOBxQuFmXN+oTZzOoNLHhVnEZQizTw4v2JFmvAB'
    'j90j6nDaSwBQ0ntO8umKGjTCNA3235KORKTFAye+9ciyZQpWzeq2k3UAuFFBYyIMAJSPyHcQ0nJB0q+DVK54NnUU64K3gfJLB1AZ'
    'tXnE2V3zCzwQjArygcD1WL11IswbRYOpwlrTXqz1jdfCegdI1saHOqKCyHsBsl5st1tfvbAJRDUFN8sAArHolwUgd8MRxzBxIAxU'
    'tLPosyk6Bvxov1wYGc0taDKezng64+lob4RgO+bD53gwnsF4B+OdjGcynsl4J+NZjGcxnsV4F+NZjGcxns14NuOxFsheBjTZ7jMV'
    'n/ElTIwpIggRzQ2DysNnuI4yAFv8oDNWLCsW8SrbZ+7da759FjG6vhPVI2y+xc0jbB5h8wi7v0X3CPt4iZ4MNz6K5TfHtkKEpcjG'
    'tnClFSyt98MZ/866v+Nvsfwt1pVi8jf1fRCaj/IiZxwpXn2We1O2HQS2xUq+zvA7ipf/X8fL68cyV7EKPtK/FZq2j/1+bS86IUDh'
    'cy+7Jktk8gJ5dhXND3ZZkmDCw6k0rj5CkYqgOwVNFfGJPde1KEk2JMk2m6jXbMRL3TBocTZzmsGUy/7WJlLVM6ReO7qMBRX49iRt'
    '+L2s6RbtqYXPaRMrVJSY3S6poyvtATSxqLUm1J9QgotqQX13HbMKieytZ8wGgBj4Yeo1EuM2KaTfvRFeVmPPxgXIbgj4EoqT0TF0'
    'ApCwTbPALuF0H5ZtfGnhhngOSGLbs2CcOFw9xxtw2BuBgv4gCCrU+4cVAdpv9RLI1/K/I9Ys2majzwDNegJbsNaq5VgrmIcgBmSm'
    '6KmGM2Xk34cCQJo2TJ9o6GDrO0VUa0JjLMJZIfuW5MKaujZnSqC1PUXkWlW8ZHWcpuLkU1BU36mn2/E8GClhSLZSrC5w/Faa1NX7'
    'iiaXUAa/rt+WlAZ51abwpp77ebSaarensaZgfeCQmNSGHFj5pnyVdDIiLjXhzIwfkVoKGwWCgiyP4M7rEygMBSX1Ps1Vie65tjHn'
    'yap8+fWgA/PG5TgbowXrbX6sOxcBn3LoimlMGZYAilikJvNVJZ+n6KoheFUl8hOtAzVXV6F9KDbIuVudJkGnBYjOzlmvkHdhJ17C'
    'dikbrnHHwuBFxXvzaELZXliFZceCETdtIYG6dNciG9cevGHUN1nAbnZcYD+CoJ+NtqkjRxsRYmm8EwtRhloabyVrfDfvxcnGOt0C'
    'QMn6/L3YcyeRbYgn0BBFqjZELMteOReObYWJ0B+0u2e2dNewqYN64bYJaFQRVK7oXw0ZO1RG/Fe88xoaX6zqNdHTU/dmGPA7rFQx'
    'TQ6a3uWnhY2mJZpXfjEEazaM2kI81Q47K7l8glyIsO1htbMMx764bLMRxTFLfxjYUnDMl4hoc61nud75nrZnusKbzg4ybSHcFN7B'
    'jhnC+E5R+ebU8yrj1NhibThlnAzfezIZz+xqluDtFy/vpX3AuITNl1yUmNaMgzUqL1Erf2Tba2Rc62Kx2RLIm4KCEB5MpU2b5T7T'
    'RRH6QwIvbF9WSihYHviqsTNmkzs51tuKff4/04z7j3JnNlGihpDf++RhsLgco3FcySR3zceTih9ImQwDMfcagroGohsAktZ6BUVI'
    'AjYoJQO0zGR1i4ivOo52IFyt5IO7ZCwKC3MMs78bRI8CldIU2SxCHlIn4aEOejxttDSE4pGxUcakJxhDFVhpsdeVDEcDtXordnQB'
    'SzYRIU031bPVITsljWhFJmTIQrR7PeLfESRPZxwF8RVJTnpN6569IQ9jVm/1w3sN87KXhWTKS+JLbdbRpWToTMkhuIYRxdkcqPxM'
    'yf1S3NiVKbk8UxQrL2Ll/h0rZwVWgAunsCBtG1K3J8q8ckziCfICW9fTJIe+02DkWB5erihLu88Q1soMAOm3TnQK2jMlhmRkN64r'
    'agVLxOws92E9BBE7+hkJgsNSZVr3cWFiFcwbu1ldfehkD92GJWnJhLayxT16xorkF1ZczRyRYmkc+4gteDsxlq76x7mM9UUX3ZhI'
    'D4vl1UdK34J3QXAyXXZSOlM4Ob23Da64JXSCHaP5tN8y1HfDKPaBG18bmFlaK7/M3nL++uVGwuPqwdnpNmjymMxolC626QNa7Ppa'
    'qd7ObSkAJ5d4GatdfcE2zelE2CDEjyGCbiOi0NGZkjds8vTSs9BRkMsf7/OmwnfvxQB0G1T6Ul/lW6iQh1xDNZdUF6ckV7zdcAdk'
    'Avy8o0UOLLGb4ZTwnrZmuVE1zCYT8fq0IhTKYLatNAPR9YCleGUYLbL1+N72PlXd7/ymfuc3Zf+W3xB43/yGyLsstPn6b/kN7baT'
    '34AdsdmEvJUK+U4QasJvALftKk3jac6pFraJHmgFPSZXgyalyJWudsXUNoURzVQAvbrLuKtewuzB81L7XxeLB6jKsTS12yTwp0zE'
    'f/0lKOWUZDfwS7S35RPRlX4jGN1V7duyZYtHWsFEY3GWc9UBEwrPsLSCRYShhjAQxyhQaJXVDVPWlAvgK3YGw2FQZwOh0vWcFa3d'
    'J0NJ7QFTNHTBdacrWdR5KDdb/Lqx2llNkkqZM2P7KRXPkHyg1dZVSXFYcNTnhjbILHPiOR/LzyGQ9gQofWBf6QklpvDPq13v7SXC'
    'QeRNS3nspqC7lRltnNMP/NH+3wX8o7OOQkKy2CpVjUlIamSLWxL2iLjMSrLN5LOdyjZVuYLQ3tcXDmrCnsau07rc68tCTqrtj3W5'
    'e5WyfJ8sram87W2aBU371S2uZFPD3rj9OupaH284v5pIDUSKIoESyycP51fr7agby9O6HqKTJDj6fIsNIrevFqDbhPsKW9hwdE9b'
    'tdmZN/x77h80+ddwPf7gCwwuZu4Z4VXukH/PcHZuru68pGani2O93IN69+ZoVenuwly+Dqbzy2wVU1uh1ZMTSNv/yBkoOaW8Nq6d'
    'cDDKhtZ1Hn5L6JzhLjmirg/Dt9j6KHvTL96+sxOebI2Y5CpqdnJ4+jMzuV0ulwvJQiWkci93N9FQDsdWfjNWYyuwdAoAWZImG7r1'
    'JFZfzLVJ0mnN7IAbUuNvqCLEo06bpCNYa4HEEKKqT3s4hP21fsStPk/Ledw7WtrN4iNID4Wa4hT2PaDpRO4N4algNoP/DmhJVfRl'
    '0Q94n+qVEGFuqKaIc2xrnwSFMqQMw6NoSW6LkvGQVkf8bf1X/vI0LxwBx8wsulreDCwjgYzi1VnPt5s+OHme1f98oQFHNqGaONSS'
    'C0WtUGBSn02kTywmGw4DDSfEjqLWbfoM2KGE1JbLsR1ScIAJa2clG6tkRF2KXhlDzCmsXATRk7A3KHWYPMcEwdQ2dBZlQ1+KGr4x'
    'QU7sXcRtloBmwr02ZCTt6Vq6vRCGo3y4ppJXD+AFEhbZEPZyDbF2ssVspnO9ofAr7i/mzh9UTW1vHc5wWB1WAOh65MslNW676tZr'
    'O8B6XpoXk21P33aL0xfTTQdfWp3/f19vkiRJrgRZnqU3vYoqwiCYblbdRHX3Sgg/hmnmz1+bcFc1CzeYqgKQgYcLWwyIPxJuv3cj'
    'no3xQAAql+jphORCGIOGkDKce0+0fg7d7HtllScvJJcSwjKQx5B7cZY1SCLh+088hpNri1d8G86u5WjgT783coR/UUitysf/el2f'
    '+m+Vj27IW3wIniaCXt0rXh+whScE0YU4cN7c4rQlK7jL+2/1dgl4Xmv1sW7qetiX83WrB+evradDXuouJ9ZB3Xk/tOdRRXVhhiPj'
    'kCV/klzNRF8Nxf9/PYhSxkiEF8mMSaJDweZUq3lpqT7WXS4KhBV6ocKRbLaNHXyVLFpk7U0kCTYxHE+6jVvI1zIooa9dBJAivs49'
    '9Oz34dM+Sgi4L1Rug2bSolUz4FA2SliDyqRLI43HZunHsAVgUc1sOshoihambx39pQnXrFJcVcMNJvVSuyAf/PhA0AH9mnCWk+co'
    '3NoGOFoUD4xNxzZSzDXwYIE2vv1GQ6CJ1J5BSiRXjQAWTuMxL5Obya76DNu6FKQ5VP0uxH2tK1msdjW7RRt8j6nIYGZSHH8VlKML'
    '9da8a6KDK9gBP3kgJuAxeYBI3AYUoLEmzcWlKD0fGFpQ2W0QgXgrOVO3YSjZAsWxlOrntEL+sY5fXyOolLXxxK8yXaF6/UdIpNx6'
    'jXGwApye+U3lO4jHmtVi7DmCD7NVBqs2y8Y4GuFbzukmMNo4Tx40603DXDOR3wQmoUeVol3YFRWiF8PStOcqCBLvc2BmNJubahWG'
    'YF6jeJeMK8iVS729lc//FHYwBGprWk200DS51GbF949ARl0qrA9+VEVV2lB6sjbRmtH+VSXYiceYvAggP+KxtXAgx9RKFyCXHq3C'
    'oRZ9yAVuyBxhaCH5awDwHCHC9fUakTNMlTwqeQZtLMUZiC4f0diSj8D02eItbhb9LdbTxrPgSMjpdPp+IxuVhyTnwEQr7uMXbAWL'
    'ObUFjnU+bAWyHLxdSuHwNepxrA+h9T5wEtFXxzDjiE5kkaWw5zDeYVqnjBtEs4xcwqKCgZ1Tzha4R8de4RKeaEhJOUsbJJ+Z+bSP'
    'fesnOxpOLK0nnrPUPZYJFIBMbBjX6xbcJs7MJbhas2kRUmiZsR5Ntkba61nZRLo5aXxnFoU5ZUd/O8N7/qOdVcdHumK3Zx/t4/c6'
    '+bH6BvHH2uyz/ggWR87xG08Xgd9DoIKWk2eJlyjP5Xxze3C8XKXE1F5I6g/yVpfKG8UBmp6sXvErcg9SlQBlmIaijboIsDs9j+i1'
    '6RkKez8+5aplE8vE4xYrUhrMk7dnORefg91oYCvVbUEAkOHCJLE+GAROHcLC367/KbQfzjvmdUWA/9+LAP+199Ww8u7ErN2+jo5h'
    '/TrZvSOOQVgvBWVJ/m0NfWgt6izQ1PRqlpiyYN2SUyLfx5F99Z4LZIIULiB0yea2Sm9ldyBCMos7g648jYBi39DX5c4r7aTtE4xW'
    'S4cui6mR+OmidqBeVkGp1tJRBaFwD1239/QOPB95/igMN2GZpsrUdwnuP5kPL2Ed7ApCE53acsRjjrpBYOnaFj/088Hc7cj6bVvT'
    '9KiaLl/HVL3gMerQ/4kN44cOmnBVHzpIxPO6zJ0tin/mBB0E6X8y2Qf9gAETMqiOp0cg1XNEFBps4IkLzquer48/SMOD7eZ7VM8V'
    '8sKeakhvdPxSKsLKbf+q5+AZXvUcz/NXPZ8/tJANvmt71fOjmI7q+SYOp3q+0WBx+bw/nZalBg3W7Ush7FFEOiVWiMQk+/BWN3Eo'
    '9Fjb5fMjxPVoDxC0KJgLEAR+C0DQVMDatWMPGjpKjob24EZpe9S/lbZjscxoOw/T3Chti221nuPlkQRVLrh/Eu5yp7yaHyOJxiMV'
    'XEZ+15HrxUj780hc+CXqJlEpMukU6v8SO0tCopMs3tOHsydSSt9BATrfQJx31gp1Uxl9zYymqnqboiw7l4eEpqnkmZr3BSILDEuF'
    'JorWKb2CRnAxUyvSjXCrykULIk9VSLiIb5uKRWuCje6WZbWkfS4W4Leb0F1PG0Ho4N3/Zpu9x49ZMlR2T02Q+AVy/SWRQMqy6LhE'
    'm1r4RYNIyhJh/SGSihbCrRub9eHxEEmbUOewsiVgCVRC4jlst/LwSMXIouJ6eXGp2Fj0TKFyQ3tosDptt8KNUaPf2ODq0oJKfIfQ'
    'MbHBxqsIcGL+U7f1fLccsPFh+cvcfyswL0sItw+CZVkpoGEbpJxn1o9X3HJI10zPWV4zO4JaONXEh32VWdbaRuBTqxXuxM6IIiBT'
    'W8hf9vxbXNGotJ1p2MP8nNkWCl3/cYb3/CtC6d7v161g/Bz75fi4hN1iGgjNPn/W4VSL5jLJwookasXdS3H3GhEu/no0Vu5TOxe3'
    'u3Xlo5iJt4wcKj71rcBzQOIjM9+j5/c9iXV9LcandSr/du0P/glCM7km1bc78cVINHcUqoF1RcDRXEb/utVHQE4kkZaMcNSkJa3p'
    'HYUpjFZX/cF856+1vcHgbnbPvd6xXlYk9/87kuv/6jpf/YicjwjbWu+4fpX7UgAcNtb8wn9pHE+bmWoJurMkr2KnSFQVAR5lxVvK'
    '+FNuY5EaALjIJstLPXD2vVxoyb91e6emB9WxBvw75zVefWqv4uQ+BAcNydMMiUDN8RL3jXTTM1xtzcv6+ZhatTC03xOx+QoW+8VS'
    'D7PrXjfQ7x+XMtDGnXT0jsWgngirVVTtHbUpoC4Ic2g6hNwsOhx7roK6ILqaI3eYnAyZznea6iIlKfqIF3jnwsjq001peULG6IKo'
    '/lBQKQGALlU+cgstCCGeWJfr4JJ8yZSr+zmul07jVqZW/T2twvHmU/nyJYb7etMp7HSylDr+pLAH7vJmws79ka+27wbpo7gTPy52'
    '3txuUzPCVLQe3KxsmJ5Zf7khidKQ4epoRTRS/A6OpQOWD5wkOspg7s4Gn6dIHXmPsbEkRv1mUF48gPKfJTFWxYOqyHFYvbXOHEDz'
    '99gSLu0nf/0kXagApbYFn3cY7+bzDuO1WsthPJbPZk6gFTNMTjvLDXYXKQ7Bos4s96iLRWBsLlcta92mz1hUzddabx7WgZmPLGP6'
    'xn1PtweEUyMeq/IpiDSTbeswDSdoEL0dryFUrLgl+VTWLSpGaVW2lmNrkepCs3PHSj96v+eXdGbPr3BOwwAmEV/4ym3jFAp43wUO'
    'SYsYoPkse5OcaEU+Go7lgDqQsb/+00Q9+4jh4vb3luqTdbPJUFTfht0wqX8PgUZgq1Q1VpZQPU6qFn7bRX7cqz4v86V4FKbp1A4R'
    'op9OIe8zv5L6CdXKrQV+yLwVoHMor1vTKVCTDdyQ8VsT/CXEp2xqpd5RdBWSprgb1FiHWOlNOlBouDbhxuKgFZkc56HpLcIqajXJ'
    'vembMrAoFSlkxhIhpnnJifjXD2kWWCjeBoyAUfSjGzXIOu3HnOq7EYSw1N1PwGzC4TB75SGC1g9jkHiqu+1QcCQRaEpZYleSWY0I'
    'lA0x/lRbphH6AEkzQsLIGFgJz1GSpIo1fp1GQuWzJp06RDcF8KIokXfVYl/5b1e9T5oWnY5P3rbOHcoVuLMw547ETVHdkedAIhsX'
    'MaQrSiqWH5qKDhIq+qMGRH6iEt38vGK5WKm8Skb196vCsuKwbP1rgY1qLIXadAaYW+pFvzPvPe+lxCPc2lMWPDsq+7dpLRWJXPGy'
    'jUMFuU0tQ20qFm1TbcNmQZAhWdRUcsnCmnSBLwJgS31paAH9aDmHoJgSa77PEBNUxNOCEczrSbRDx1gLhO64hiPCEEwh4+jq4yht'
    'pArnYyxFf2bfQsYnNMa+t0jMNlqbgU6swdZnIIoik56UFs9JLtTlRTCk5GpngqYbd5e2lMqOrbt8DHXkNvx/bJD8xQ24DG+6eYlO'
    'hvIX+2cvcvjk9U5BQO7DGCTB8bsUv0tDdQLDmqaChNR7VHK+zzVeK/ksTczBnxFAKT+dfGT29ye5db/29/x1A8/y0UxCL1JbWV5t'
    'UU3Sorfdpgjq98qlzgtCqvd4JKVMGcMT+ImCPs11t8mPCHg0CKAGkR6ga/V2hRC2rfGtxImDJ86mqlxDUrOppiM1lqugmXjPpSXl'
    'lM9yl8spVeaUwaUZaRr20p8zoSuzyOdvm8YBQakiz3SfGT6TFYEXfvrCWlid5Nzwxx+zyEDxTOCfOa95v5b6w9sXaFlzcza9SBZK'
    'bllxyjfn3Wz0MFoB+dbasGswcjN3QmhZqfSjGgZGqSAFvAtIaUtcVbAqSfkTp48WRHitLj+y3gQrsPmLWMlnv3k/bAmzzPnJXthS'
    'jHD6edtazpiqnqGTfCeXyxzYVCsuv19+5u3sTk5k7jOFNm3GALTFSvDXRcx3Lm1+eVw5RrcqHZ6X5I3yuHDc9Afzhvz19xZDkJ6A'
    'ctM7xrzQoCPucbaGpyok91tp2qjifb+3RGgaK5dKCA09sHvtOqt7/t2rqDzQ8Wq6/hLuk7HtfSzyyYmpFbGq4n5v4UAnLO92V4rS'
    'cBRv3SqVwtPfB0WBjtAj93vmjS8p1XmHZRWqoU8NNDE7yn0W5dITGiBSKuLI8yN3/zMhoL8V8yfysqFIS1T9VniCRgZo1sAsrsAi'
    'm4rU4UAb4FW+lgL6oIGp6tAHDesg64MQM5FDmEAoAI7LF4OiD7K9etcHdQbZELb/uUXSVIv5McllkFUfVBkGGu+FQdokl1eLnHA1'
    'RjxyNUJU5TW+LSV6jQ4lejyvpF6vkS3p2mO+nGIwEwettLiaMq2SGuaQ4OtMr06bZcYf7XWDLVBhO57MVZIo9n+TmNRAWLAkuGoI'
    'z9VkUo1DM8WMzB0q/lR/EM8SbNDShYoZZI6ryyk2eWisqtqFmss952UgEy6MRf4hTehIPIIme2QXSQQbUY1V2IlcK0QYjoyoFf1E'
    '4tW7SA1axgTpyoOrq3NAh9V4UXq4zQD8heQ1tC4G5WcQZFZ2IQ0wPK2SiAb10jo+Qi9SdnpCL6P+Whu2mnVvIxHBqKA0VT+F5Rkw'
    'qg/A2ILQC5ZJQQ91ElhYDcVmNxZ0TmSzSaoFoCvYpSSt4gbvEvtii1y8bttPk3u3gbHBMVhie4AeKHAHVndusNibq2/Y2YNL8xkT'
    'KYvbytWU4lp9xjt3HeYy2I+0uTnQ3C5o4TPHZ2j/JNM6z3TXpfv2mW1JH1uePk2L8AhjuZrtEWZoUlwVNxa/239r2dWsF7tAmTLV'
    'i3VurX/bWVCxAfOnL7cd1vpSrk1s6OYh/CjXJs4p+in/Fg+t16x3AXb1v7OxlYpVG+3M/6Lk25Clvj/bP459enA4Pz9t6Xe8vdSf'
    '+8z8rOi8j7fxLt703mOm0VY6mZm0HA+GfkDdOWh+V3728cSVN5d6l19Vr1UnNZKvaPalwO39/sytfqRDzf1xF9AY/uZHRwoPSKCC'
    'JNI/0eatRnKtSUUSI9XOtyuqYG79t9mc+/uri5kY4ycPr1R/qLm+dPRttePXtgF0ybyB48nxwi7wFNK/DhFM1YQMvgh2NrlLBkUh'
    'O55G/ppR5yDI0WEgeXrflNJoTWYnTb4lNwwcOuo6SqDfTKRtHk4Hqmif8nLtHy3UqSbNPe5+nRg0h3elhnl/3tAZT1M1FcVnIKA8'
    'XwzZef9krBkrdmLJGXxtJd63gpCwRuBxjWpdZstDMaYFmPM4hN26fy87CdjCNIqKVwM2x9XEH7tXTvAtXid7b+5EVO3UN4vYaL/q'
    'mL9fZB1z85eN9quOrXBOVeC43D0e8HnPr3ES5dhnGDM45uFe6x8PdeGh1sPO24ae5g46W99FIyPioPlBjUJfqk7GzFf8AxZ3K61H'
    'nnFLozlUXoTTGIKCbhXbAn0TaTRHfWYJiG4Cnx769DFtlRBq2uz5iipTn4Af1NSnL3064vErXH6xwI2qDFsazSFV8y3V1JB16pZG'
    'cwjsvBWIunpjPqGOuf6F+1G4P5X7WTvH3M/K/a3nVYE2UK1Ab32jXRKghDaF+jDUbn5cjYLxhKtJjOf5Grl8b2MjnqfnbGSPFVsb'
    'MZ7nbcR4bG4ELOjnbsR4bG+0y3sehRZAPmeBmPfri8Zwe1K4/w7xq9p8LUZm51Yf+3Wf7x9R9Tu3cimtcvvKChr53qKCpk2nZbh7'
    'f6KqGsZ/TxcZkPP7CZltC/ovw32HC9gXb8s92x+46I2BE8Z5culaMhKeiVBI8X/hcdJoPqXUE6ucjQn1uGhKbfCDKnLAVWy4id5w'
    'Nfon1kaPIdQMtyS6VsvQIjFg3wqdlVAK96DzG1aTS+8FGu3LfpzPk7Xyy5kmrFXqUg25j1s+UzkyXIW5hbxCofewzC+WdxWAlYQ1'
    'Jv8tBWSfPRlTn92qChp4m4of+7ZNpFTSZTEX78zs5Sud+2DW/WJz423KkI+CZCUNqjybX9Y21dZt95+1jCk+euhvPVr4pVC22ESw'
    'a1AYmmHCoc1x2pgnk0tRr9VsU00ozODRZQwgT/iux/g9CV2CWBSQVAVC+Y19bVhZv0EupLm0pTSqzBk1xyGN+iPnt2VIST7rJXjW'
    'LRDcLLE0hh+WN1PQxsz42ormYjNW1+4KlzkrdSkC1BDlaTY+7oUt3mUn+lYYRN8yk+6hQD13y6Vom42rLfHeRd98ofibnLefxO5b'
    '3+Lp8X7d2/pb7ZB51qE0dY9fRSqCVyV9l6sSwICh0dkc2XFDKEjdhBXDFsyEHS6VdoU3GfYUwrRuBfVNKUxVgnt9cx0LSl+1PUl8'
    'lcoIvxwWAS5tmFtnKS6fHgxeEPe913wSBgXRZ5byGsrtVmRvNDHmoBTo+T0pFXJ+ar3LsC4oPQ6OXYrcn7Buqqd3j7V+qAmcx359'
    '6jh7FA1TEZ0Yqvm7eKqK7hy/8mollDzeFWQKRcNDZdzhRlZzqfd4ZRsuELvrlYtMhUudZeV8xOuyaO3UtMoKuJpmzaXnQDi2G11e'
    'Ibc3o43U6sC5ADNvBHX0bbafFG6ZijP3WcqbkWV39PlVUve0zDq+pPWHcRCPMXB8xqJHxwi0Yy20RIl1EA1zGchgK+gJ+5Qz3YLi'
    'htckecRudQ1lSOElU1PNraD5MBfVy43FwGzgI7RmAIcVmWUYT7HofAxT9H9InGMAkP3Uw+x9S05KW6Ehf6HqxKFIUqwU0GH9CCiR'
    '4sV2gM7utmti95OP5T6lh2xJCV/Kqqp/Nm8qorb7idwRb2x39mwQvd8gJcC13hAl7LTeANUyWtbsLhKXXEhjgLmdmIJl4ABQvhzj'
    'wSfS3taSxG8cAmBe9xtPK3IfsgpdsgYOAT2WwMIUJlJuRCvPFqxoyDUPvid0yy0LoltKlej3UAW3S6BgjCe0bZS6sGKL/j0wDJWn'
    'OyZ9ki9PZoa4PhZxziF1VPUlB9PVBVXhV0WiP2p1CsH3R7JlkmNJqKiUrLPXvBG1TgQpgpAiOS6ssuXf/IxtMLsRzKTnv6FOihRc'
    '78HJg6OKcn5igIrLzwx9aComCJMnpS9B8zFm6s/LKT+U+vTKD0UXZv2K0Hq0xEYIOTjpzofEKSUhfjH1+aFHH5p64aorm4JDKRmS'
    'Xqd2DBcJTZIASkLsEQBN+tPmFf6EkPg8bij0Q2FX9CMPdb07otdJsdYPU+i6is+BmBvY8YAs3bQMp3ZCyUOeR7FJKTQDAr9TfnaU'
    'GOjnZiRPhtQfRqP/F7OQlQ/NXbj0+OlgIsaGRsNzReoFLKiAUSWjPIGlOjcj1yuLh6EE0lDkuPNhiLyZw80MYOV0z5/Hq3d5yhbl'
    'o85os92fcPUr4YaXcSm/uB1bgO4rFO8UPrNRaEy1Eorpbbcq8HAdaLlcRsCSf3VQvQhSgy5vq7tP5l+s8Tx6OhATBVoLA116n1fL'
    'N3dl7+6PK+xGRe6v1duhZRUOpdgNOnDhY7oQ+Vvolr4lvtjwxLJy7ALeMAoojYPkUOICJYsooXp0aob7KQBZgBZ0UXKpCPVj/YFk'
    'Lir4WyLhAs/e6Tezg+dM6z9WKVU1HARcFFjKnUCgV+l0dSUm6hw9qBhoMDuZdESys76IImAXrk9i7+Oj7T5Mna3ILqMz2Hz5gA+n'
    'YRrOj+b5r2X1JJiMB0WNg/TSsQiSYLTD99KCCZveVz6wg6I2IAEGfcPrFG252J2jNDfD1Y7w8dRszKppKNbLWK3SPyw4hBc1Ei/+'
    'yoZKyp4ArBRx1dJ3sekRNDJi0vluVCtlX3eUHrRKJ16uFFl95Vlu9BSUrok/cdMLOVzt7GHeCWnwl3ZEks5GRQansExbQjAKpXAB'
    'zkug4DubDMBZjENIgw59yUiE8dKBTCOMH+vwmuYG2SBQcR7z/zdQilwlUHh/2UHnPr1sYVtkeik5MOM/s4XOO162wFcgWyikD8vJ'
    'glMPt8YSTVKofit3Hwa6N/tbxPxgR5QsNOO9EFdufRlxUlkze/V7YAvnmwuppdKHxsogBEzwSz641U3UWnzGKUYBDZ+InEEJmzNh'
    'lsp7T4VKdVwquVmDSJ3W8zpPvcu8cpO2clMoli4OF93KY/Y0k5LnV993Osze5sMOmIJiLNkFp1Aq0sQOiA7LCl0BZno9Myx1waUy'
    'hj/e8d5VgVBsk6fK+FRpb4kNG6SkNS20yKPTFgst/JcUcj5yKQvF+I5xGcrDWR326yjQb17PymNHZ2RhOtoh/l9tROscF8q6B3gH'
    'IPIiTG0HjnsX2zOdTCAnd57jRfUdcHrRrEFXHvO82KD1tY4No1fxzBI6wxI6DS8X6TIHS7qwKlZvM2pLwjsLtYV81qJ6I2jW3jUy'
    'PpFBhQvQnlqa3YuaJcsnRsXamkpYY235TLWiGsasf1NUw9sROCOJ3EHp+yD9bTXuu2+PglLagBs5QEkg5JVLkHkk1sYPgRq6MINN'
    '4mhNW2QR0lBqiRLACOSJJY7RJNQihEyTLNcDvq+EKk75La0sVw0t3CuL1qNZWvM8cMrU7h/KKSZIZXFIBjohMidOsSppF8ltSYC4'
    '54qkmHOoCS25cyVygKilpRl4HjaDJlN2XijcsBnpti/S/xAyjTBEm4ndHjL1jdQwkTiDNEtEbohE0ACXwYp8S8chOetHxNirYSW4'
    'jEpE2GxoUpWHl6kv7DH6kGUoUNiBQhjjydaUCUKmfLyRtvUcAOK6To9kSerJAMitgReS3QoQmBkFb6SFF1KI/1u5X0N49Jw2k2qt'
    'LZsmShRBMDpJCYa9k45SggGcc4GCsGvBAlg++ZopHiiDLikJgQBOQsvS1FiITDU4v0uUDysPvalko6CJwEvGioX3YysTL7OK/5JZ'
    'bal4SBl4Hg70grgZ88G50Na+sbvC7NN+0bZ/voKRsSJOd0AzJabDaCZs8CyymtpeG5R06HVrcT5NzjRaWKxjsaz6YnJvPI0PjEn1'
    'Sx9+MowYH+6F/fUQHUCUG5PTEwZPkgkJVl1NeD7+JXdIe8/VbnqzK17VBjlVNxUbCm7x0NrU9SOJOKSsFTG3zi44KlbebFH7MzSP'
    '1WNfNlpFgmbMD5hy0Ejs8Yx0K81e3fOGBXYAXwTyNAgcFqZ8udcewOWZ0bi92Cl2A8vvH5xRN82sF8v7WIewF+DbaGN1STFkkGX8'
    '/EYGZyLhY0kt453i+8QdEq32s4h0oXlgULY43rZwKhZnrc/+MzgTX59H0X/ttnAMY644P7bXl7IX5Oeh4zuqft0genTA+xlWp3tc'
    '6NkVPkbx9r3pk2BPbDQ52ST/ECleG1jq6wzxK4uETJYaJls1t6k+rLKm+1T8jHKQC7mNsBBSgZUJgYoc3aYQNUF1BxTBjfyxIeb5'
    'pCJHWg7Hg+PBceFYN/kIJpESCCoPhDoYW3XWeEodKcewTIpbGgZM1xVPUH3TaVQKxWXE/mFPb7L5nUVJCOld7+kawWhPGSRUJtn4'
    'EyqO2DQ2xTDl6DObFF3ow2EsyA21ywVuCAFcJJaYZWv+QpeaSKu+ZddKWn9H30hfVhewsVNQu2LKSIasojiqI33zNp5EGeZioamP'
    'ldjfv4+PBiMk6KqITNxAyeqERdfqTo0BVOQQOmrCD+M3KWOoUAcrjKAo7S2Ircf+uIG380SqZLsBEqhBMO6IhzcEkwJtxAa6IlBz'
    '7yIXvnWtgygZevITJ46ezgJNLhNngY0rxeW7A29sRyzxKK3EgckXAe1ALGoNzJYRMlxwX1BlyOIZ6+zEQPWQ88zPultxY79ZZOYp'
    'm5wqJUCaVgy5Q5s1v1WG09aGHvUyhahAKl4wD9SnK/XhF7UJlkEDEiHM24FTicENuNpgY5xf2r2BtglsYuqlhVdueST3MUuvZHuT'
    '9q3ajV3hZCIZshLTsdJppvSood7Vw63dhLwsFwwPxS2qrFFko3gWU/QKZ4YLCG7w5//SGUM+wmSY8N+xhnxWLWRoDA87f9GZ8Jnw'
    'GX96OwaTDJ/xp7f6Id4MeCOUOKbPNJ/xpxd/evGnF4/wKcGcV4g4PhOf0sRoLmgY/TvQHtWZ7U7itn7MZoQZGD29dc8CzhhjM81T'
    'n8tnus94hCZQ/oT7Hit7eITDIxweYXiE8SAaHmF4hN0j7B5h9wgfCqgtM8A9wtb/w6dr/2RIOeMRVo+w+FsUX+fiERaPsPhbFL7F'
    'YYCH8R2+wuEbbAa3IXFlHIOSeGeL7Q08PVtwB18fbNEB7j7YwuGdvL/XlVJL8Ajkex9/T9IY3lNj9VXwTfFd8sPnp9HTxfOH4/Mj'
    '+xUcboacKnXMVfbk8mwLbp7noyeoZ6yn8GC4nuSe9V4G3B23YcBkPNaCXIxnMd7FeBbj2Yxnt9/d8d16d+kfV9vjHdwNd58GrxOh'
    'ZGq6wSkE7NIE5xNALV4n9smfG27phs2xnSIO8iyacOMpEf5rqhiyz+yKQJpSQ454raohmNUNxS9NSiAhlp3CNtPc43f7Ok24Rlo4'
    'xeyu/PlkNaS/Ol9jQwbJskhZ5s5+yRujfzUuukUqFhW9kEHgw3DCt8sdtimCUOkO8lewkw81iCoBc+YHiFsN/BBa++zsExznwZ/m'
    'GKZX6SoY9HeAuleq/fT2xnHZvBlPSC83zyi3OKYFLRe3D78Y16EzxWeGeZ7DZ4rP0FjUFllJxJpbUjoD6kn7dD0f5mczg7T50+t7'
    'jz9dibS7mfNtW8fJGrFKnil8+vGXeFBKvsOBfXkY3eGDzQ7dvL6NjOf/bz5h8QHZO2lSkstjrsjkEqlHg9XNbARN5wcB4/OCL7UY'
    'Tzc7FLyVUFGwR6s5/4gMV8E5bhC06E1094KOEswOHDCPC+xRQ8tKh2FQ/hi3lKFTncSJxkJWjissPeLlLfnk+3emBfCn4smJpZZV'
    '4udXS3yjGvHoJuvNFgmS4m57SeZ0Fofjc/Z4KcxthEzRdOpiz1a0EhIhTtyghHc8vs/E0Wz8rZdg16mpKkoUxrnfeAMfPIvgdjdR'
    'WVGGFaro7g+3puPz9zuirvYN7sh5ATUULwyhMZDsUtNRpz3BAl/BpCHo713mB+MSuKs+waGGAKx1PhsliYkVQKPxNJudEXSffN/8'
    '/f95XURNq+Qd9Ixjoy3v1VJl5ft8bEvcY5y9yZPy/CbPCXlKVuv1I5KZx7h0Hb9uo1K3tSzJ9fPIKfj1/eSC1ICyS822kaB5jvLs'
    'KSDLerHQb7Nb0Wt1WSmgu7VVDfwVLtpGBzcWUeZnWfXuqGfaJbWXj8VOs3fSLF/lwoS0d6sbumk03f5pbho9B/Vni+3nG0qjJaO7'
    'tQzr+NIVkbOtDwrXhx1BitHvUDykd1jxxpX9oyWWu6PTjYfz8yjViaIrl36sGCR2itJ5jHDKRlFyUpI1RrCHIS4s7+pwI54qNEsI'
    'xDIlv7YbNZWg0iSpasmgNIkfyUiwizMjegw+ekvKgBn6BeyALOWHrKCrzNGGCuNZ1IIjDdoIjrRmJxxpRtZF2J+S3mtaIIcAbE3T'
    'doCA0GQbYn9dIoX6GDCBJxTFpQ6QukMDd+fyYGwSALwbSbO7cwi5oL5piEWtjQ2DQXVoYdtVc5WyjbbVuEk6+lGz69zzJ37+GBha'
    'Ox+ivQMS6MOHrgKipdXOUBuFLrJBUtTQX77yw8d0HDDv3xhWf0dbJ3s9+FY39dfUJ6Wtncm7NKol6oL6ZLY/N3RorA6IZzOg7tCC'
    'J2KkFoCaBMzBHJsE2MEMS8vjiSAsvaDF51hkZtvWQM+ejKDQ17gJxO7Qpbd6QOm8Wp4xtY6ZVnv9ptVWG1S2mYvjzfv/U090ih5G'
    'EiPt4zyY5C3vGb+ATknZiN+iDU7xiIDnIm6wepqZHYZroIRDbydoFY/zY4rbO2sdd5uRglYjuj/TaoMnEohcLXddLP42tIEdjNM2'
    'qOqF2ONA7X5i6GPwt5RWKhCXsKIptG9pPBV+Eee2cGYsA+GXG0kwHwfx3FhQCKAWdBV/bxtJamTjJ87fgGpQfnB2EVgm2O10QiZf'
    'qORu+l/neeXtL1LA5TSZK0wjDqDxVbTfpDJMHrCAHk4UzgbTL0BQSws6qY6SWltqBk9BWIekkGmhh9r9Ta7Jerq0IPOkVT3nqB3X'
    'z0v5NqWm8/+emqruLK7j7zHOZv55T/l4EhWh3K0haCZRCtGZFJ/EE3dKkwF2VN9/BJI7vrxBh3bCo1/Yv53x0R2Q+rldHPIJcpwX'
    '5ll126bbHQglzvVqvdI1xDcn7EzoAqlkCKyJn3Ftxcz2kOu5QLTInSc6xwPq3zAysT9FuiN9ti1yq1WbBEQHGRHyseyqTHVqWoEw'
    '/ADUOVFDdCFdgeJ6X+ZvX25RQIfRmgXxbY7QE0tyiVVwMldEcZp5k/F+Jnyd2X6iY+kAfRTUtfUVw0dXuckoRqpqqMkegTbmdj9k'
    'SDlgIVGIG6nSXy52AJWe+GSn8XP5lgK7WRPGeN/XD2WEDP0G3rthSqsXBBoZCyb+s8/cFqpMowTHrq272nn+SdZYGCtJgCSl2yue'
    'h6wNK35b2QQh3fmuo/wDtkGtXgUfdSlEgwrxFxryccOQ/1wvcsou3ZeTOnZ2blc8S6oyKNAQbi9rDMBZzRRj/2CfUJIaKGZAStlu'
    'hTZ/AGIKSjIV8qhnCyMsywjDdRHI2824+mRZhpQKoH8KU/ODb3d01/r+0S8XoANaIlvPaTdp6boqVMOtKTeozNB/cARtXw+66H3N'
    'k8HoWFT3sxMkUHfhSTkbtLe9de+FB9Odc/EUpKXKS9oGuhYuodkmWohAkAan/GjUCKZrTpfHJNzs4gp8CwZkTSW2hSnEoCjgpP4G'
    'yiS1C4eWRrI8WUsaa8lERla68TQNXaKD55cZINNhTMu6kLw7uefvjGpcOk8iglDVKlK4kyLsGpiUzY+KVE0c+Z1ywePd9aZwA1RQ'
    'u7Cbqc4G3Ca3WqWqLonvPEhJzAOI5GVFXeVfwUuUIglsFIDZn5YHWRGKUgkAmihKpToUK5B1JWX+jXs3/fGpZi8wtKlYpqvlmV6a'
    'ksOWR0LTFjrw3VRYfu8Pt7fB25blByrYQwFFJbE5uoaPmiPQg+IRecZpSoVWSzG/QjwqWDsU1gSAy65veXpRF9u2pZ5512yReZLE'
    '3Z5eVILhBs2HBMNR0r7J8ScjunpdJqlbEbZYegmSjxMiSYS/hAgh9vEDwyEHFbilVWPZbF0/PvnRxvrN+RFYucyPJqhm5AoHDYaG'
    'CfQAW2YMt+WiOmnak4uigj8J7q1yNdFDtPzmQmVpYP+c+RF5F2oByo+w/Vr4oC4weQv+f4IKjrtr1cGtnaUbdXtoEHhfT5GxMjPA'
    'bWiymoTFJY4mZsdTYmBzHaB6B1AEmUeDq2qGANC6B+v5Wvedkt7CgL7HT5mH3uN06a2qVLicucCFtDrTIjpRZoP8fVS+1+f7/fO8'
    'daldsjsc8/qhRPtw48eCVcWkj2Itq9pdYHNPtbrr+yvCmc9aHE61bZ+06qrV37BzfX8cHirKfJClXsnNMMJfya1z++ezg3hObtXe'
    '08XBznKBbZlE67g5zUuGXci56diQPMp/AfQclg+tiKGpXmjBgDW/uVa1/lZbLqcdF+EMBb/tq+0aXjfNabMNcKbaAXhpyp/tkhtJ'
    '250TG2vgPG4c8/rdBTY1sgBKl8eVWgJlvkXMk7UH5h7CGZnlLLTB7o3K14cytOUMLeK/GtkKi90UHvTpI7+2nwvsFPNyQ9UFXpJS'
    '6WFCQ3yfH/OzxfOweIYofQ73xvkxlQ6NtE0rbqG/NagFBK03VQCkS21droYSV4EOpHi04XaXH1yagSyuF3Q0OasFleiUgdPJeK2j'
    'nKDw9TG8oT14+PeRnJAUDt5aw8RnuWuEsO5Lgo042mYwDNaTAEu7r/BbEJkFDQRpXjf2DIbhS/1K9CZJdjetXr2pAlpFlRWKq09X'
    'Bki62Yrtjqm6ZlNhb/14dEM6alMXGBvaq4Ul2P+W83YXUnjLD7PrkdyqooUMYOzfpV78KU+SGFChnK7uj/tYnYdYO+jjK5wo6PeT'
    'NZZ4+v6jG9iBA6Z8k1wdlfcV8BDb1nrqFwRGZ/2CTDpd4v76FYYBTyf7dO6MEc3H4VV8WMRWcS5JXuu4WVyRoYT4pyLwcZXB6wPD'
    'tWkSyGqQcEzVXwvtI9NcX8XtqQhKiVfMJGBEe1lDEAx1bkVPsPtI/SSncze4uRtEjOZH5myFEmBCY8nuxBiri14x1ta5AKiDXn8z'
    '01M1w6H4Ce7QfC0iuRXUSdBa0xEcvcP07TpUOraZFAp977E0uPsfT3epX6utmpTCqmM11+VbkseDz2YoUT5KKVMZVR4znODzBoMd'
    'jGcwngGFcTLeyXgm45mMZzHexedZeG4xns14F9/fBOTtq8N4N+M5jOfweed81Ebq/vXzKZ0YsjaZI3nmwQJq8RmDEirjkrLObBbD'
    'xlVEoITwvTIEoZkc2A2A6F6O3a/XA1gt1ZMgifp9TzNsoi3/8gSV9n96smrBzQgk8HTyEa8RuqsxLoqyYARDlQvWt4NIxltnHkR9'
    'hDVAwork8RmskQUa7Fg2KFhGUS6hzYd6SL/i9UaXEjWH/YfJA1OzWXYK7cD5Nw3Bxxnvuvd3StPI3XAaFzagkzVxEBaN8iw5p4AR'
    'QyIWdyOlL3R0ISXZx5FeU1yyn/bav5tyLWuyg+NfH58vjt/rf51vCCU1lFp6+9gLDbaMWV/IL35Aw+WgoOG9QYPMV/DZMI/PNBN3'
    'fgC2yRutYdoHOKVNsWS52LE+iAF/9qy4saPh3TsPWMXjCj7JD+foz6yoqx2m0l4/RlPr6ESrPXBkX7UlNbzEe58iZKRqqNYv9CyX'
    'wORHO/PdUGN99s9W30g9crFFxKV75ZeatX6pof31ybST+08/5LHyaaSO1JXLCSUWgbYDM1xNjvXOAiaynx8HZZKcTjwcJpH4cKwf'
    'Tif6MRWzW+nXSIDoX55SwmULD9uTtYq39lRrQZgNnRvJcL1vAJI2gIl68T0e8ZnDl1DYVAvXdNXFzM9YH/W4wg7TcR0LzVb5BXQg'
    'Zr/Vs1sJ6fkRTvQXGwW0o1hFKteK/W4whLpCm0/eBt/p1k39fNjQBuYzQKAG5JMH/mvvATYPuWlBUU0b8ywwY3p+XgPFpWXl+jza'
    '6TsGya4NEJ6HNknRzww2jEANNz/dLUlFFLzhszxQTCTJR7NZLU+ldDz65rOpzYQP88ZhZw0Hd03TdpHnHoBPZ9kvz7X9n1sk5VWt'
    'IWcbExgfCrwYSEOpUftKjNTP8zC9vA9FKDGINJqeozqoDQNo2lTrFzXcgbHvXfXdD7JBMVvYYvibAHTx/aQi0h5RQ8cA1/okYC2v'
    'prtNqGifqsq0S0BlHCzdEU9a9J/n1V2AkBs4ui3ouqNizxuCeQ506dfPmW5w8Vv7bA1bCVMu15YKWwC8vi7i11EL9/BKdB1G4kMM'
    'keZA6Pg0nO2kGZnFfd9zpHgl8VIlzVhwgSmNCDbQ4luYD5HdFoEBmqUVnw1FIbKsinA7NhN1o094noSMQuz+9AvVN1kvEu0wMSfA'
    'TMFiB2Iazsk32nqqP6d4Bip14yuFgwtBI7pIgKT1FC2pjFiGxDQssUyEi+r1T0xj4J5jpsvEzMliGkQ3E8BpUjhQ7ziP0+HYN4w0'
    'CAx67KBSgfMecz1ysR7TGQyltGZJB63CzepAhikIU+ohJBuy2ByoOjfqsG+KCZyBuCKQXWvxtfVlkdR/8H4oKM+vLEbYmqiaaTI+'
    'YhpimgyLadhLcNi6qRZzT0AscqZZTKObqGSux7K8Qs4a40EeP+Xh9CSmgfaAmCbTK+Rjmoy/yZ8iIJRp7rOSytLnsi+AeYvKjZcb'
    '8tspOHg/GTXiix60irqqGhU5z4qGzVaYOxT0hticxvzKL7BZVxFrhw7haRBhTDbKU1xCfHDC7jIspDKDwQKHwuZqgE3Z462l63zM'
    'ESf9vAa40zLKLtPNSYiJ8sst057HsuEWHJdbK0X2M78u0na+tMPwvSPHYWobFj6yBJe2vvJ/u/wOhiH3dv66Lj+iElIGmghOaMns'
    'IIXYmL7xiS//+skRLH4ehNByQ2/1R964CzSMTB37dQQmNz2cTc9lo1K5sMxevJ6SkACpWkV/AEuOBpV6YtmRGn9Uv1OA5KBvUPTc'
    'VNQsxkaHd6KPMEWtrgMMHW61qbdA2NqhWt+VKagPIpGlUIlZGwiDGtsfdtr+GK318nO4D3QVeHvnazHn3EzjCethxbzXkstO21Gv'
    '8RyDGfMJlYPUDRevIMjWl7xYJRkeZJFImff9/creJqjS6hmAntIJZopcnlvdc8dLF5gpnepsliolovcqnQ+UPepz0ZTUxVCuK5ty'
    'aYdUkPnSFbErlNIrhKJRIJFvIGLqQ4FBF5F/CtoSSq1GWryFQsuZcIuhytJMi2hQXNdQXNagXc+XdCNpFkgZrWUDWYqY1FsF/MK+'
    'HvtkiVrWLGKExDebmMQh/jMeSSrHDhQIpDmzPu5Kf63A0IYlCEH00zrBNvD8Bh3g1mgprw4sYRpC84quVcSo9KrvI6UFBH/wCtYk'
    'dAsr0cp98CfNIaFyGrRj249Qm20dH+Gl5f+accWnEGt436TH16BbEH0n3RlO5AaRoGgWeH0HDniDjYooO463T6R9kB3k5tVdPXCX'
    'tPM/5/rB4g+VYBhUhzTq/Lx4cyW2komwR28j9AL8n2uzi+Og6tDzSpWj/v6O27vhnltuWbVZlNa5WzlfoYZBRjjaV8XpaXWlLMMT'
    '0luudkBM161FPum4S1hhFaTyLy4TFSjYb2mfuHvpc35nGhK+hTbZeUDG8a9WAP1D3lgT0sbn2K9DApcIq56uWyZY0JAPwnQiXb2a'
    'X7P4WZmWtLe2/YAxpsZrteriVGexCkp/hI7fwkirqYCXuwrN6JN1RRQDpZ8hOZWN+eajXhTTbovdie6+P7cJNs3eSIeGflhhfdk5'
    'Op6d+P7WeCsSM81mXYJMwfFWdC1kYarxYz2oislA/g9Qik1SilA+KZLZlLGFgHcBDA2KRtCNaawk00SimtdyAy3cSDUUeFE5zPPa'
    '1sQPYl0Yo9fsZ1VMv5A+ZvvIMHeD/iSA4l5LOOx9vlh+KqTatd2Fn5oMbbizXQlWGh33hgBqtVtCk5AFfXtUubdFcBpd/z3trc2E'
    '3xazc7FhG7uIOz1AhMf4+Zzmyx6JlBxHqbxKKQdr7Fzomu7yZiEEWbcpVLXx+s0EuLBUFuMbou0ubyo1v7HWcu1Bpz81uxBEZRIL'
    'Z61z08YTny/Nv1mHG0ItxnerQgYfrkuz8t7hQdmiopwtGH6noVthn+Kd3GhWhtL+HBVlFdbKoFrBp+Q2OmQjbK/EceTxep4Lo/Ey'
    'AxkcJGisWo6lCv7ERZtFxMdhIDjEYQBbKDsMgBm2w4BfTYW2NAuaz9ogvYSWFkGSy6DhsTCwRG/xfKtSW1UPoqhMQG3y6Tbj/njj'
    'UqhscHnu3JcrmQVyj9aIqA9TqWR8IGnanqXzdHUFCQpLjqqqEeQW64+JBfN8+3nYlVdIwo+OihPBrXqAdZgIdm6qInIYmAh20Lcj'
    'U0vjJyt+UjsQXXY/NsSJrz1rUOVYrKHxMxj4WLyiUvqT8qzD7lrPKpY24U/VIstF8wvvFlNqf2xpO3DdX9dPl7O7ZuGe7zCEtqL8'
    'pM2w2hS32wfFtcsBUFzDsHRiKow01z6mdZmzkmXpxKyPdFc6HjxXYI5qs9/nMLxtCEyZRk0m3LMU/xxAQ838umqCTzPBLisdu7pt'
    'UKgg2lytPuMOszCrnT2EGtp+z4JSJE1qVDLrtvyoWDbGGk3HYxOwkSStsVTSZ40wxRGWjPiHLGpvryjSWj7KXrJxJFngq/ifuVJ2'
    '/RSDshBUuKGsXUSfzOQHvdcmbhkYzdPDk7f/WFigCLQyRWDJDaqjCmUVu2M/UjMiVv1wYdS6G+Opry/SqwRaap7NeDjLjVpZ07s2'
    '7LBknWmLygpTy9QrkSrlccpSMo7HZSm222TRSw4KdztO0A/x9mP0GChVMHOwalyGxLG+Rkhbt+s0K6C1nwbJT4V0WM1uwRq134Gq'
    'M812FNmW6V+Cq73KFeMZLtdMpp3WT+nVZt3+g4pfyodE0+1mIfzdY08s4+9MXh3Qy/K/i+HdobyGu3TDlNfhgOg+1e9hXv5fy1q6'
    'y9Iz+l/1P3r923KujPIBeCC+8DKnJXhVCQywBFbZ/Ihmff3wFFJtGLmby78slmVTYwzOPSfFb5nPqke2O+wylnmv47EKFgXfrDA2'
    'qy00wyveqlzB42Qt1+B+FBiHSZnVmFz7rnbjE9qyHi45ZD3vK32/4gYetyVVDZR1hpFkUz24fG4VqwGR0DZFCSo+DesupHsONavO'
    'zjOFxS08QGGU5nxWqA2KTHrC2F19Gv8xiqlIg+2nGWShqn95whTagQXjSql+jHNsjiOoIMghhAZSUOvj/SVm0t3W6akpeiNM40iv'
    'Ke/8f8k77039l7xzfwh0WmUeme5v58ufX4Hp4vp6Lq7a6zDJzshHFieqTjjHcfvRgl9o/3ZS+rsdZ6GLfTWYe3dx0OP4p6ly8Kcp'
    'aPjTqrAgrakgmefvrTsGpy8Jm05kCRc1pGqh6PzLORkPTDAtKdNr1Kpm6k3aD5k2bZPsuivrmypHJcwHMU0B5oIYNyYItMonQOr8'
    '60d6DHfHV/IZBHBvCjY3PcZT6vZf9Cdoqc+id9C7aNUTEfUILZRmer7oIft7fX/1XXoxTcoPc1jqfxAGjoPCfEOJnrB2KCW6YW/f'
    'H6jsde8FjNSQnGvA/hqhvT2KBbkXvf7hCC50nnLaQk7hFCOhnLci/dzgD2SNG7TEkIxMSHylK5i+Nb72uCRD6NkpCtpSeZaF8yDm'
    'UeuvqsewBje7U0trZmFarBuxQ80nNLOFGYc81VBO6aIUZikRQ+pevpKekI3KsMenjIZC4NhUopY8wFUoOqJqS6og4QhySIQceH6+'
    'Mx14cIOfbsGsIHAZAztvOatWNAFa0ULbiizcm1kraYxz69IdXtBSnXph+20+SFgBraJvZhGMLCvVRyvQt0gx+P7JM4eFasTLTLzB'
    'wRyCDMu2X15f1xd6NTtChdvPttjszcvTT56vWIX/GGmyUT7KOqvduArBxRnWnwoj8rx9NDdRCy3yzdAGxo0P3Ike3yAwFxU00LX3'
    'MJopF4X4/BXGkmwwLASLwE41lh4F+XszsQHBuRDo//06rVi4b6Oxr/gunQQh5WkTvSzaEl8Dsit9VWxbMDBcbcUS+cMuY+dv6+v9'
    '5SBUDN2/McJwezfHbNKKebFayzviahl1bLOiZQJ+vzvldarIN4h7hGnHkrk5VMjxGatsa/rJ/gwZB9Weq/mzZm6ooYNo2bFcecI8'
    'JfKqQLRahc1pX1k/2etJmjQa4YrTB0jzOZuwelrMzmD1WyS44VYZCDNzdSaRWl8//d60ywJGmnr2VbO3AHrqqGYkK37YmUg7zrBS'
    'AsSH8SDiP71gNQzEjTMsXelcUCeUcJcl+xD9JXTQYhDa+UQpDlrJ4urlJFYaGUkqrWrbZSO7Ziyi/E1WK5EgJlp4AopUO5Ems18r'
    'popGYgvert1InX2tl0mx0f6BpKx2cjftpBYXQHy1cbhpJ1ZlPsMyA2i/ph0u6zTtNIKZUVdICmssrHTTeqBjuRYylFP4FGJG6FaG'
    'PN+qenrDKsTsGCtN0hcCfs8+IeyYsNV9y6Zo9uyUQ2ozRMtw/jCcF+FPEkNWyvY86Kh0TY2ndunaZXy0gG8xDsKFUiN2/yInuMeR'
    'qBXtX0F77gzrQMomvNturQyadjbmylTODNwgdcA4t4K2/jXpxjMUHMiQxv6kVbdtif6qdEIo9gXOyzcGBEop9E0fn3Sq2T2rAedS'
    'o2uV3wZSUNzafgEa/CL++483PIGs7eW80Ffb9neq7aMesuwLOezp4nr/CDY2oyzHhkXohp5RlduJ+sRKxhWLHLFLVn3bMaZ+K1WL'
    'MFeq/c8xJxyhGgiUO87x6n1cfSyAlyRmO+ynhrWZQFDF/kG1+Mz2GVeLqr0kvJTJPKAavmXT0n4cF1gWOau83YArFy3uI3DWN2+O'
    'YQ/V6egaxcLWDMe3E6tZDmOCIOsmQujZkB3b/KodhlGb8UOlgXrb9Li2678DVFvnGJCanKlBsLqjOHGmvai6+UHVddklNvhDDdnu'
    'Hyrv4Gxtx1v1xV+9uw1QfvXxTRIFeFGB1K91HRv1cSDdfZMmIVfYQaVW4XjutZOjE4YrDfnFsrEEW9TzNyhojPOKfDB/lmKgHLEc'
    'y0SFtCkjpQMk/crq0aNo9AYl093o3EpG8j7wzTLeJDyNSSx5PaDuU6z0O6k0p+g1/XVT7PG06KME5q8yoB9g3ZEnX4Iu3amwUUxQ'
    '/GQ8AOhRezlNlt6+UB+pyDDGW40mhkkHF6MJBxpLOfTH29PkO2+xhQ1MU820npQOPHbb/uK3azPxF1xZsQlTJzsoJnv3SqG4O3/Y'
    'j8T3FGHvInQs9tcgzxykuDJ3L+CwXgRXy08yR2kcaBYpOVRanbgaqRAgLRzFsu7QLoj2arUuJISPB1iUCk2Q55YWS1hY/PRWUnGL'
    '4c1qmxeN7u4Ta/4Gl7oqB00nPFZ2/w3tRh97/kaWApTnN7BbjTmdcQkNlVH5BH6WmhmyjM1x3UZmkimayrQ31S/jp/PVtqozg9Tw'
    'WlBW4Elaev60Kq8JReR/zTSEYRTF3zop+gjCEKrqk+OcSj0bMLWTSsN38UkmqpRTVDyK3+kUNeOvtPM5ztdVNfsfVM3+mrf/xmkG'
    'XZk/2t+OOCf8JTDMqR934h2FBvf52IRADzfEzwYslMlDlqy/S8e4oyI+4FS8Pyk7IHWnm2gvQlilPwLP9NJhGJEl96YsRMiEwmIH'
    'eYAIGSJ0LuzTmDBgA+NMqvRUYixz2eSk2VFQ6fqQDiynS7ExGEGX7U98BBf2TwotNAwrsQ590GAYQ8OYDGMqpVIxRRyzHVwcAV53'
    'vD7/0jA2w1gaxmaQm2vBq1vD2OrHbM3WrabKzj+kp+h/8hRF/y/aZZHSK13/lt/v8TljyBp0+ZY/sLmNI1eP4D9x0JTE+b/l/wq5'
    'kcGSou4llcumXK087cmRGL4QbC8yOQjB9iLb+V0u1T1xfx3v6JSh6cVG0tnmFQVpik6rgyY8gLYroQGQvJFJitCBKmChtE05Czko'
    '6tr/j6/tv8KpVATBFKfQainnHft12lsB1g4l30BrkDqweijzoQ9oJofiDRnt5ny6EVtROTQA+FNZCihZmE/pMC9Fw4Y2zS3UnNZh'
    'YiFuwBP2t5BklA5THuguWWHhKKIqOA8UmsLumAiO2/9SIVPQYKigm4J6MHSRIEFR6K0O0vnjzMfkE0VBYf9L4BxB9/kL9shhZPYE'
    'wYXi1gN3YVZFgAI//UH2ycCcHH0QKUPDsCpQaJABqiQ0DBiJWcbH8MVIJ6qsGCnBy9d6rGHAcc3g4cPJqvogqDMZyKBbZo1dnjbD'
    'r4QQ1GF+0NHnnGVo7FD2nEtJjKfhpE+4F1ZV6S6xT/Q8JPD3H93I7IdpyVaC7QX8j17RKeE1tbgIs9Sk6Bdi/94wTY7n+Ur+V6ER'
    '3QXiXeOhmlm4iHkLsOds62th/9Pe+SrdK57cRAVXnup0km961O5yJuFGFazkChFSowTmrAKP5JkwufjYPOefHtk/y0pU/hBvIis7'
    '/6qUurM4412++0gvcS4gK1MYjK98+XAnVv70d8J0cElPFhQdUdE7s+fW1NFLA2JK2fq/uJtSJAV1R4SsMemRefWZk9278/nd77mr'
    '6P/+3/8HU6ihug==';
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
    'NBzRfoY+dKgZo+GIKjT1oVPfRsMRvWjpQ0U8IjinTaMPFVlpL4ftbt9Om/vF/WvvLnaA9bj75XWVaWmwVBSrTO94d2nKZ5dmPl0a'
    '5zMfXZrxdGnAJgnSuq/li/KlAqR1A2ntanWPejnDhdZrpx5eWVA7uuIVK9eOLlOFYTBoWzdWmcEWrJy8ki9mIK1PPmn5+5lfK9sr'
    'Hx30LSYKWWO/uzSWux9frk5MuiNrvOXuERoZmXwaKCv5dsjfjychf+z9Ksozj79fxUU6pbfcfftF7t55fXZYU2554Mrd30aOuxq1'
    '/Sw81PWzONHqzwJGWz+LHL0Y49qsIT+NcZ32n8hgXJvJ08NiQI8AvmVaWzeUtLptcwXw8VMQLiRCVZtLXAH85f7WI4B/q5lXAH+/'
    'bQbrLVNtO/7dUlZ7C+DfBb6+fYRrfwTwcfNLjwA+pbXxFsAHH/kSwHePZyw3cpqF5dx8Tf0tPpdsGJLQzwoBzqoS8yTH6uD2I0zC'
    '/DVL2CVXVW/CPuyskk15LwubZQlU3Kz7wvOL7H0HuHdlHt1xZ9xxvaLEo7qpAAzynGjDJq4tAjXZuw6lnHE1ophbQ51FSIeTf48n'
    '/z7raNxvJ/8+hQq7zO6Tf5NzH9dScu5jz6fbqRb8aqPfGUfhZZtJROVze+6uqh27qwJXFW9C1D+XUwm4k+wThekGOfta+PdZMscJ'
    'eFgtpScBhzRBAt4y1r/haBtdy5AVdgJOZO0EvCfAxCTgURyp1yIt3iZYi07AB5VmJGacUN8EnMT4OiFndbrMsBuFhBoNn0GB5yxq'
    'NrucWK0EqBkw8obmEcfwmwYV5gAp5ye2WxSl3UGLxLoJz3FBy3IUf/Qb+wvEDAb8E8TM7aGeGffv7am5tj6Vov+vfwAal9IFmzgP'
    'v+CTn8/T2JUFNqJQHfLG6DcAXJZFSc7Py3XoMcK/d2Pgpn3MXRRfzVQ0a1UulS9k9c4T1UKGKqsoH4L+ik7v+SHk83J+t6GHBug+'
    'XW+Ijeb7hke71Q2Nx6fJd1mXy02+zmIey/J2Sb78PuV2ky9r317YAU/rwhBHRKGeuuwLMqeKSdB11ckV2bpK9VRYqsiKpTtV2Vk1'
    'CuPb0m08xzpuQxOLHwZrcuoSNOtg8fosHWLJOX5x08U6p9LBCZ+gjmvCF83vml5ZWWF5rYu+JOWHE1PQ9Nrb3TtnYVdQpI23mUtz'
    '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';
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
