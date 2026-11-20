import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

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

class _StitchBlock {
  final List<Offset?> points;
  _StitchBlock(this.points);
}

class DstParser {
  static Future<EmbDesignInfo?> parseFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length < 512) return null;
      final header = String.fromCharCodes(bytes.sublist(0, 512));
      final stitches = _extractInt(header, 'ST:');
      final colors = _extractInt(header, 'CO:') + 1;
      final plusX = _extractInt(header, '+X:');
      final minusX = _extractInt(header, '-X:');
      final plusY = _extractInt(header, '+Y:');
      final minusY = _extractInt(header, '-Y:');
      final widthMm = (plusX + minusX) / 10.0;
      final heightMm = (plusY + minusY) / 10.0;
      final imageBytes = await _renderDstToImage(bytes);
      final fileName = filePath.split(Platform.pathSeparator).last;
      return EmbDesignInfo(
        filePath: filePath,
        fileName: fileName,
        previewJpeg: imageBytes,
        stitches: stitches,
        colorCount: colors,
        jumpsCount: 0,
        sequinsCount: 0,
        machineType: 'Tajima (DST)',
        colorSequence: [],
        widthMm: widthMm > 0 ? widthMm : null,
        heightMm: heightMm > 0 ? heightMm : null,
      );
    } catch (_) {
      return null;
    }
  }

  static int _extractInt(String header, String key) {
    final idx = header.indexOf(key);
    if (idx == -1) return 0;
    final endIdx = header.indexOf('\r', idx);
    if (endIdx == -1) return 0;
    final valStr = header.substring(idx + key.length, endIdx).trim();
    return int.tryParse(valStr) ?? 0;
  }

  static Future<Uint8List?> _renderDstToImage(Uint8List bytes) async {
    int x = 0, y = 0;
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    List<Offset?> points = [];
    List<_StitchBlock> colorBlocks = [];
    for (int i = 512; i < bytes.length - 2; i += 3) {
      int b1 = bytes[i], b2 = bytes[i + 1], b3 = bytes[i + 2];
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
      double px = x.toDouble(), py = -y.toDouble();
      bool isStop = (b3 & 0x40) != 0;
      bool isJump = (b3 & 0x80) != 0;
      if (isStop && points.isNotEmpty) {
        colorBlocks.add(_StitchBlock(List<Offset?>.from(points)));
        points.clear();
      }
      if (isJump) {
        if (points.isNotEmpty && points.last != null) {
          points.add(null);
        }
      } else {
        points.add(Offset(px, py));
        if (px > maxX) maxX = px;
        if (px < minX) minX = px;
        if (py > maxY) maxY = py;
        if (py < minY) minY = py;
      }
    }
    if (points.isNotEmpty) colorBlocks.add(_StitchBlock(points));
    double width = maxX - minX, height = maxY - minY;
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) return null;

    const double pad = 36.0;
    const double maxCanvas = 2200.0;
    final double scale = (maxCanvas - pad * 2) / math.max(width, height);
    final int imgW = math.max(64, (width * scale + pad * 2).ceil());
    final int imgH = math.max(64, (height * scale + pad * 2).ceil());

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()),
      Paint()..color = Colors.white,
    );
    final palette = [
      const Color(0xFF1E88E5),
      const Color(0xFFE53935),
      const Color(0xFF43A047),
      const Color(0xFFFDD835),
      const Color(0xFF8E24AA),
      const Color(0xFFF4511E),
      const Color(0xFF00ACC1),
      const Color(0xFFD81B60),
      const Color(0xFF7CB342),
      const Color(0xFF3949AB),
    ];
    for (int c = 0; c < colorBlocks.length; c++) {
      final paint = Paint()
        ..color = palette[c % palette.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.75
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      final path = Path();
      final List<Offset?> block = colorBlocks[c].points;
      bool hasMove = false;
      for (int i = 0; i < block.length; i++) {
        final Offset? pt = block[i];
        if (pt == null) {
          hasMove = false;
          continue;
        }
        final double sx = (pt.dx - minX) * scale + pad;
        final double sy = (pt.dy - minY) * scale + pad;
        if (!hasMove) {
          path.moveTo(sx, sy);
          hasMove = true;
        } else {
          path.lineTo(sx, sy);
        }
      }
      canvas.drawPath(path, paint);
    }
    final picture = recorder.endRecording();
    final img = await picture.toImage(imgW, imgH);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    picture.dispose();
    return byteData?.buffer.asUint8List();
  }
}

