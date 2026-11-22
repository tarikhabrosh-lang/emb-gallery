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

  Uint8List finish() => Uint8List.sublistView(_buf, 0, length);
}

/// حزمة متجهية نقية (Pure Dart TypedData) تُجهّز في الخيط الخلفي وتُسلَّم جاهزة للرسم السريع
class VectorDesignData {
  final Float32List stX;
  final Float32List stY;
  final Uint8List stMove; // 1 = moveTo (بعد قفزة أو تغيير لون), 0 = lineTo
  final Uint8List stColor;

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
  final double strokeW = maxCanvas >= 1800.0 ? 0.95 : 0.88;
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
      final double threadW = (strokeW * 3.6).clamp(2.4, 5.6);
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
      } else if (code == 16) {
        b = 2;
      } else if (code == 32) {
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
        for (int i = 0; i < nRec; i++) {
          final int off = i * 12;
          final int rawX = bd.getInt32(off, Endian.little);
          final int rawY = bd.getInt32(off + 4, Endian.little);
          final int fl = bd.getUint32(off + 8, Endian.little);
          final int low = fl & 0xFF;

          final bool isBead = ((fl & 0x01000000) != 0) && (low == 0x45 || low == 0x46 || low == 0x47);
          final bool isSequin = !isBead && (low == 0x06 || low == 0x07);
          final bool isNormalStitch = low == 0x00;

          if (isNormalStitch || isSequin || isBead) {
            final double px = rawX / 10.0;
            final double py = -rawY / 10.0;

            stX.add(px);
            stY.add(py);
            stMove.add(needMove ? 1 : 0);
            stColor.add(currentColorIdx);
            if (needMove) {
              jumpCount++;
              needMove = false;
            }
            stitchCount++;

            if (isSequin) {
              sequinCount++;
              seqX.add(px);
              seqY.add(py);
              seqCode.add(low == 0x07 ? 2 : 1);
            } else if (isBead) {
              beadCount++;
              beadX.add(px);
              beadY.add(py);
              beadCode.add(low == 0x45 ? 1 : (low == 0x46 ? 2 : 3));
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

  /// فحص ذكي لمحتوى الملف عند فتحه من واتساب بلاحقة مختلفة أو .bin
  static Future<EmbDesignInfo?> parseByContentFallback(String filePath, {double maxCanvas = 640.0}) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length < 16) return null;

      // 1) Wilcom OLE2 (.EMB)
      if (bytes[0] == 0xD0 && bytes[1] == 0xCF && bytes[2] == 0x11 && bytes[3] == 0xE0) {
        return await EmbParser.parseFile(filePath);
      }
      // 2) Tajima (.DST)
      if (bytes.length >= 512 && bytes[0] == 0x4C && bytes[1] == 0x41 && bytes[2] == 0x3A) {
        return await DstParser.parseFile(filePath, maxCanvas: maxCanvas);
      }
      // 3) Brother (.PES / .PEC)
      if (bytes[0] == 0x23 && bytes[1] == 0x50 && bytes[2] == 0x45 && bytes[3] == 0x53) {
        final vec = await Isolate.run(() => _decodePesSync(bytes));
        if (vec != null && vec.stX.length > 2) return await _vecToInfo(filePath, vec, maxCanvas);
      }
      if (bytes[0] == 0x23 && bytes[1] == 0x50 && bytes[2] == 0x45 && bytes[3] == 0x43) {
        final vec = await Isolate.run(() => _decodePecSync(bytes, 8, 'Brother (PEC)'));
        if (vec != null && vec.stX.length > 2) return await _vecToInfo(filePath, vec, maxCanvas);
      }
      // 4) Try Singer (.XXX), Melco (.EXP), Janome (.JEF), Barudan (.DSB), Tajima (.TBF)
      final VectorDesignData? vec = await Isolate.run(() {
        final lower = filePath.toLowerCase();
        if (lower.endsWith('.xxx')) return _decodeXxxSync(bytes);
        if (lower.endsWith('.exp')) return _decodeExpSync(bytes);
        if (lower.endsWith('.jef')) return _decodeJefSync(bytes);
        if (lower.endsWith('.dsb')) return _decodeDsbSync(bytes);
        if (lower.endsWith('.tbf')) return _decodeTbfSync(bytes);
        // تجربة تلقائية للصيغ القياسية
        final vExp = _decodeExpSync(bytes);
        if (vExp != null && vExp.stitches > 10) return vExp;
        final vXxx = _decodeXxxSync(bytes);
        if (vXxx != null && vXxx.stitches > 10) return vXxx;
        final vJef = _decodeJefSync(bytes);
        if (vJef != null && vJef.stitches > 10) return vJef;
        final vDsb = _decodeDsbSync(bytes);
        if (vDsb != null && vDsb.stitches > 10) return vDsb;
        return null;
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
        if (i + 1 < bytes.length) {
          x += _s8(bytes[i]);
          y += _s8(bytes[i + 1]);
          i += 2;
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
    final int n = stX.length;

    int curX = 0;
    int curY = 0;
    int minX = 0, maxX = 0, minY = 0, maxY = 0;
    int totalRecords = 0;
    int colorChanges = 0;
    int activeColor = stColor[0];

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

      if (i > 0 && c != activeColor) {
        emitDelta(0, 0, false, true);
        colorChanges++;
        activeColor = c;
      }

      final int dx = tx - curX;
      final int dy = ty - curY;
      final bool isJump = (stMove[i] != 0) && (dx.abs() > 0 || dy.abs() > 0);
      if (isJump) {
        emitDelta(dx, dy, true, false);
        emitDelta(0, 0, false, false);
      } else {
        emitDelta(dx, dy, false, false);
      }
    }

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
        'AX:+    0\r'
        'AY:+    0\r'
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
        if (lower.endsWith('.dhp')) {
          return DahaoParser._decodeDhpSync(filePath);
        } else if (lower.endsWith('.dhe') || lower.endsWith('.dha')) {
          return DahaoParser._decodeDheDhaSync(filePath, lower.endsWith('.dhe'));
        } else if (lower.endsWith('.dst')) {
          return DstParser._decodeDstSync(filePath)?.$1;
        } else if (UniversalFormatParser.isSupported(lower)) {
          return UniversalFormatParser._decodeAnySync(filePath);
        }
        return null;
      });
    } catch (_) {
      return null;
    }
  }
}


