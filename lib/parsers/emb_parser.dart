import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

      final lowerPath = filePath.toLowerCase();
      
      // توجيه الملف حسب صيغته إلى القارئ المناسب
      if (lowerPath.endsWith('.dst')) {
        return await _parseDst(file, filePath);
      } else if (lowerPath.endsWith('.emb')) {
        return await _parseEmb(file, filePath);
      } else {
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  // --- محرك قراءة ملفات الـ DST ---
  static Future<EmbDesignInfo?> _parseDst(File file, String filePath) async {
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length < 512) return null; // الـ DST يجب أن يحتوي على رأس بحجم 512 بايت

      final header = String.fromCharCodes(bytes.sublist(0, 512));
      
      final stitches = _extractDstInt(header, 'ST:');
      final colors = _extractDstInt(header, 'CO:') + 1;
      
      final plusX = _extractDstInt(header, '+X:');
      final minusX = _extractDstInt(header, '-X:');
      final plusY = _extractDstInt(header, '+Y:');
      final minusY = _extractDstInt(header, '-Y:');
      
      // المقاسات في الـ DST تخزن بوحدة 0.1 ملم، لذا نقسم على 10
      final widthMm = (plusX + minusX) / 10.0;
      final heightMm = (plusY + minusY) / 10.0;

      final fileName = filePath.split(Platform.pathSeparator).last;

      return EmbDesignInfo(
        filePath: filePath,
        fileName: fileName,
        previewJpeg: null, 
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

  static int _extractDstInt(String header, String key) {
    final idx = header.indexOf(key);
    if (idx == -1) return 0;
    final endIdx = header.indexOf('\r', idx);
    if (endIdx == -1) return 0;
    final valStr = header.substring(idx + key.length, endIdx).trim();
    return int.tryParse(valStr) ?? 0;
  }

  // --- محرك قراءة ملفات الـ EMB ---
  static Future<EmbDesignInfo?> _parseEmb(File file, String filePath) async {
    try {
      final bytes = await file.readAsBytes();
      final ole = _Ole2Reader(bytes);
      if (!ole.isValid) return null;

      _ExtractedImage? bestTrueView = _decodeStreamImage(ole.getStream('TRUEVIEW_ICON'));
      final _ExtractedImage? stitchView = _decodeStreamImage(ole.getStream('DESIGN_ICON'));

      for (final name in ole.streamNames) {
        if (name == 'TRUEVIEW_ICON' || name == 'DESIGN_ICON') continue;
        final candidate = _decodeStreamImage(ole.getStream(name));
        if (candidate != null) {
          if (bestTrueView == null || candidate.pixels > bestTrueView.pixels) {
            bestTrueView = candidate;
          }
        }
      }

      final _ExtractedImage? primaryImg = bestTrueView ?? stitchView;
      final Uint8List? secondaryStitch = (bestTrueView != null && stitchView != null) ? stitchView.bytes : null;

      int stitches = 0, colors = 0, jumps = 0, sequins = 0, blings = 0, trims = 0;
      String machine = 'Unknown';
      List<ThreadColorStep> sequence = [];
      double? widthMm, heightMm;
      double? exactLeft, exactRight, exactUp, exactDown;

      final infoStreamName = '${String.fromCharCode(5)}WilcomDesignInformationDDD';
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
                final nameStr = latin1.decode(infoStream.sublist(curr, curr + nameLen), allowInvalid: true)
                    .replaceAll('\x00', '').trim().toLowerCase();
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

            if ((propType == 3 || propType == 19 || propType == 22) && propPos + 8 <= infoStream.length) {
              final val = bd.getInt32(propPos + 4, Endian.little);
              if (propName == 'number of stitches' || pid == 6) stitches = val;
              else if (propName == 'number of colours' || pid == 3) colors = val;
              else if (propName == 'number of jumps' || pid == 7) jumps = val;
              else if (propName == 'sequins') sequins = val;
              else if (propName == 'blings') blings = val;
              else if (propName == 'number of trims') trims = val;
            } else if ((propType == 4 || propType == 5) && propPos + 8 <= infoStream.length) {
              final dVal = propType == 4
                  ? bd.getFloat32(propPos + 4, Endian.little)
                  : (propPos + 12 <= infoStream.length ? bd.getFloat64(propPos + 4, Endian.little) : 0.0);
              
              if (propName == 'design left') exactLeft = dVal;
              else if (propName == 'design right') exactRight = dVal;
              else if (propName == 'design up') exactUp = dVal;
              else if (propName == 'design down') exactDown = dVal;
            } else if (propType == 30 && propPos + 8 <= infoStream.length) {
              final strLen = bd.getUint32(propPos + 4, Endian.little);
              final endStr = (propPos + 8 + strLen).clamp(0, infoStream.length);
              final rawStr = latin1.decode(infoStream.sublist(propPos + 8, endStr), allowInvalid: true).replaceAll('\x00', '').trim();
              if ((propName == 'embroidery machine name' || pid == 19) && rawStr.isNotEmpty) machine = rawStr;
              else if ((propName == 'colorways' || pid == 34) && rawStr.isNotEmpty) sequence = _parseColorwayTable(rawStr);
            }
          }

          if (exactLeft != null && exactRight != null) {
            widthMm = _resolveTrueSizeMm((exactRight - exactLeft).abs());
          }
          if (exactUp != null && exactDown != null) {
            heightMm = _resolveTrueSizeMm((exactUp - exactDown).abs());
          }
        }
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
        jumpsCount: jumps,
        sequinsCount: sequins > 0 ? sequins : blings,
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

  static double? _resolveTrueSizeMm(double val) {
    if (val <= 0.1) return null;
    if (val > 2000) return val / 10.0;
    return val;
  }

  static _ExtractedImage? _decodeStreamImage(Uint8List? stream) {
    if (stream == null || stream.length < 16) return null;
    Uint8List? imgBytes;
    if (stream.length > 6 && stream[4] == 0x78) {
      try { imgBytes = Uint8List.fromList(ZLibDecoder().convert(stream.sublist(4))); } catch (_) {}
    }
    if (imgBytes == null && stream[0] == 0x78) {
      try { imgBytes = Uint8List.fromList(ZLibDecoder().convert(stream)); } catch (_) {}
    }
    imgBytes ??= stream;
    final dims = _readImageDimensions(imgBytes);
    if (dims == null) return null;
    return _ExtractedImage(imgBytes, dims.$1, dims.$2);
  }

  static (int, int)? _readImageDimensions(Uint8List bytes) {
    if (bytes.length < 24) return null;
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getUint32(16, Endian.big);
      final h = bd.getUint32(20, Endian.big);
      if (w > 0 && h > 0) return (w, h);
    }
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      int offset = 2;
      final bd = ByteData.sublistView(bytes);
      while (offset + 9 < bytes.length) {
        if (bytes[offset] != 0xFF) { offset++; continue; }
        final marker = bytes[offset + 1];
        if (marker == 0xD8 || marker == 0xD9 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) { offset += 2; continue; }
        if (offset + 4 >= bytes.length) break;
        final segLen = bd.getUint16(offset + 2, Endian.big);
        if (segLen < 2) break;
        if ((marker == 0xC0 || marker == 0xC1 || marker == 0xC2) && offset + 9 <= bytes.length) {
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
        if (stopNum > 0) {
          final resolvedName = colorName.isEmpty ? 'Color $colorIdx' : colorName;
          steps.add(ThreadColorStep(
            stopNumber: stopNum,
            colorIndex: colorIdx,
            stitches: stepStitches,
            colorName: resolvedName,
            colorValue: _resolveColorFromName(resolvedName, colorIdx),
          ));
        }
      }
    }
    return steps;
  }

  static int _resolveColorFromName(String name, int fallbackIdx) {
    const palette = [0xFF00BCD4, 0xFFFBC02D, 0xFF6D4C41, 0xFFF06292, 0xFF2E7D32, 0xFFE53935, 0xFF1E88E5, 0xFF8E24AA, 0xFFF57C00, 0xFFD4AF37];
    return palette[fallbackIdx.abs() % palette.length];
  }
}