class _DahaoEvent {
  final double x, y;
  final String type; // 'STITCH', 'JUMP', 'SEQUIN'
  final int sequinCode;
  final int colorIndex;
  _DahaoEvent(this.x, this.y, this.type, {this.sequinCode = 0, this.colorIndex = 0});
}

class _R2Coord {
  final int sign;
  final int state;
  final int val;
  _R2Coord(this.sign, this.state, this.val);
}

/// محرك فك تشفير داهوا الموحّد والنهائي (جدول الأوامر الكامل + قفز (+,-) في الحلقة الرابعة + حل تصادم الترتر + إغلاق نقطة الأصل)
class DahaoParser {
  static int _mod(int a, int m) => ((a % m) + m) % m;

  static bool _isSequinOrStopPayload(bool flip1, bool flip2, int dy, int dx) {
    if (flip1 || flip2) return false;
    if (dx == 0 && dy == 0) return true;
    return (dy == 6 || dy == 10) &&
        (dx == 1 || dx == 2 || dx == 4 || dx == 6 || dx == 8 || dx == 16 || dx == 32);
  }

  static Future<EmbDesignInfo?> parseFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length < 32) return null;

      final lower = filePath.toLowerCase();
      final fileName = filePath.split(Platform.pathSeparator).last;
      final bd = ByteData.sublistView(bytes);

      if (lower.endsWith('.dhp')) {
        int colors = 1;
        int stops = 0;
        int trims = 0;
        if (bytes.length > 740) {
          trims = bd.getInt32(680, Endian.little);
          colors = bd.getInt32(700, Endian.little);
          stops = bd.getInt32(732, Endian.little);
          if (colors <= 0 || colors > 256) colors = 1;
        }

        Uint8List? validPreview = await _findValidEmbeddedJpeg(bytes);

        return EmbDesignInfo(
          filePath: filePath,
          fileName: fileName,
          previewJpeg: validPreview,
          stitches: 0,
          colorCount: colors,
          stopsCount: stops > 0 ? stops : 0,
          jumpsCount: 0,
          sequinsCount: 0,
          trimsCount: trims > 0 ? trims : 0,
          machineType: 'Dahao CAD (.DHP)',
          colorSequence: [],
        );
      } else {
        final bool isDhe = lower.endsWith('.dhe');
        final int stops = bd.getUint16(4, Endian.little);
        final int rawColors = bd.getInt32(16, Endian.little);
        final int validColors = (rawColors > 0 && rawColors < 256) ? rawColors : 1;

        final List<Color> threadPalette = _extractHeaderPalette(bytes, validColors);

        final detected = _detectStartAndKeys(bytes, isDhe);
        final int startPos = detected.$1;
        final int stitchEndPos = detected.$2;
        final int ky0 = detected.$3;
        final int kx0 = detected.$4;
        final int? endByte = detected.$5;

        final decoded = _decodeDahaoUniversal(
          bytes,
          startPos,
          stitchEndPos,
          ky0,
          kx0,
          endByte,
          threadPalette.length,
        );

        final events = decoded.$1;
        final int stitchCount = decoded.$2;
        final int jumpCount = decoded.$3;
        final int sequinCount = decoded.$4;
        final double? widthMm = decoded.$5;
        final double? heightMm = decoded.$6;

        Uint8List? previewPng;
        if (events.length > 2) {
          previewPng = await _renderDahaoToImage(events, threadPalette);
        }

        return EmbDesignInfo(
          filePath: filePath,
          fileName: fileName,
          previewJpeg: previewPng,
          stitches: stitchCount,
          colorCount: validColors,
          stopsCount: stops,
          jumpsCount: jumpCount,
          sequinsCount: sequinCount,
          machineType: isDhe ? 'Dahao (.DHE)' : 'Dahao (.DHA)',
          colorSequence: [],
          widthMm: widthMm,
          heightMm: heightMm,
        );
      }
    } catch (_) {
      return null;
    }
  }

  static List<Color> _extractHeaderPalette(Uint8List bytes, int count) {
    final List<Color> colors = [];
    const fallbackPalette = [
      Color(0xFF1E8E3E),
      Color(0xFF1E88E5),
      Color(0xFFE53935),
      Color(0xFF8E24AA),
      Color(0xFFF57C00),
      Color(0xFF00897B),
      Color(0xFFD81B60),
      Color(0xFF3949AB),
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
        colors.add(Color.fromARGB(255, r, g, b));
      }
    }
    if (colors.isEmpty) {
      return fallbackPalette;
    }
    return colors;
  }

  /// اكتشاف نقطة البداية والنهاية ومفتاحي الحلقة الأولى (ky0, kx0) وبايت END بدقة
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

  /// اكتشاف مفتاحي الحلقة الثالثة (110..192، حجم 83)
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

  /// اكتشاف مفتاحي الحلقة الرابعة (193..255، حجم 63) مع دعم قفزات (+,-) عند +32 وتصادم (r4B - r4A == 9)
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

  /// فك إحداثي يقع في الحلقة الثالثة (غرزة طويلة 11.0 - 12.7 مم)
  static int _decodeRing3Coord(int b, int r3A, int r3B) {
    final int k3A = _mod(r3A - 18, 83);
    final int k3B = _mod(r3B - 18, 83);
    final int dA = _mod(b - 110 - k3A, 83);
    final int dB = _mod(b - 110 - k3B, 83);
    final int d = math.min(dA, dB);
    return 110 + (d <= 17 ? d : 11);
  }

  /// اكتشاف مفتاحي الحلقة الثانية (61..109، حجم 49) بدقة 0.0 مم عبر مطابقة العودة لنقطة الأصل (0, 0)
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

      // تقييم كل k0 (مع k1 = (k0 + bestDiff) % 49) باستخدام معيار الإغلاق عند نقطة الأصل (0, 0)
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

        // ترجيح ثانوي خفيف للقيم القصيرة عند تساوي الإغلاق
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

  static (List<_DahaoEvent>, int, int, int, double?, double?) _decodeDahaoUniversal(
    Uint8List bytes,
    int startPos,
    int endPos,
    int ky0,
    int kx0,
    int? endByte,
    int paletteSize,
  ) {
    final List<_DahaoEvent> events = [_DahaoEvent(0, 0, 'JUMP', colorIndex: 0)];
    if (startPos >= endPos - 3) {
      return (events, 0, 0, 0, null, null);
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

    // الجدول الموحد الكامل للقفزات: (+,-) في الحلقة الرابعة عند +32 لأن 0xC1 = 193 أول بايت في الحلقة الرابعة
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
    bool sawRealStitchInColor = false;

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

      // فك التصادم التام بين الترتر والغرز/القفزات عند (r4B - r4A == 9 أو 10)
      if (specialCmds.contains(cmd) &&
          (!stitchSignMap.containsKey(cmd) || isSpecialPayload) &&
          (!jumpSignMap.containsKey(cmd) || isSpecialPayload)) {
        if (dx == 0 && dy == 0) {
          if (sawRealStitchInColor && paletteSize > 1) {
            currentColorIdx = (currentColorIdx + 1) % paletteSize;
            sawRealStitchInColor = false;
          }
          events.add(_DahaoEvent(x.toDouble(), -y.toDouble(), 'JUMP', colorIndex: currentColorIdx));
        } else {
          sequins++;
          final px = x.toDouble();
          final py = -y.toDouble();
          events.add(_DahaoEvent(px, py, 'SEQUIN', sequinCode: dx, colorIndex: currentColorIdx));
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
          events.add(_DahaoEvent(x.toDouble(), -y.toDouble(), 'JUMP', colorIndex: currentColorIdx));
          continue;
        }

        stitches++;
        sawRealStitchInColor = true;
        final px = x.toDouble();
        final py = -y.toDouble();
        events.add(_DahaoEvent(px, py, 'STITCH', colorIndex: currentColorIdx));

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
        events.add(_DahaoEvent(x.toDouble(), -y.toDouble(), 'JUMP', colorIndex: currentColorIdx));
      } else if (dx == 0 && dy == 0) {
        if (sawRealStitchInColor && paletteSize > 1) {
          currentColorIdx = (currentColorIdx + 1) % paletteSize;
          sawRealStitchInColor = false;
        }
        events.add(_DahaoEvent(x.toDouble(), -y.toDouble(), 'JUMP', colorIndex: currentColorIdx));
      }
    }

    final double? widthMm = hasBounds && (maxX - minX) > 0 ? (maxX - minX) / 10.0 : null;
    final double? heightMm = hasBounds && (maxY - minY) > 0 ? (maxY - minY) / 10.0 : null;

    return (events, stitches, jumps, sequins, widthMm, heightMm);
  }

  static Future<Uint8List?> _renderDahaoToImage(
    List<_DahaoEvent> events,
    List<Color> threadPalette,
  ) async {
    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;

    for (final ev in events) {
      if (ev.type == 'STITCH' || ev.type == 'SEQUIN') {
        if (ev.x < minX) minX = ev.x;
        if (ev.x > maxX) maxX = ev.x;
        if (ev.y < minY) minY = ev.y;
        if (ev.y > maxY) maxY = ev.y;
      }
    }

    final double rawW = maxX - minX;
    final double rawH = maxY - minY;
    if (!rawW.isFinite || !rawH.isFinite || rawW <= 0 || rawH <= 0) return null;

    const double pad = 36.0;
    const double maxCanvas = 2200.0;
    final double scale = (maxCanvas - pad * 2) / math.max(rawW, rawH);
    final int imgW = math.max(64, (rawW * scale + pad * 2).ceil());
    final int imgH = math.max(64, (rawH * scale + pad * 2).ceil());

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()),
      Paint()..color = Colors.white,
    );

    Path currentPath = Path();
    int activeColorIdx = -1;
    bool hasMove = false;

    void flushPath() {
      if (!hasMove || activeColorIdx < 0) return;
      final paint = Paint()
        ..color = threadPalette[activeColorIdx % threadPalette.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.75
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      canvas.drawPath(currentPath, paint);
      currentPath = Path();
      hasMove = false;
    }

    for (int i = 0; i < events.length; i++) {
      final ev = events[i];
      final double sx = (ev.x - minX) * scale + pad;
      final double sy = (ev.y - minY) * scale + pad;

      if (ev.type == 'JUMP') {
        flushPath();
      } else if (ev.type == 'STITCH') {
        if (ev.colorIndex != activeColorIdx) {
          flushPath();
          activeColorIdx = ev.colorIndex;
        }
        if (!hasMove) {
          currentPath.moveTo(sx, sy);
          hasMove = true;
        } else {
          currentPath.lineTo(sx, sy);
        }
      }
    }
    flushPath();

    for (final ev in events) {
      if (ev.type == 'SEQUIN') {
        final double sx = (ev.x - minX) * scale + pad;
        final double sy = (ev.y - minY) * scale + pad;

        double radiusUnits = 15.0;
        Color seqColor = const Color(0xFFE53935);
        if (ev.sequinCode == 1 || ev.sequinCode == 4) {
          radiusUnits = 15.0;
          seqColor = const Color(0xFFE53935);
        } else if (ev.sequinCode == 2 || ev.sequinCode == 6) {
          radiusUnits = 22.0;
          seqColor = const Color(0xFFFB8C00);
        } else if (ev.sequinCode == 16) {
          radiusUnits = 28.0;
          seqColor = const Color(0xFF1E88E5);
        } else if (ev.sequinCode == 32) {
          radiusUnits = 35.0;
          seqColor = const Color(0xFF8E24AA);
        }

        final double radius = (radiusUnits * scale).clamp(2.5, 18.0);
        final seqPaint = Paint()
          ..color = seqColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = (radius * 0.25).clamp(0.7, 2.2)
          ..isAntiAlias = true;

        canvas.drawCircle(Offset(sx, sy), radius, seqPaint);
      }
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(imgW, imgH);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    picture.dispose();
    return byteData?.buffer.asUint8List();
  }

  static Future<Uint8List?> _findValidEmbeddedJpeg(Uint8List data) async {
    int pos = _findBytes(data, [0xFF, 0xD8, 0xFF]);
    while (pos != -1 && pos + 16 < data.length) {
      final int marker = data[pos + 3];
      if (marker == 0xE0 || marker == 0xE1 || marker == 0xDB || marker == 0xC0) {
        final int endPos = _findBytes(data, [0xFF, 0xD9], startFrom: pos + 4);
        if (endPos != -1 && endPos - pos > 2048 && endPos + 2 <= data.length) {
          final candidate = data.sublist(pos, endPos + 2);
          try {
            final codec = await ui.instantiateImageCodec(candidate);
            final frame = await codec.getNextFrame();
            if (frame.image.width > 16 && frame.image.height > 16) {
              return candidate;
            }
          } catch (_) {}
        }
      }
      pos = _findBytes(data, [0xFF, 0xD8, 0xFF], startFrom: pos + 3);
    }
    return null;
  }

  static int _findBytes(Uint8List data, List<int> pattern, {int startFrom = 0}) {
    if (pattern.isEmpty || data.length < pattern.length) return -1;
    final int limit = data.length - pattern.length;
    for (int i = startFrom; i <= limit; i++) {
      bool match = true;
      for (int j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }
}
