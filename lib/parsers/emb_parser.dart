import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ThreadColorStep {
  final int stopNumber;
  final int colorIndex;
  final int stitches;
  final String colorName;
  final int colorValue;

  ThreadColorStep({
    required this.stopNumber,
    required this.colorIndex,
    required this.stitches,
    required this.colorName,
    required this.colorValue,
  });
}

class EmbDesignInfo {
  final String filePath;
  final String fileName;
  final Uint8List? previewJpeg;
  final Uint8List? stitchPreviewBytes;
  final int previewWidth;
  final int previewHeight;
  final int stitches;
  final int colorCount;
  final int jumpsCount;
  final int sequinsCount;
  final int trimsCount;
  final String machineType;
  final List<ThreadColorStep> colorSequence;
  final double? widthMm;
  final double? heightMm;

  EmbDesignInfo({
    required this.filePath,
    required this.fileName,
    this.previewJpeg,
    this.stitchPreviewBytes,
    this.previewWidth = 0,
    this.previewHeight = 0,
    required this.stitches,
    required this.colorCount,
    required this.jumpsCount,
    required this.sequinsCount,
    this.trimsCount = 0,
    required this.machineType,
    required this.colorSequence,
    this.widthMm,
    this.heightMm,
  });

  int get actualStopsCount =>
      colorSequence.isNotEmpty ? colorSequence.length : colorCount;
}

class _ExtractedImage {
  final Uint8List bytes;
  final int width;
  final int height;

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

      // 1. استخراج صور المعاينة (TrueView 3D & 2D Stitch)
      _ExtractedImage? bestTrueView =
          _decodeStreamImage(ole.getStream('TRUEVIEW_ICON'));
      final _ExtractedImage? stitchView =
          _decodeStreamImage(ole.getStream('DESIGN_ICON'));

      for (final name in ole.streamNames) {
        if (name == 'TRUEVIEW_ICON' || name == 'DESIGN_ICON') continue;
        final candidate = _decodeStreamImage(ole.getStream(name));
        if (candidate != null) {
          if (bestTrueView == null || candidate.pixels > bestTrueView.pixels) {
            bestTrueView = candidate;
          }
        }
      }

      _ExtractedImage? primaryImg = bestTrueView ?? stitchView;
      if (primaryImg != null) {
        primaryImg = _enhanceCrystalHD(primaryImg);
      }

      final Uint8List? secondaryStitch =
          (bestTrueView != null && stitchView != null)
              ? _enhanceCrystalHD(stitchView).bytes
              : null;

      // 2. قراءة خصائص الملف + قاموس الأسماء لحساب الترتر بدقة 100%
      int stitches = 0;
      int colors = 0;
      int jumps = 0;
      int sequins = 0;
      int blings = 0;
      int trims = 0;
      String machine = 'Unknown';
      List<ThreadColorStep> sequence = [];
      double? widthMm;
      double? heightMm;
      double? left, right, up, down;

