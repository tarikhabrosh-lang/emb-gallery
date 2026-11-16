import 'dart:io';
import 'emb_parser.dart';

class DstParser {
  static Future<EmbDesignInfo?> parseFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      
      // نقرأ فقط أول 512 بايت لأنها تحتوي على "رأس الملف" (Header)
      final bytes = await file.readAsBytes();
      if (bytes.length < 512) return null;

      final header = String.fromCharCodes(bytes.sublist(0, 512));
      
      // استخراج عدد الغرز والألوان
      final stitches = _extractInt(header, 'ST:');
      final colors = _extractInt(header, 'CO:') + 1;
      
      // استخراج أبعاد التصميم الفعلي (بحدود الإبرة) 
      // الـ DST يخزن الأبعاد بوحدة 0.1 ملم، لذلك نقسم على 10 لتحويلها إلى ملم
      final plusX = _extractInt(header, '+X:');
      final minusX = _extractInt(header, '-X:');
      final plusY = _extractInt(header, '+Y:');
      final minusY = _extractInt(header, '-Y:');
      
      final widthMm = (plusX + minusX) / 10.0;
      final heightMm = (plusY + minusY) / 10.0;

      final fileName = filePath.split(Platform.pathSeparator).last;

      return EmbDesignInfo(
        filePath: filePath,
        fileName: fileName,
        previewJpeg: null, // DST لا يحتوي على صورة مدمجة
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
}