/// محرك التصدير متعدد الصيغ (.DST, .EXP, .DSB, .JEF, .TBF)
class UniversalExporter {
  static const List<Map<String, String>> supportedFormats = [
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
      final bool isJump = (stMove[i] != 0) && (dx != 0 || dy != 0);
      if (isJump) {
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
      final bool isJump = (stMove[i] != 0) && (dx != 0 || dy != 0);
      if (isJump) {
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
      final bool isJump = (stMove[i] != 0) && (dx != 0 || dy != 0);
      if (isJump) {
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
      final bool isJump = (stMove[i] != 0) && (dx != 0 || dy != 0);
      if (isJump) {
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
      final bool isJump = (stMove[i] != 0) && (dx != 0 || dy != 0);
      if (isJump) {
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
  static VectorDesignData transform(
    VectorDesignData src, {
    double scale = 1.0,
    double rotationDeg = 0.0,
    bool flipH = false,
    bool flipV = false,
    Set<int> deletedColors = const {},
    int? trimStart,
    int? trimEnd,
    double densityFactor = 1.0,
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

    (double, double) xform(double x, double y) {
      double dx = (x - cx) * scale * (flipH ? -1.0 : 1.0);
      double dy = (y - cy) * scale * (flipV ? -1.0 : 1.0);
      final double rx = dx * cosA - dy * sinA + cx;
      final double ry = dx * sinA + dy * cosA + cy;
      return (rx, ry);
    }

    final stX = _Float32Buf(math.max(64, endIdx - startIdx));
    final stY = _Float32Buf(math.max(64, endIdx - startIdx));
    final stMove = _Uint8Buf(math.max(64, endIdx - startIdx));
    final stColor = _Uint8Buf(math.max(64, endIdx - startIdx));

    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    bool hasBounds = false;
    bool forceMove = true;
    final Set<int> usedColors = {};

    void pushStitch(double px, double py, int mv, int c) {
      stX.add(px);
      stY.add(py);
      stMove.add(mv);
      stColor.add(c);
      usedColors.add(c);
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

    final double safeDensity = densityFactor.clamp(0.5, 1.8);
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
      final pt = xform(src.stX[i], src.stY[i]);
      final double px = pt.$1;
      final double py = pt.$2;
      final bool isMove = forceMove || src.stMove[i] != 0 || (hasPrev && c != prevColor);

      if (safeDensity < 0.99 && !isMove && hasPrev && i + 1 < endIdx && src.stMove[i + 1] == 0 && src.stColor[i + 1] == c) {
        // تخفيف الغرز مع الحفاظ على نقاط البداية والنهاية وتغييرات اللون
        thinAcc += safeDensity;
        if (thinAcc < 1.0) {
          continue;
        }
        thinAcc -= 1.0;
      }

      pushStitch(px, py, isMove ? 1 : 0, c);
      forceMove = false;

      if (safeDensity > 1.01 && !isMove && hasPrev && i + 1 < endIdx && src.stMove[i + 1] == 0 && src.stColor[i + 1] == c) {
        // تكثيف الغرز بإضافة غرزة وسطية ناعمة بين الغرزتين المتتاليتين
        denseAcc += (safeDensity - 1.0);
        if (denseAcc >= 1.0) {
          denseAcc -= 1.0;
          final nextPt = xform(src.stX[i + 1], src.stY[i + 1]);
          final double mx = (prevPx + nextPt.$1) * 0.5;
          final double my = (prevPy + nextPt.$2) * 0.5;
          final double d = math.sqrt((mx - px) * (mx - px) + (my - py) * (my - py));
          if (d >= 2.0) {
            pushStitch(mx, my, 0, c);
          }
        }
      }

      prevPx = px;
      prevPy = py;
      prevColor = c;
      hasPrev = true;
    }

    final seqX = _Float32Buf(math.max(16, src.seqX.length));
    final seqY = _Float32Buf(math.max(16, src.seqY.length));
    for (int i = 0; i < src.seqX.length; i++) {
      final pt = xform(src.seqX[i], src.seqY[i]);
      seqX.add(pt.$1);
      seqY.add(pt.$2);
    }

    final beadX = _Float32Buf(math.max(16, src.beadX.length));
    final beadY = _Float32Buf(math.max(16, src.beadY.length));
    for (int i = 0; i < src.beadX.length; i++) {
      final pt = xform(src.beadX[i], src.beadY[i]);
      beadX.add(pt.$1);
      beadY.add(pt.$2);
    }

    return VectorDesignData(
      stX: stX.finish(),
      stY: stY.finish(),
      stMove: stMove.finish(),
      stColor: stColor.finish(),
      seqX: seqX.finish(),
      seqY: seqY.finish(),
      seqCode: src.seqCode,
      beadX: beadX.finish(),
      beadY: beadY.finish(),
      beadCode: src.beadCode,
      paletteArgb: src.paletteArgb,
      stitches: stX.length,
      colorCount: math.max(1, usedColors.length),
      stopsCount: usedColors.length > 1 ? usedColors.length - 1 : 0,
      jumpsCount: src.jumpsCount,
      sequinsCount: src.sequinsCount,
      beadsCount: src.beadsCount,
      trimsCount: src.trimsCount,
      minX: hasBounds ? minX : 0,
      maxX: hasBounds ? maxX : 0,
      minY: hasBounds ? minY : 0,
      maxY: hasBounds ? maxY : 0,
      hasBounds: hasBounds,
      machineType: src.machineType,
    );
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


/// محرك تحويل الكتابة العربية والإنجليزية إلى غرز تطريز احترافية
/// يدعم: التبديل بين فستون على خط الوسط (Centerline Satin) وتاتامي (Tatami)
/// + التحكم بالكثافة + أقرب نقطة تلاقي + الدخول بدرز وسط والرجوع بفستون + تقصير الغرز الداخلية في اللفات
class TextToStitchEngine {
  static Future<VectorDesignData?> generateFromText({
    required String text,
    double widthCm = 12.0,
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

    // 1) رسم النص بدقة عالية على لوحة شفافة (يدعم اتصال الحروف العربية بالكامل)
    const double fontSize = 140.0;
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
    )..layout(maxWidth: 1600);

    final int w = math.max(16, tp.width.ceil() + 24);
    final int h = math.max(16, tp.height.ceil() + 24);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    tp.paint(canvas, const Offset(12, 12));
    final picture = recorder.endRecording();
    final ui.Image img = await picture.toImage(w, h);
    final ByteData? rgba = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    picture.dispose();
    if (rgba == null) return null;

    final Uint8List pixels = rgba.buffer.asUint8List();

    // 2) تنفيذ الحسابات الهندسية الثقيلة في الخيط الخلفي (Isolate) لعدم تجميد الواجهة
    return await Isolate.run(() => _buildStitchesFromMask(
          pixels: pixels,
          w: w,
          h: h,
          isRtl: isRtl,
          widthCm: widthCm,
          densityMm: densityMm,
          colorArgb: colorArgb,
          isSatin: isSatin,
        ));
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
        if (labels[idx] != 0 || pixels[idx * 4 + 3] < 96) continue;

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
              if (labels[nIdx] == 0 && pixels[nIdx * 4 + 3] >= 96) {
                labels[nIdx] = cid;
                queue.add(nIdx);
              }
            }
          }
        }

        if (area >= 8) {
          comps.add(_TextComp(cid, minX, maxX, minY, maxY, area));
        }
      }
    }

    if (comps.isEmpty) return null;

    // 2) ترتيب الكائنات بترتيب القراءة الطبيعي مع إلحاق النقط مباشرة بعد الحرف التابع لها
    int maxArea = 1;
    for (final c in comps) {
      if (c.area > maxArea) maxArea = c.area;
    }
    final List<_TextComp> bodies = [];
    final List<_TextComp> dots = [];
    for (final c in comps) {
      final int cw = c.maxX - c.minX + 1;
      final int ch = c.maxY - c.minY + 1;
      if (c.area < maxArea * 0.14 && cw < 44 && ch < 44) {
        dots.add(c);
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
        if (dot.centerX >= body.minX - 12 && dot.centerX <= body.maxX + 12) {
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
    final double rowStepPx = math.max(1.05, (safeDensityMm * 10.0) / pxToUnits);
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
      // إذا كانت المسافة قصيرة جداً (< 2.5 مم = 25 وحدة) نصلها بغرزة ناعمة بدون قفزة
      bool actualMove = isMove;
      if (isMove && hasNeedlePos) {
        final double d = math.sqrt((ux - curNeedleX) * (ux - curNeedleX) + (uy - curNeedleY) * (uy - curNeedleY));
        if (d < 24.0) {
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
      // ====== وضع الفستون على خط الوسط (Centerline Satin + Underlay Return + Auto-Shortening) ======
      for (final comp in ordered) {
        final int pad = 2;
        final int bw = (comp.maxX - comp.minX + 1) + pad * 2;
        final int bh = (comp.maxY - comp.minY + 1) + pad * 2;
        final int ox = comp.minX - pad;
        final int oy = comp.minY - pad;

        final Uint8List bin = Uint8List(bw * bh);
        for (int y = comp.minY; y <= comp.maxY; y++) {
          for (int x = comp.minX; x <= comp.maxX; x++) {
            if (labels[y * w + x] == comp.id) {
              bin[(y - oy) * bw + (x - ox)] = 1;
            }
          }
        }

        // خريطة المسافة (Distance Transform) لمعرفة نصف عرض الحرف r_i عند كل نقطة
        final Float32List distMap = _computeDistanceTransform(bin, bw, bh);

        // استخراج خط الوسط (Zhang-Suen Skeleton)
        final Uint8List skel = _zhangSuenThin(Uint8List.fromList(bin), bw, bh);
        List<List<(double, double, double)>> chains = _extractSkeletonChains(skel, distMap, bw, bh, ox, oy);

        // احتياطي للنقط الصغيرة جداً التي تتلاشى في الترقيق
        if (chains.isEmpty) {
          final double cx = (comp.minX + comp.maxX) * 0.5;
          final double cy = (comp.minY + comp.maxY) * 0.5;
          final double r = math.max(1.5, math.min(comp.maxX - comp.minX + 1, comp.maxY - comp.minY + 1) * 0.48);
          final double halfLen = math.max(1.5, math.max(comp.maxX - comp.minX + 1, comp.maxY - comp.minY + 1) * 0.35);
          chains = [
            [
              (cx - halfLen, cy, r),
              (cx, cy, r),
              (cx + halfLen, cy, r),
            ]
          ];
        }

        // ترتيب الفروع حسب أقرب نقطة تلاقي مع موقع الإبرة الحالي
        final List<List<(double, double, double)>> orderedChains = [];
        final List<bool> used = List<bool>.filled(chains.length, false);
        double refX = hasNeedlePos ? (curNeedleX / pxToUnits) : (isRtl ? comp.maxX.toDouble() : comp.minX.toDouble());
        double refY = hasNeedlePos ? (curNeedleY / pxToUnits) : ((comp.minY + comp.maxY) * 0.5);

        for (int k = 0; k < chains.length; k++) {
          int bestIdx = -1;
          bool bestRev = false;
          double bestD = 1e18;
          for (int j = 0; j < chains.length; j++) {
            if (used[j]) continue;
            final ch = chains[j];
            if (ch.isEmpty) continue;
            final dStart = _dist2(refX, refY, ch.first.$1, ch.first.$2);
            if (dStart < bestD) {
              bestD = dStart;
              bestIdx = j;
              bestRev = false;
            }
            final dEnd = _dist2(refX, refY, ch.last.$1, ch.last.$2);
            if (dEnd < bestD) {
              bestD = dEnd;
              bestIdx = j;
              bestRev = true;
            }
          }
          if (bestIdx == -1) break;
          used[bestIdx] = true;
          final chosen = bestRev ? chains[bestIdx].reversed.toList() : chains[bestIdx];
          orderedChains.add(chosen);
          refX = chosen.first.$1; // لأننا نرجع بالفستون لنقطة الدخول أو ننهي قريباً منها
          refY = chosen.first.$2;
        }

        // رسم كل فرع: دخول بدرز وسط (Underlay) ثم رجوع بفستون (Satin Return)
        for (final rawChain in orderedChains) {
          final smoothed = _smoothAndResampleChain(rawChain, rowStepPx);
          if (smoothed.length < 2) continue;

          // 1) الدخول بدرز وسط (Running Stitch Underlay) بخطوة ~2.4 مم
          final double runStepUnits = 24.0;
          addPt(smoothed.first.$1 * pxToUnits, smoothed.first.$2 * pxToUnits, true);
          double acc = 0.0;
          for (int i = 1; i < smoothed.length; i++) {
            final double dx = (smoothed[i].$1 - smoothed[i - 1].$1) * pxToUnits;
            final double dy = (smoothed[i].$2 - smoothed[i - 1].$2) * pxToUnits;
            acc += math.sqrt(dx * dx + dy * dy);
            if (acc >= runStepUnits || i == smoothed.length - 1) {
              addPt(smoothed[i].$1 * pxToUnits, smoothed[i].$2 * pxToUnits, false);
              acc = 0.0;
            }
          }

          // 2) الرجوع بفستون (Satin Return) على طول خط الوسط مع دوران عمودي ناعم + تقصير اللفات الحادة
          final rev = smoothed.reversed.toList();
          double? prevLx, prevLy, prevRx, prevRy;
          const double minInnerDistUnits = 3.6; // حد الأمان 0.36 مم لمنع تكتّل الخيط في اللفات

          for (int i = 0; i < rev.length; i++) {
            final int iPrev = math.max(0, i - 2);
            final int iNext = math.min(rev.length - 1, i + 2);
            double tx = rev[iNext].$1 - rev[iPrev].$1;
            double ty = rev[iNext].$2 - rev[iPrev].$2;
            final double tLen = math.sqrt(tx * tx + ty * ty);
            double nx = 0.0, ny = 1.0;
            if (tLen > 1e-4) {
              nx = -ty / tLen;
              ny = tx / tLen;
            }

            final double cx = rev[i].$1;
            final double cy = rev[i].$2;
            final double rPx = (rev[i].$3 * 1.08).clamp(1.6, 38.0);

            double lx = (cx + nx * rPx) * pxToUnits;
            double ly = (cy + ny * rPx) * pxToUnits;
            double rx = (cx - nx * rPx) * pxToUnits;
            double ry = (cy - ny * rPx) * pxToUnits;

            // تقصير الغرز الداخلية في اللفات الحادة (Auto Shortening)
            if (prevLx != null && prevLy != null) {
              final double dl = math.sqrt((lx - prevLx) * (lx - prevLx) + (ly - prevLy) * (ly - prevLy));
              if (dl < minInnerDistUnits) {
                lx = (cx + nx * rPx * 0.72) * pxToUnits;
                ly = (cy + ny * rPx * 0.72) * pxToUnits;
              }
            }
            if (prevRx != null && prevRy != null) {
              final double dr = math.sqrt((rx - prevRx) * (rx - prevRx) + (ry - prevRy) * (ry - prevRy));
              if (dr < minInnerDistUnits) {
                rx = (cx - nx * rPx * 0.72) * pxToUnits;
                ry = (cy - ny * rPx * 0.72) * pxToUnits;
              }
            }

            addPt(lx, ly, false);
            addPt(rx, ry, false);
            prevLx = lx;
            prevLy = ly;
            prevRx = rx;
            prevRy = ry;
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

        // ترتيب الفروع حسب أقرب نقطة تلاقي
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
      machineType: isSatin ? 'Tarik Satin' : 'Tarik Tatami',
    );
  }

  static double _dist2(double x1, double y1, double x2, double y2) {
    final dx = x1 - x2;
    final dy = y1 - y2;
    return dx * dx + dy * dy;
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
    for (int iter = 0; iter < 42; iter++) {
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

  static List<List<(double, double, double)>> _extractSkeletonChains(
    Uint8List skel,
    Float32List distMap,
    int w,
    int h,
    int ox,
    int oy,
  ) {
    final Uint8List visited = Uint8List(w * h);
    final List<List<(double, double, double)>> chains = [];
    const dirs = [
      (1, 0), (-1, 0), (0, 1), (0, -1),
      (1, 1), (-1, -1), (1, -1), (-1, 1),
    ];

    int degree(int x, int y) {
      int deg = 0;
      for (final d in dirs) {
        final nx = x + d.$1;
        final ny = y + d.$2;
        if (nx >= 0 && nx < w && ny >= 0 && ny < h && skel[ny * w + nx] != 0) deg++;
      }
      return deg;
    }

    void walkFrom(int sx, int sy) {
      final List<(double, double, double)> chain = [];
      int cx = sx, cy = sy;
      while (true) {
        final int idx = cy * w + cx;
        visited[idx] = 1;
        chain.add(((cx + ox).toDouble(), (cy + oy).toDouble(), distMap[idx]));

        int nextX = -1, nextY = -1;
        for (final d in dirs) {
          final nx = cx + d.$1;
          final ny = cy + d.$2;
          if (nx >= 0 && nx < w && ny >= 0 && ny < h) {
            final nIdx = ny * w + nx;
            if (skel[nIdx] != 0 && visited[nIdx] == 0) {
              nextX = nx;
              nextY = ny;
              break;
            }
          }
        }
        if (nextX == -1) break;
        cx = nextX;
        cy = nextY;
      }
      if (chain.length >= 2) {
        chains.add(chain);
      }
    }

    // نبدأ أولاً من الأطراف الحرة (degree == 1) لتتبع المسارات الطويلة النظيفة
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final int idx = y * w + x;
        if (skel[idx] != 0 && visited[idx] == 0 && degree(x, y) == 1) {
          walkFrom(x, y);
        }
      }
    }
    // ثم أي حلقات مغلقة متبقية (مثل حلقة حرف ط أو ق أو O)
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final int idx = y * w + x;
        if (skel[idx] != 0 && visited[idx] == 0) {
          walkFrom(x, y);
        }
      }
    }
    return chains;
  }

  static List<(double, double, double)> _smoothAndResampleChain(
    List<(double, double, double)> raw,
    double stepPx,
  ) {
    if (raw.length <= 2) return raw;

    // 1) تنعيم المسار مرتين
    List<(double, double, double)> pts = List.from(raw);
    for (int pass = 0; pass < 2; pass++) {
      final List<(double, double, double)> next = [pts.first];
      for (int i = 1; i < pts.length - 1; i++) {
        final x = (pts[i - 1].$1 + pts[i].$1 * 2.0 + pts[i + 1].$1) * 0.25;
        final y = (pts[i - 1].$2 + pts[i].$2 * 2.0 + pts[i + 1].$2) * 0.25;
        final r = (pts[i - 1].$3 + pts[i].$3 * 2.0 + pts[i + 1].$3) * 0.25;
        next.add((x, y, r));
      }
      next.add(pts.last);
      pts = next;
    }

    // 2) إعادة التوزيع بمسافات متساوية حسب الكثافة
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
    if (out.length < 2) {
      out.add(pts.last);
    }
    return out;
  }
}

class _TextComp {
  final int id, minX, maxX, minY, maxY, area;
  _TextComp(this.id, this.minX, this.maxX, this.minY, this.maxY, this.area);
  double get centerX => (minX + maxX) * 0.5;
}
// Tarik emb - latest


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
    try {
      final raw = await rootBundle.loadString('assets/emb_fonts/index.json');
      final Map<String, dynamic> decoded = jsonDecode(raw);
      final List<dynamic> list = (decoded['fonts'] as List<dynamic>?) ?? const [];
      _cachedIndex = list
          .whereType<Map<String, dynamic>>()
          .map(EmbFontMeta.fromJson)
          .where((f) => f.id.isNotEmpty && f.file.isNotEmpty)
          .toList();
      return _cachedIndex!;
    } catch (_) {
      _cachedIndex = const [];
      return _cachedIndex!;
    }
  }

  static Future<String?> loadRawFontJson(EmbFontMeta meta) async {
    if (_rawFontCache.containsKey(meta.id)) {
      return _rawFontCache[meta.id];
    }
    try {
      final raw = await rootBundle.loadString(meta.file);
      _rawFontCache[meta.id] = raw;
      return raw;
    } catch (_) {
      return null;
    }
  }
}

class _ShapedGlyphToken {
  final String shaped;
  final String base;
  final bool connectsLeft;
  final bool connectsRight;
  final bool isSpace;

  const _ShapedGlyphToken({
    required this.shaped,
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

      // Lam-Alef ligature check
      if (cp == 0x0644 && i + 1 < cps.length && _lamAlef.containsKey(cps[i + 1])) {
        final lig = _lamAlef[cps[i + 1]]!;
        final String shaped = prevConn ? lig[1] : lig[0];
        out.add(_ShapedGlyphToken(
          shaped: shaped,
          base: shaped,
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

      String shaped;
      if (rightConn && leftConn) {
        shaped = forms[3]; // medial
      } else if (leftConn) {
        shaped = forms[2]; // initial
      } else if (rightConn) {
        shaped = forms[1]; // final
      } else {
        shaped = forms[0]; // isolated
      }
      out.add(_ShapedGlyphToken(
        shaped: shaped,
        base: String.fromCharCode(cp),
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
    double densityMm = 0.42,
    double extraSpacingMm = 0.0,
    int underlayMode = 1, // 0 = بدون، 1 = درز وسط تلقائي، 2 = حواف + وسط
    int colorArgb = 0xFFFF1744,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final rawJson = await InkStitchFontCatalog.loadRawFontJson(meta);
    if (rawJson == null || rawJson.isEmpty) return null;

    return await Isolate.run(() => _generateSync(
          rawJson: rawJson,
          text: trimmed,
          letterHeightCm: letterHeightCm,
          densityMm: densityMm,
          extraSpacingMm: extraSpacingMm,
          underlayMode: underlayMode,
          colorArgb: colorArgb,
        ));
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
    final double arabicJoinOverlap = (2.2 * scale).clamp(1.0, 4.5);

    Map<String, dynamic>? lookupGlyph(_ShapedGlyphToken tok) {
      if (glyphs.containsKey(tok.shaped)) return glyphs[tok.shaped] as Map<String, dynamic>;
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
        if (d < 22.0) {
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
        double adv = gw;
        if (tIdx + 1 < tokens.length && !tokens[tIdx + 1].isSpace) {
          final nextTok = tokens[tIdx + 1];
          if (isRtl && tok.connectsLeft && nextTok.connectsRight) {
            adv = math.max(gw * 0.4, gw - arabicJoinOverlap + (extraSpUnits * 0.35));
          } else {
            adv = math.max(gw * 0.4, gw + baseLetterSp + extraSpUnits);
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
          }
        }

        cursorX += isRtl ? -adv : adv;
      }
    }

    if (stX.length < 2) return null;

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
      machineType: '$fontName (Satin)',
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
