import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class ThreadColorStep {
  final int stopNumber, colorIndex, stitches, colorValue;
  final String colorName;
  ThreadColorStep({required this.stopNumber, required this.colorIndex, required this.stitches, required this.colorName, required this.colorValue});
}

class EmbDesignInfo {
  final String filePath, fileName, machineType;
  final Uint8List? previewJpeg, stitchPreviewBytes;
  final int previewWidth, previewHeight, stitches, colorCount, jumpsCount, sequinsCount, trimsCount;
  final List<ThreadColorStep> colorSequence;
  final double? widthMm, heightMm;

  EmbDesignInfo({
    required this.filePath, required this.fileName, this.previewJpeg, this.stitchPreviewBytes,
    this.previewWidth = 0, this.previewHeight = 0, required this.stitches, required this.colorCount,
    required this.jumpsCount, required this.sequinsCount, this.trimsCount = 0, required this.machineType,
    required this.colorSequence, this.widthMm, this.heightMm,
  });
  int get actualStopsCount => colorSequence.isNotEmpty ? colorSequence.length : colorCount;
}

class _ExtractedImage {
  final Uint8List bytes;
  final int width, height;
  _ExtractedImage(this.bytes, this.width, this.height);
  int get pixels => width * height;
}

// ==========================================
// محرك قراءة ملفات EMB
// ==========================================
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
        if (candidate != null && (bestTrueView == null || candidate.pixels > bestTrueView.pixels)) bestTrueView = candidate;
      }
      final _ExtractedImage? primaryImg = bestTrueView ?? stitchView;
      final Uint8List? secondaryStitch = (bestTrueView != null && stitchView != null) ? stitchView.bytes : null;

      int stitches = 0, colors = 0, jumps = 0, sequins = 0, blings = 0, trims = 0;
      String machine = 'Unknown';
      List<ThreadColorStep> sequence = [];
      double? widthMm, heightMm, exactLeft, exactRight, exactUp, exactDown;

      final infoStream = ole.getStream('${String.fromCharCode(5)}WilcomDesignInformationDDD');
      if (infoStream != null && infoStream.length > 56) {
        final bd = ByteData.sublistView(infoStream);
        final sectionOffset = bd.getUint32(44, Endian.little);
        if (sectionOffset + 8 <= infoStream.length) {
          final propCount = bd.getUint32(sectionOffset + 4, Endian.little);
          final Map<int, int> propPositions = {};
          for (int i = 0; i < propCount; i++) {
            final entryPos = sectionOffset + 8 + (i * 8);
            if (entryPos + 8 > infoStream.length) break;
            propPositions[bd.getUint32(entryPos, Endian.little)] = sectionOffset + bd.getUint32(entryPos + 4, Endian.little);
          }
          final Map<int, String> pidNames = {};
          if (propPositions.containsKey(0)) {
            final dictPos = propPositions[0]!;
            if (dictPos + 4 <= infoStream.length) {
              int curr = dictPos + 4;
              for (int d = 0; d < bd.getUint32(dictPos, Endian.little); d++) {
                if (curr + 8 > infoStream.length) break;
                final dPid = bd.getUint32(curr, Endian.little);
                final nameLen = bd.getUint32(curr + 4, Endian.little);
                curr += 8;
                if (curr + nameLen > infoStream.length) break;
                pidNames[dPid] = latin1.decode(infoStream.sublist(curr, curr + nameLen), allowInvalid: true).replaceAll('\x00', '').trim().toLowerCase();
                curr += nameLen;
              }
            }
          }
          for (final entry in propPositions.entries) {
            final pid = entry.key, propPos = entry.value;
            if (pid == 0 || propPos + 8 > infoStream.length) continue;
            final propType = bd.getUint32(propPos, Endian.little), propName = pidNames[pid] ?? '';
            if ((propType == 3 || propType == 19 || propType == 22) && propPos + 8 <= infoStream.length) {
              final val = bd.getInt32(propPos + 4, Endian.little);
              if (propName.contains('stitches') || pid == 6) stitches = val;
              else if (propName.contains('colour') || propName.contains('color') || pid == 3) colors = val;
              else if (propName.contains('jump') || pid == 7) jumps = val;
              else if (propName.contains('sequin')) sequins = val;
              else if (propName.contains('bling')) blings = val;
              else if (propName.contains('trim')) trims = val;
            } else if ((propType == 4 || propType == 5) && propPos + 8 <= infoStream.length) {
              final dVal = propType == 4 ? bd.getFloat32(propPos + 4, Endian.little) : (propPos + 12 <= infoStream.length ? bd.getFloat64(propPos + 4, Endian.little) : 0.0);
              if (propName == 'design left') exactLeft = dVal;
              else if (propName == 'design right') exactRight = dVal;
              else if (propName == 'design up') exactUp = dVal;
              else if (propName == 'design down') exactDown = dVal;
            } else if (propType == 30 && propPos + 8 <= infoStream.length) {
              final strLen = bd.getUint32(propPos + 4, Endian.little);
              final rawStr = latin1.decode(infoStream.sublist(propPos + 8, (propPos + 8 + strLen).clamp(0, infoStream.length)), allowInvalid: true).replaceAll('\x00', '').trim();
              if ((propName.contains('machine') || pid == 19) && rawStr.isNotEmpty) machine = rawStr;
              else if ((propName.contains('colorway') || pid == 34) && rawStr.isNotEmpty) sequence = _parseColorwayTable(rawStr);
            }
          }
          if (exactLeft != null && exactRight != null) widthMm = _resolveTrueSizeMm((exactRight - exactLeft).abs());
          if (exactUp != null && exactDown != null) heightMm = _resolveTrueSizeMm((exactUp - exactDown).abs());
        }
      }
      if (colors == 0 && sequence.isNotEmpty) colors = sequence.length;
      return EmbDesignInfo(
        filePath: filePath, fileName: filePath.split(Platform.pathSeparator).last,
        previewJpeg: primaryImg?.bytes, stitchPreviewBytes: secondaryStitch,
        previewWidth: primaryImg?.width ?? 0, previewHeight: primaryImg?.height ?? 0,
        stitches: stitches, colorCount: colors, jumpsCount: jumps, sequinsCount: sequins > 0 ? sequins : blings,
        trimsCount: trims, machineType: machine, colorSequence: sequence, widthMm: widthMm, heightMm: heightMm,
      );
    } catch (_) { return null; }
  }

  static double? _resolveTrueSizeMm(double val) {
    if (val <= 0.1) return null;
    return val > 2000 ? val / 10.0 : val;
  }

  static _ExtractedImage? _decodeStreamImage(Uint8List? stream) {
    if (stream == null || stream.length < 16) return null;
    Uint8List? imgBytes;
    if (stream.length > 6 && stream[4] == 0x78) try { imgBytes = Uint8List.fromList(ZLibDecoder().convert(stream.sublist(4))); } catch (_) {}
    if (imgBytes == null && stream[0] == 0x78) try { imgBytes = Uint8List.fromList(ZLibDecoder().convert(stream)); } catch (_) {}
    imgBytes ??= stream;
    final dims = _readImageDimensions(imgBytes);
    return dims == null ? null : _ExtractedImage(imgBytes, dims.$1, dims.$2);
  }

  static (int, int)? _readImageDimensions(Uint8List bytes) {
    if (bytes.length < 24) return null;
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getUint32(16, Endian.big), h = bd.getUint32(20, Endian.big);
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
        final segLen = bd.getUint1
