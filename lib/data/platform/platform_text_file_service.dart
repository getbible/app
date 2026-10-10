import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../services/text_file_service.dart';
import 'browser_text_share_stub.dart'
    if (dart.library.js_interop) 'browser_text_share_web.dart';

/// Reuses the app's native mobile document handlers. Desktop and browser file
/// access goes through the maintained Flutter file selector implementation.
final class PlatformTextFileService implements TextFileService {
  PlatformTextFileService({
    this.channel = const MethodChannel('life.getbible.mobile/files'),
    this.textFilesLabel = 'Text and JSON files',
    TargetPlatform? platform,
  }) : _platform = platform ?? defaultTargetPlatform;

  final MethodChannel channel;
  final String textFilesLabel;
  final TargetPlatform _platform;
  bool _busy = false;
  bool get _mobile =>
      !kIsWeb &&
      (_platform == TargetPlatform.android || _platform == TargetPlatform.iOS);
  XTypeGroup get _textTypes => XTypeGroup(
    label: textFilesLabel,
    extensions: <String>['json', 'txt', 'md'],
    uniformTypeIdentifiers: <String>['public.json', 'public.plain-text'],
  );

  @override
  Future<String?> pickText({int maxBytes = maxTextFileBytes}) =>
      _exclusive(() async {
        validateTextFileLimit(maxBytes);
        if (_mobile) {
          final String? text = await channel.invokeMethod<String>(
            'pickTextFile',
            <String, Object>{
              'maxBytes': maxBytes,
              'mimeTypes': <String>['application/json', 'text/plain'],
            },
          );
          // Native handlers enforce the bound while streaming, before this
          // defensive check at the Dart boundary.
          if (text != null) encodeBoundedText(text, maxBytes: maxBytes);
          return text;
        }
        final XFile? file = await openFile(
          acceptedTypeGroups: <XTypeGroup>[_textTypes],
        );
        if (file == null) return null;
        return readBoundedText(
          length: file.length,
          openRead: file.openRead,
          maxBytes: maxBytes,
        );
      });

  @override
  Future<TextSaveResult> saveText({
    required String text,
    required String filename,
    required String mimeType,
  }) => _exclusive(() async {
    validateExportFilename(filename);
    final bytes = encodeBoundedText(text);
    if (_mobile) {
      final bool? saved = await channel.invokeMethod<bool>(
        'saveText',
        <String, String>{
          'text': text,
          'filename': filename,
          'mimeType': mimeType,
        },
      );
      return saved == true ? TextSaveResult.saved : TextSaveResult.cancelled;
    }
    final XFile file = XFile.fromData(
      bytes,
      mimeType: mimeType,
      name: filename,
    );
    if (kIsWeb) {
      await file.saveTo(filename);
      return TextSaveResult.downloadRequested;
    }
    final FileSaveLocation? location = await getSaveLocation(
      suggestedName: filename,
    );
    if (location == null) return TextSaveResult.cancelled;
    await file.saveTo(location.path);
    return TextSaveResult.saved;
  });

  @override
  Future<TextShareResult> shareText({
    required String text,
    required String subject,
  }) => _exclusive(() async {
    if (text.length > maxSharedTextBytes ||
        encodeBoundedText(text).length > maxSharedTextBytes) {
      throw const TextFileException(
        'This text is too large for a share sheet. Save it as a file instead.',
      );
    }
    if (kIsWeb) return shareBrowserText(text, subject);
    if (!_mobile) return TextShareResult.unsupported;
    final String? result = await channel.invokeMethod<String>(
      'shareText',
      <String, String>{'text': text, 'subject': subject},
    );
    return switch (result) {
      'completed' => TextShareResult.completed,
      'cancelled' => TextShareResult.cancelled,
      'presented' => TextShareResult.presented,
      _ => TextShareResult.unsupported,
    };
  });

  @override
  Future<void> copyText(String text) async {
    encodeBoundedText(text);
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    if (_busy) {
      throw const TextFileException('Another file operation is already open.');
    }
    _busy = true;
    try {
      return await operation();
    } on PlatformException catch (error) {
      throw TextFileException(
        error.message ?? 'The file operation could not be completed.',
      );
    } on MissingPluginException {
      throw const TextFileException(
        'File access is unavailable. Copy the text instead.',
      );
    } finally {
      _busy = false;
    }
  }
}
