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

              // معامل ويلكم الفعلي: 180 وحدة لكل 1 مليمتر
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
  final List points;
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
    double minX = 0, maxX = 0, minY = 0, maxY = 0;
    List points = [];
    List colorBlocks = [];
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
        colorBlocks.add(_StitchBlock(List.from(points)));
        points.clear();
      }
      if (!isJump) {
        points.add(Offset(px, py));
        if (px > maxX) maxX = px;
        if (px < minX) minX = px;
        if (py > maxY) maxY = py;
        if (py < minY) minY = py;
      }
    }
    if (points.isNotEmpty) colorBlocks.add(_StitchBlock(points));
    double width = maxX - minX, height = maxY - minY;
    if (width <= 0 || height <= 0) return null;
    double scale = 800.0 / (width > height ? width : height);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width * scale, height * scale));
    canvas.drawRect(Rect.fromLTWH(0, 0, width * scale, height * scale), Paint()..color = Colors.white);
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
        ..strokeWidth = 1.2
        ..isAntiAlias = true;
      final path = Path();
      final List block = colorBlocks[c].points;
      if (block.isEmpty) continue;
      final Offset firstPt = block[0];
      path.moveTo((firstPt.dx - minX) * scale, (firstPt.dy - minY) * scale);
      for (int i = 1; i < block.length; i++) {
        final Offset pt = block[i];
        path.lineTo((pt.dx - minX) * scale, (pt.dy - minY) * scale);
      }
      canvas.drawPath(path, paint);
    }
    final picture = recorder.endRecording();
    final img = await picture.toImage((width * scale).toInt(), (height * scale).toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }
}

class _DahaoEvent {
  final double x, y;
  final String type; // 'STITCH', 'JUMP', 'SEQUIN'
  final int sequinCode;
  _DahaoEvent(this.x, this.y, this.type, {this.sequinCode = 0});
}

class DahaoParser {
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
        // صيغ ماكينة داهوا (.DHE و .DHA)
        final bool isDhe = lower.endsWith('.dhe');
        final int stops = bd.getUint16(4, Endian.little);
        final int rawColors = bd.getInt32(16, Endian.little);
        final int validColors = (rawColors > 0 && rawColors < 256) ? rawColors : 1;

        Color primaryThreadColor = const Color(0xFF1E8E3E);
        if (bytes.length > 0x1F) {
          final r = bytes[0x1C];
          final g = bytes[0x1D];
          final b = bytes[0x1E];
          if (r > 0 || g > 0 || b > 0) {
            primaryThreadColor = Color.fromARGB(255, r, g, b);
          }
        }

        int startPos = 0x538;
        if (bytes.length > 0x1B2 && bytes[0x1B0] == 0x06 && bytes[0x1B1] == 0x35) {
          int pos = 0x1B0;
          while (pos + 2 <= bytes.length && bytes[pos] == 0x06 && bytes[pos + 1] == 0x35) {
            pos += 2;
          }
          startPos = pos + 16;
        }

        final decoded = _decodeDahaoStitches(bytes, startPos, isDhe);
        final events = decoded.$1;
        final int stitchCount = decoded.$2;
        final int jumpCount = decoded.$3;
        final int sequinCount = decoded.$4;
        final double? widthMm = decoded.$5;
        final double? heightMm = decoded.$6;