      final infoStreamName =
          '${String.fromCharCode(5)}WilcomDesignInformationDDD';
      final infoStream = ole.getStream(infoStreamName);
      if (infoStream != null && infoStream.length > 56) {
        final bd = ByteData.sublistView(infoStream);
        final sectionOffset = bd.getUint32(44, Endian.little);
        if (sectionOffset + 8 <= infoStream.length) {
          final propCount = bd.getUint32(sectionOffset + 4, Endian.little);

          final Map<int, int> propPositions = {};
          for (int i = 0; i < propCount; i++) {
            final entryPos = sectionOffset + 8 + (i * 8);
            if (entryPos + 8 > infoStream.length) break;
            final pid = bd.getUint32(entryPos, Endian.little);
            final propRelOffset = bd.getUint32(entryPos + 4, Endian.little);
            propPositions[pid] = sectionOffset + propRelOffset;
          }

          // قراءة القاموس (PID 0) لربط اسم 'sequins' بالمعرف الصحيح
          final Map<int, String> pidNames = {};
          if (propPositions.containsKey(0)) {
            final dictPos = propPositions[0]!;
            if (dictPos + 4 <= infoStream.length) {
              final dictEntries = bd.getUint32(dictPos, Endian.little);
              int curr = dictPos + 4;
              for (int d = 0; d < dictEntries; d++) {
                if (curr + 8 > infoStream.length) break;
                final dPid = bd.getUint32(curr, Endian.little);
                final nameLen = bd.getUint32(curr + 4, Endian.little);
                curr += 8;
                if (curr + nameLen > infoStream.length) break;
                final nameStr = latin1
                    .decode(infoStream.sublist(curr, curr + nameLen),
                        allowInvalid: true)
                    .replaceAll('\x00', '')
                    .trim()
                    .toLowerCase();
                curr += nameLen;
                pidNames[dPid] = nameStr;
              }
            }
          }

          for (final entry in propPositions.entries) {
            final pid = entry.key;
            final propPos = entry.value;
            if (pid == 0 || propPos + 8 > infoStream.length) continue;

            final propType = bd.getUint32(propPos, Endian.little);
            final propName = pidNames[pid] ?? '';

            if ((propType == 3 || propType == 19 || propType == 22) &&
                propPos + 8 <= infoStream.length) {
              final val = bd.getInt32(propPos + 4, Endian.little);
              if (propName == 'number of stitches' || (propName.isEmpty && pid == 6)) {
                stitches = val;
              } else if (propName == 'number of colours' || (propName.isEmpty && pid == 3)) {
                colors = val;
              } else if (propName == 'number of jumps' || (propName.isEmpty && pid == 7)) {
                jumps = val;
              } else if (propName == 'sequins') {
                sequins = val;
              } else if (propName == 'blings') {
                blings = val;
              } else if (propName == 'number of trims') {
                trims = val;
              }
            } else if ((propType == 4 || propType == 5) &&
                propPos + 8 <= infoStream.length) {
              final dVal = propType == 4
                  ? bd.getFloat32(propPos + 4, Endian.little)
                  : (propPos + 12 <= infoStream.length
                      ? bd.getFloat64(propPos + 4, Endian.little)
                      : 0.0);

              if (propName == 'design width') {
                widthMm = _normalizeMm(dVal);
              } else if (propName == 'design height') {
                heightMm = _normalizeMm(dVal);
              } else if (propName == 'design left') {
                left = dVal;
              } else if (propName == 'design right') {
                right = dVal;
              } else if (propName == 'design up') {
                up = dVal;
              } else if (propName == 'design down') {
                down = dVal;
              }
            } else if (propType == 30 && propPos + 8 <= infoStream.length) {
              final strLen = bd.getUint32(propPos + 4, Endian.little);
              final endStr =
                  (propPos + 8 + strLen).clamp(0, infoStream.length);
              final rawStr = latin1
                  .decode(
                    infoStream.sublist(propPos + 8, endStr),
                    allowInvalid: true,
                  )
                  .replaceAll('\x00', '')
                  .trim();

              if ((propName == 'embroidery machine name' || pid == 19) &&
                  rawStr.isNotEmpty) {
                machine = rawStr;
              } else if ((propName == 'colorways' || pid == 34) &&
                  rawStr.isNotEmpty) {
                sequence = _parseColorwayTable(rawStr);
              }
            }
          }

          if (widthMm == null && left != null && right != null) {
            widthMm = _normalizeMm((right - left).abs());
          }
          if (heightMm == null && up != null && down != null) {
            heightMm = _normalizeMm((up - down).abs());
          }
        }
      }

      final totalSequins = sequins > 0 ? sequins : blings;
      final fileName = filePath.split(Platform.pathSeparator).last;

