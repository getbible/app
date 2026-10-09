import 'dart:convert';
import 'dart:typed_data';

/// Maximum file size accepted at the platform boundary, before decoding JSON.
const int maxTextFileBytes = 64 * 1024 * 1024;
const int maxSharedTextBytes = 256 * 1024;

enum TextSaveResult { saved, downloadRequested, cancelled, unsupported }

enum TextShareResult { completed, presented, cancelled, unsupported }

final class TextFileException implements Exception {
  const TextFileException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Explicit file and clipboard operations. A browser download request is not a
/// guarantee that a user has saved a file; callers must preserve that distinction.
abstract interface class TextFileService {
  Future<String?> pickText({int maxBytes = maxTextFileBytes});
  Future<TextSaveResult> saveText({
    required String text,
    required String filename,
    required String mimeType,
  });
  Future<TextShareResult> shareText({
    required String text,
    required String subject,
  });
  Future<void> copyText(String text);
}

/// Check metadata before opening a stream, then enforce the actual byte count.
/// Metadata alone cannot protect against a changing file or an inaccurate size.
Future<String> readBoundedText({
  required Future<int> Function() length,
  required Stream<List<int>> Function() openRead,
  int maxBytes = maxTextFileBytes,
}) async {
  validateTextFileLimit(maxBytes);
  if (await length() > maxBytes) {
    throw const TextFileException('The selected file exceeds the size limit.');
  }
  final BytesBuilder bytes = BytesBuilder();
  await for (final List<int> chunk in openRead()) {
    if (chunk.length > maxBytes - bytes.length) {
      throw const TextFileException(
        'The selected file exceeds the size limit.',
      );
    }
    bytes.add(chunk);
  }
  try {
    return utf8.decode(bytes.takeBytes());
  } on FormatException {
    throw const TextFileException('The selected file is not valid UTF-8 text.');
  }
}

void validateTextFileLimit(int maxBytes) {
  if (maxBytes <= 0 || maxBytes > maxTextFileBytes) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'Invalid file size limit');
  }
}

Uint8List encodeBoundedText(String text, {int maxBytes = maxTextFileBytes}) {
  if (text.length > maxBytes) {
    throw const TextFileException('The text exceeds the size limit.');
  }
  final Uint8List bytes = utf8.encode(text);
  if (bytes.length > maxBytes) {
    throw const TextFileException('The text exceeds the size limit.');
  }
  return bytes;
}

void validateExportFilename(String filename) {
  if (filename.isEmpty ||
      filename == '.' ||
      filename == '..' ||
      filename.length > 200 ||
      RegExp(r'[\\/\x00-\x1f\x7f]').hasMatch(filename)) {
    throw const TextFileException('The export filename is invalid.');
  }
}