        Uint8List? previewPng;
        if (events.length > 2) {
          previewPng = await _renderDahaoToImage(events, primaryThreadColor);
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

  static (int, bool) _decodeByte(int b, int key, int highKey) {
    if (b < 61) {
      return ((b - key) % 61, false);
    } else {
      int val;
      if (key == highKey) {
        val = b + 4;
      } else {
        val = b - 37;
        if (val < 61) val += 49;
      }
      return (val, true);
    }
  }

  static (List<_DahaoEvent>, int, int, int, double?, double?) _decodeDahaoStitches(
    Uint8List bytes,
    int startPos,
    bool isDhe,
  ) {
    final List<_DahaoEvent> events = [_DahaoEvent(0, 0, 'JUMP')];
    if (startPos >= bytes.length - 6) {
      return (events, 0, 0, 0, null, null);
    }

    int ky = isDhe ? 0x21 : 0x0C;
    int kx = isDhe ? 0x33 : 0x25;
    final int highKey = isDhe ? 0x33 : 0x25;

    final Map<int, (int, int)> signMap = isDhe
        ? const {
            0xB5: (1, 1), 0xBF: (1, 1),
            0xA2: (1, -1), 0xAC: (1, -1),
            0x82: (-1, 1), 0x8C: (-1, 1),
            0xD5: (-1, -1), 0xDF: (-1, -1),
            0x8D: (-1, 1), 0x83: (-1, 1),
          }
        : const {
            0xAF: (1, 1), 0x77: (1, 1),
            0x9C: (1, -1), 0xB7: (1, -1),
            0x7C: (-1, 1), 0x97: (-1, 1),
            0xDD: (-1, -1), 0xC2: (-1, -1),
          };

    int x = 0, y = 0;
    double minX = 0, maxX = 0, minY = 0, maxY = 0;
    bool hasBounds = false;

    int stitches = 0, jumps = 0, sequins = 0;
    final int limit = bytes.length - 24;

    for (int p = startPos; p + 2 < limit; p += 3) {
      final int cmd = bytes[p];
      final int b1 = bytes[p + 1];
      final int b2 = bytes[p + 2];

      if (isDhe && (cmd == 0x21 || cmd == 0x33 || cmd == 0xF7)) break;
      if (!isDhe && cmd == 0x00 && b1 == 0x00 && b2 == 0x00) break;

      final d1 = _decodeByte(b1, ky, highKey);
      final int dy = d1.$1;
      final bool flip1 = d1.$2;
      if (flip1) {
        final tmp = ky;
        ky = kx;
        kx = tmp;
      }

      final d2 = _decodeByte(b2, kx, highKey);
      final int dx = d2.$1;
      final bool flip2 = d2.$2;
      if (flip2) {
        final tmp = ky;
        ky = kx;
        kx = tmp;
      }

      if (isDhe && (cmd == 0xE0 || ((cmd == 0xD6 || cmd == 0xCC) && (flip1 || flip2)))) {
        x -= dx;
        y -= dy;
        jumps++;
        events.add(_DahaoEvent(x.toDouble(), -y.toDouble(), 'JUMP'));
      } else if (isDhe && (cmd == 0xD6 || cmd == 0xCC)) {
        if (dx != 0 || dy != 0) {
          sequins++;
          events.add(_DahaoEvent(x.toDouble(), -y.toDouble(), 'SEQUIN', sequinCode: dx));
        }
      } else if (isDhe && (cmd == 0x8D || cmd == 0x83)) {
        x -= dx;
        y += dy;
        jumps++;
        events.add(_DahaoEvent(x.toDouble(), -y.toDouble(), 'JUMP'));
      } else if (signMap.containsKey(cmd)) {
        final s = signMap[cmd]!;
        x += s.$1 * dx;
        y += s.$2 * dy;
        stitches++;
        final px = x.toDouble();
        final py = -y.toDouble();
        events.add(_DahaoEvent(px, py, 'STITCH'));

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

    for (final ev in events) {
      if (ev.type == 'SEQUIN') {
        if (!hasBounds) {
          minX = maxX = ev.x;
          minY = maxY = ev.y;
          hasBounds = true;
        } else {
          if (ev.x < minX) minX = ev.x;
          if (ev.x > maxX) maxX = ev.x;
          if (ev.y < minY) minY = ev.y;
          if (ev.y > maxY) maxY = ev.y;
        }
      }
    }

    final double? widthMm = hasBounds && (maxX - minX) > 0 ? (maxX - minX) / 10.0 : null;
    final double? heightMm = hasBounds && (maxY - minY) > 0 ? (maxY - minY) / 10.0 : null;

    return (events, stitches, jumps, sequins, widthMm, heightMm);
  }

  static Future<Uint8List?> _renderDahaoToImage(
    List<_DahaoEvent> events,
    Color threadColor,
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

    const double pad = 40.0;
    final double scale = 800.0 / math.max(rawW, rawH);
    final int imgW = math.max(64, (rawW * scale + pad * 2).toInt());
    final int imgH = math.max(64, (rawH * scale + pad * 2).toInt());

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()),
      Paint()..color = Colors.white,
    );

    final stitchPaint = Paint()
      ..color = threadColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final Path path = Path();
    bool hasMove = false;

    for (int i = 0; i < events.length; i++) {
      final ev = events[i];
      final double sx = (ev.x - minX) * scale + pad;
      final double sy = (ev.y - minY) * scale + pad;

      if (ev.type == 'JUMP') {
        hasMove = false;
      } else if (ev.type == 'STITCH') {
        if (!hasMove) {
          path.moveTo(sx, sy);
          hasMove = true;
        } else {
          path.lineTo(sx, sy);
        }
      }
    }
    canvas.drawPath(path, stitchPaint);

    for (final ev in events) {
      if (ev.type == 'SEQUIN') {
        final double sx = (ev.x - minX) * scale + pad;
        final double sy = (ev.y - minY) * scale + pad;

        double radius = 9.0;
        Color seqColor = const Color(0xFFE53935);
        if (ev.sequinCode == 4) {
          radius = 6.5;
          seqColor = const Color(0xFFE53935);
        } else if (ev.sequinCode == 6) {
          radius = 8.5;
          seqColor = const Color(0xFFFB8C00);
        } else if (ev.sequinCode == 16) {
          radius = 11.0;
          seqColor = const Color(0xFF1E88E5);
        } else if (ev.sequinCode == 32) {
          radius = 13.5;
          seqColor = const Color(0xFF8E24AA);
        }

        final seqPaint = Paint()
          ..color = seqColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = radius * 0.55
          ..isAntiAlias = true;

        canvas.drawCircle(Offset(sx, sy), radius * 0.7, seqPaint);
      }
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(imgW, imgH);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
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