      return EmbDesignInfo(
        filePath: filePath,
        fileName: fileName,
        previewJpeg: primaryImg?.bytes,
        stitchPreviewBytes: secondaryStitch,
        previewWidth: primaryImg?.width ?? 0,
        previewHeight: primaryImg?.height ?? 0,
        stitches: stitches,
        colorCount: colors,
        jumpsCount: jumps,
        sequinsCount: totalSequins,
        trimsCount: trims,
        machineType: machine,
        colorSequence: sequence,
        widthMm: widthMm,
        heightMm: heightMm,
      );
    } catch (_) {
      return null;
    }
  }

  static double? _normalizeMm(double val) {
    final v = val.abs();
    if (v <= 0.1) return null;
    if (v > 5000) return v / 100.0;
    return v;
  }

  // خوارزمية رفع الدقة وتصفية الغباش (Crystal Upscaling)
  static _ExtractedImage _enhanceCrystalHD(_ExtractedImage src) {
    try {
      final decoded = img.decodeImage(src.bytes);
      if (decoded == null) return src;

      // مضاعفة الأبعاد بنظام Cubic مع فلتر إبراز حواف الغرز والترتر
      final int scale = (decoded.width < 900 && decoded.height < 900) ? 2 : 1;
      img.Image work = scale > 1
          ? img.copyResize(
              decoded,
              width: decoded.width * scale,
              height: decoded.height * scale,
              interpolation: img.Interpolation.cubic,
            )
          : decoded;

      // تطبيق مصفوفة حدة دقيقة (Unsharp Convolution) لإزالة غباش التكبير
      work = img.convolution(
        work,
        filter: [
          0, -0.45, 0,
          -0.45, 2.8, -0.45,
          0, -0.45, 0,
        ],
        div: 1.0,
        offset: 0,
      );

      final pngBytes = Uint8List.fromList(img.encodePng(work, level: 4));
      return _ExtractedImage(pngBytes, work.width, work.height);
    } catch (_) {
      return src;
    }
  }

  static _ExtractedImage? _decodeStreamImage(Uint8List? stream) {
    if (stream == null || stream.length < 16) return null;

    Uint8List? imgBytes;

    if (stream.length > 6 && stream[4] == 0x78) {
      try {
        final decoded = ZLibDecoder().convert(stream.sublist(4));
        imgBytes = Uint8List.fromList(decoded);
      } catch (_) {}
    }

    if (imgBytes == null && stream[0] == 0x78) {
      try {
        final decoded = ZLibDecoder().convert(stream);
        imgBytes = Uint8List.fromList(decoded);
      } catch (_) {}
    }

    imgBytes ??= stream;

    final dims = _readImageDimensions(imgBytes);
    if (dims == null) return null;
    return _ExtractedImage(imgBytes, dims.$1, dims.$2);
  }

  static (int, int)? _readImageDimensions(Uint8List bytes) {
    if (bytes.length < 24) return null;

    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getUint32(16, Endian.big);
      final h = bd.getUint32(20, Endian.big);
      if (w > 0 && h > 0) return (w, h);
    }

    if (bytes[0] == 0x42 && bytes[1] == 0x4D && bytes.length >= 26) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getInt32(18, Endian.little).abs();
      final h = bd.getInt32(22, Endian.little).abs();
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
        if (marker == 0xD8 ||
            marker == 0xD9 ||
            marker == 0x01 ||
            (marker >= 0xD0 && marker <= 0xD7)) {
          offset += 2;
          continue;
        }
        if (offset + 4 >= bytes.length) break;
        final segLen = bd.getUint16(offset + 2, Endian.big);
        if (segLen < 2) break;

        if ((marker == 0xC0 || marker == 0xC1 || marker == 0xC2) &&
            offset + 9 <= bytes.length) {
          final h = bd.getUint16(offset + 5, Endian.big);
          final w = bd.getUint16(offset + 7, Endian.big);
          if (w > 0 && h > 0) return (w, h);
        }
        offset += 2 + segLen;
      }
      return (256, 256);
    }

    return null;
  }

  static List<ThreadColorStep> _parseColorwayTable(String rawTable) {
    final steps = <ThreadColorStep>[];
    final lines = rawTable.split('\n');
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final cols = line.split('\t');
      if (cols.length >= 7) {
        final stopNum = int.tryParse(cols[0].trim()) ?? 0;
        final colorIdx = int.tryParse(cols[1].trim()) ?? 0;
        final stepStitches = int.tryParse(cols[3].trim()) ?? 0;
        final colorName = cols[6].trim();
        int? parsedRgb;
        if (cols.length >= 8) {
          parsedRgb = _tryParseColorColumn(cols[7].trim());
        }
        if (stopNum > 0) {
          final resolvedName =
              colorName.isEmpty ? 'Color $colorIdx' : colorName;
          steps.add(ThreadColorStep(
            stopNumber: stopNum,
            colorIndex: colorIdx,
            stitches: stepStitches,
            colorName: resolvedName,
            colorValue:
                parsedRgb ?? _resolveColorFromName(resolvedName, colorIdx),
          ));
        }
      }
    }
    return steps;
  }

  static int? _tryParseColorColumn(String col) {
    if (col.isEmpty) return null;
    if (col.startsWith('#') && col.length == 7) {
      final hex = int.tryParse(col.substring(1), radix: 16);
      if (hex != null) return 0xFF000000 | hex;
    }
    final parts = col.split(RegExp(r'[,;\s]+'));
    if (parts.length >= 3) {
      final r = int.tryParse(parts[0]);
      final g = int.tryParse(parts[1]);
      final b = int.tryParse(parts[2]);
      if (r != null && g != null && b != null) {
        return 0xFF000000 |
            ((r.clamp(0, 255)) << 16) |
            ((g.clamp(0, 255)) << 8) |
            (b.clamp(0, 255));
      }
    }
    return null;
  }

  static int _resolveColorFromName(String name, int fallbackIdx) {
    final lower = name.toLowerCase();
    if (lower.contains('aqua') ||
        lower.contains('cyan') ||
        lower.contains('turquoise')) {
      return 0xFF00BCD4;
    }
    if (lower.contains('dark green') || lower.contains('forest')) {
      return 0xFF1B5E20;
    }
    if (lower.contains('olive')) return 0xFF556B2F;
    if (lower.contains('lime') || lower.contains('light green')) {
      return 0xFF8BC34A;
    }
    if (lower.contains('green')) return 0xFF2E7D32;
    if (lower.contains('gold')) return 0xFFD4AF37;
    if (lower.contains('yellow') || lower.contains('lemon')) {
      return 0xFFFBC02D;
    }
    if (lower.contains('orange') || lower.contains('peach')) {
      return 0xFFF57C00;
    }
    if (lower.contains('maroon') ||
        lower.contains('burgundy') ||
        lower.contains('wine')) {
      return 0xFF7A1C24;
    }
    if (lower.contains('dark red') || lower.contains('crimson')) {
      return 0xFFB71C1C;
    }
    if (lower.contains('red')) return 0xFFE53935;
    if (lower.contains('hot pink') ||
        lower.contains('magenta') ||
        lower.contains('fuchsia')) {
      return 0xFFD81B60;
    }
    if (lower.contains('pink') || lower.contains('rose')) {
      return 0xFFF06292;
    }
    if (lower.contains('purple') ||
        lower.contains('violet') ||
        lower.contains('lilac')) {
      return 0xFF8E24AA;
    }
    if (lower.contains('navy') || lower.contains('dark blue')) {
      return 0xFF1A237E;
    }
    if (lower.contains('sky') || lower.contains('light blue')) {
      return 0xFF29B6F6;
    }
    if (lower.contains('blue')) return 0xFF1E88E5;
    if (lower.contains('brown') ||
        lower.contains('chocolate') ||
        lower.contains('coffee')) {
      return 0xFF6D4C41;
    }
    if (lower.contains('beige') ||
        lower.contains('cream') ||
        lower.contains('ivory')) {
      return 0xFFD7CCC8;
    }
    if (lower.contains('white')) return 0xFFF5F5F5;
    if (lower.contains('silver') ||
        lower.contains('light gray') ||
        lower.contains('light grey')) {
      return 0xFFBDBDBD;
    }
    if (lower.contains('gray') || lower.contains('grey')) {
      return 0xFF757575;
    }
    if (lower.contains('black')) return 0xFF212121;

    const palette = [
      0xFF00BCD4,
      0xFFFBC02D,
      0xFF6D4C41,
      0xFFF06292,
      0xFF2E7D32,
      0xFFE53935,
      0xFF1E88E5,
      0xFF8E24AA,
      0xFFF57C00,
      0xFFD4AF37,
    ];
    return palette[fallbackIdx.abs() % palette.length];
  }
}