class _Ole2Reader {
  final Uint8List _data;
  late final ByteData _bd;
  bool isValid = false;
  int _sectorSize = 512, _miniSectorSize = 64, _miniCutoff = 4096;
  int _firstDirSector = 0, _firstMiniFatSector = 0, _numMiniFatSectors = 0;
  final List<int> _fat = [], _miniFat = [];
  Uint8List? _miniStream;
  final Map<String, _DirEntry> _entries = {};

  Iterable<String> get streamNames => _entries.keys;

  _Ole2Reader(this._data) {
    if (_data.length < 512) return;
    const magic = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    for (int i = 0; i < 8; i++) if (_data[i] != magic[i]) return;
    isValid = true;
    _bd = ByteData.sublistView(_data);

    _sectorSize = 1 << _bd.getUint16(30, Endian.little);
    _miniSectorSize = 1 << _bd.getUint16(32, Endian.little);
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
      for (int j = 0; j < _sectorSize ~/ 4; j++) _fat.add(_bd.getUint32(offset + j * 4, Endian.little));
    }
    if (_numMiniFatSectors > 0 && _firstMiniFatSector < 0xFFFFFFFA) {
      final miniFatBytes = _readChain(_firstMiniFatSector);
      final mBd = ByteData.sublistView(miniFatBytes);
      for (int j = 0; j < miniFatBytes.length ~/ 4; j++) _miniFat.add(mBd.getUint32(j * 4, Endian.little));
    }
    final dirBytes = _readChain(_firstDirSector);
    final dirBd = ByteData.sublistView(dirBytes);
    for (int off = 0; off + 128 <= dirBytes.length; off += 128) {
      final nameLen = dirBd.getUint16(off + 64, Endian.little);
      final type = dirBytes[off + 66];
      if (type == 0 || nameLen < 2 || nameLen > 64) continue;
      final codeUnits = <int>[];
      for (int c = 0; c < nameLen - 2; c += 2) codeUnits.add(dirBd.getUint16(off + c, Endian.little));
      final name = String.fromCharCodes(codeUnits);
      final startSec = dirBd.getUint32(off + 116, Endian.little);
      final size = dirBd.getUint32(off + 120, Endian.little);

      if (type == 5 && startSec < 0xFFFFFFFA && size > 0) _miniStream = _readChain(startSec, maxBytes: size);
      else if (type == 2) _entries[name] = _DirEntry(name, startSec, size);
    }
  }

  Uint8List? getStream(String name) {
    final entry = _entries[name];
    if (entry == null || entry.size == 0) return null;
    if (entry.size < _miniCutoff && _miniStream != null) return _readMiniChain(entry.startSector, entry.size);
    return _readChain(entry.startSector, maxBytes: entry.size);
  }

  Uint8List _readChain(int startSector, {int? maxBytes}) {
    final builder = BytesBuilder(copy: false);
    int sec = startSector, collected = 0;
    final visited = <int>{};
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
    final visited = <int>{};
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
