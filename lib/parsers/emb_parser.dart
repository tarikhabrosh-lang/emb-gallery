import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class ThreadColorStep {
  final int stopNumber;
  final int colorIndex;
  final int stitches;
  final String colorName;

  ThreadColorStep({
    required this.stopNumber,
    required this.colorIndex,
    required this.stitches,
    required this.colorName,
  });
}

class EmbDesignInfo {
  final String filePath;
  final String fileName;
  final Uint8List? previewJpeg;
  final int stitches;
  final int colorCount;
  final int stopsCount;
  final String machineType;
  final List<ThreadColorStep> colorSequence;
  final double? widthMm;
  final double? heightMm;

  EmbDesignInfo({
    required this.filePath,
    required this.fileName,
    this.previewJpeg,
    required this.stitches,
    required this.colorCount,
    required this.stopsCount,
    required this.machineType,
    required this.colorSequence,
    this.widthMm,
    this.heightMm,
  });
}

class EmbParser {
  static Future<EmbDesignInfo?> parseFile(String filePath) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final ole = _Ole2Reader(bytes);
      if (!ole.isValid) return null;

      // 1. Extract TrueView preview (TRUEVIEW_ICON -> Zlib -> JPEG)
      Uint8List? jpegBytes;
      final trueViewStream = ole.getStream('TRUEVIEW_ICON');
      if (trueViewStream != null && trueViewStream.length > 4) {
        final compressed = trueViewStream.sublist(4);
        final decoded = ZLibDecoder().convert(compressed);
        jpegBytes = Uint8List.fromList(decoded);
      }

      // 2. Read property set (\x05WilcomDesignInformationDDD)
      int stitches = 0;
      int colors = 0;
      int stops = 0;
      String machine = 'Unknown';
      List<ThreadColorStep> sequence = [];

      final infoStreamName = '${String.fromCharCode(5)}WilcomDesignInformationDDD';
      final infoStream = ole.getStream(infoStreamName);
      if (infoStream != null && infoStream.length > 56) {
        final bd = ByteData.sublistView(infoStream);
        final sectionOffset = bd.getUint32(44, Endian.little);
        if (sectionOffset + 8 <= infoStream.length) {
          final propCount = bd.getUint32(sectionOffset + 4, Endian.little);

          for (int i = 0; i < propCount; i++) {
            final entryPos = sectionOffset + 8 + (i * 8);
            if (entryPos + 8 > infoStream.length) break;

            final pid = bd.getUint32(entryPos, Endian.little);
            final propRelOffset = bd.getUint32(entryPos + 4, Endian.little);
            final propPos = sectionOffset + propRelOffset;
            if (propPos + 8 > infoStream.length) continue;

            final propType = bd.getUint32(propPos, Endian.little);

            if (propType == 3 && propPos + 8 <= infoStream.length) {
              final val = bd.getInt32(propPos + 4, Endian.little);
              if (pid == 6) stitches = val;
              if (pid == 3) colors = val;
              if (pid == 7) stops = val;
            } else if (propType == 30 && propPos + 8 <= infoStream.length) {
              final strLen = bd.getUint32(propPos + 4, Endian.little);
              final endStr = (propPos + 8 + strLen).clamp(0, infoStream.length);
              final rawStr = latin1
                  .decode(
                    infoStream.sublist(propPos + 8, endStr),
                    allowInvalid: true,
                  )
                  .replaceAll('\x00', '')
                  .trim();

              if (pid == 19 && rawStr.isNotEmpty) {
                machine = rawStr;
              } else if (pid == 34 && rawStr.isNotEmpty) {
                sequence = _parseColorwayTable(rawStr);
              }
            }
          }
        }
      }

      final fileName = filePath.split(Platform.pathSeparator).last;
      return EmbDesignInfo(
        filePath: filePath,
        fileName: fileName,
        previewJpeg: jpegBytes,
        stitches: stitches,
        colorCount: colors,
        stopsCount: stops,
        machineType: machine,
        colorSequence: sequence,
      );
    } catch (_) {
      return null;
    }
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
          steps.add(ThreadColorStep(
            stopNumber: stopNum,
            colorIndex: colorIdx,
            stitches: stepStitches,
            colorName: colorName.isEmpty ? 'Color $colorIdx' : colorName,
          ));
        }
      }
    }
    return steps;
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