class _Ole2Reader {
  final Uint8List _data;
  late final ByteData _bd;
  bool isValid = false;
  int _sectorSize = 512;
  int _miniSectorSize = 64;
  int _miniCutoff = 4096;
  int _firstDirSector = 0;
  int _firstMiniFatSector = 0;
  int _numMiniFatSectors = 0;
  final List<int> _fat = [];
  final List<int> _miniFat = [];
  Uint8List? _miniStream;
  final Map<String, _DirEntry> _entries = {};

  Iterable<String> get streamNames => _entries.keys;

  _Ole2Reader(this._data) {
    if (_data.length < 512) return;
    const magic = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    for (int i = 0; i < 8; i++) {
      if (_data[i] != magic[i]) return;
    }
    isValid = true;
    _bd = ByteData.sublistView(_data);

    final sectorShift = _bd.getUint16(30, Endian.little);
    final miniShift = _bd.getUint16(32, Endian.little);
    _sectorSize = 1 << sectorShift;
    _miniSectorSize = 1 << miniShift;

    final numFatSectors = _bd.getUint32(44, Endian.little);
    _firstDirSector = _bd.getUint32(48, Endian.little);
    _miniCutoff = _bd.getUint32(56, Endian.little);
    _firstMiniFatSector = _bd.getUint32(60, Endian.little);
    _numMiniFatSectors = _bd.getUint32(64, Endian.little);
    int difatSector = _bd.getUint32(68, Endian.little);
    final numDifatSectors = _bd.getUint32(72, Endian.little);

    final fatSectorIds = <int>[];
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
      final offset = (fatSectorIds[i] + 1) * _sectorSize;
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

      final codeUnits = <int>[];
      for (int c = 0; c < nameLen - 2; c += 2) {
        codeUnits.add(dirBd.getUint16(off + c, Endian.little));
      }
      final name = String.fromCharCodes(codeUnits);
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
    final entry = _entries[name];
    if (entry == null || entry.size == 0) return null;
    if (entry.size < _miniCutoff && _miniStream != null) {
      return _readMiniChain(entry.startSector, entry.size);
    }
    return _readChain(entry.startSector, maxBytes: entry.size);
  }

  Uint8List _readChain(int startSector, {int? maxBytes}) {
    final builder = BytesBuilder(copy: false);
    int sec = startSector;
    int collected = 0;
    final visited = <int>{};

    while (sec >= 0 && sec < 0xFFFFFFFA && !visited.contains(sec)) {
      visited.add(sec);
      final offset = (sec + 1) * _sectorSize;
      if (offset + _sectorSize > _data.length) break;

      int toRead = _sectorSize;
      if (maxBytes != null && collected + toRead > maxBytes) {
        toRead = maxBytes - collected;
      }
      builder.add(_data.sublist(offset, offset + toRead));
      collected += toRead;
      if (maxBytes != null && collected >= maxBytes) break;

      sec = sec < _fat.length ? _fat[sec] : 0xFFFFFFFE;
    }
    return builder.takeBytes();
  }

  Uint8List _readMiniChain(int startMiniSector, int size) {
    final builder = BytesBuilder(copy: false);
    int sec = startMiniSector;
    int collected = 0;
    final visited = <int>{};

    while (sec >= 0 && sec < 0xFFFFFFFA && !visited.contains(sec)) {
      visited.add(sec);
      final offset = sec * _miniSectorSize;
      if (offset + _miniSectorSize > _miniStream!.length) break;

      int toRead = _miniSectorSize;
      if (collected + toRead > size) {
        toRead = size - collected;
      }
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
  final int startSector;
  final int size;
  _DirEntry(this.name, this.startSector, this.size);
}
