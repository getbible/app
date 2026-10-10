import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'native_ui_catalog.dart';
import 'web_ui_catalog.dart';

/// Explicit UI-only localization contract shared with app.getbible.life.
///
/// Public resource metadata, Scripture and private user content must never be
/// passed to [text]. They already carry their source language and direction.
final class UiStrings {
  const UiStrings(
    this.locale,
    this._messages, [
    this._nativeMessages = const {},
  ]);

  static const UiStrings english = UiStrings('en', <String>[]);
  static const List<String> supportedLocales = webUiLocales;
  static final Map<String, int> _indexes = <String, int>{
    for (final (int index, String key) in webUiMessages.keys.indexed)
      key: index,
  };
  static final Map<String, String> _englishKeys = <String, String>{
    for (final MapEntry<String, String> entry in webUiMessages.entries)
      entry.value: entry.key,
  };
  static final Map<String, String> _nativeEnglish = <String, String>{
    for (final entry in nativeUiKeys.entries) entry.value: entry.key,
  };
  static final RegExp _placeholder = RegExp(r'\{([a-zA-Z][a-zA-Z0-9]*)\}');

  final String locale;
  final List<String> _messages;
  final Map<String, String> _nativeMessages;

  static UiStrings of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiStringsScope>()?.strings ??
      english;

  /// RTL applies to native controls independently of Scripture's direction.
  bool get isRtl =>
      !webUiFallbackLocales.contains(locale) &&
      const <String>{'ar', 'cop', 'he', 'hbo', 'prs', 'syr'}.contains(locale);

  Locale get flutterLocale {
    // Match the reference packs' documented modern-language aliases for
    // Flutter's built-in selection menus and date/dialog accessibility labels.
    if (webUiFallbackLocales.contains(locale)) return const Locale('en');
    final String frameworkCode =
        const <String, String>{
          'enm': 'en',
          'hbo': 'he',
          'grc': 'el',
          'cu': 'ru',
          'cop': 'ar',
          'got': 'de',
          'mlf': 'ml',
          'rmq': 'es',
          'nd': 'zu',
          'nn': 'nb',
          'syr': 'ar',
          'tl': 'fil',
          'tsg': 'fil',
          'ppk': 'id',
          'zh': 'zh-Hans',
        }[locale] ??
        locale;
    final List<String> parts = frameworkCode.split('-');
    return Locale.fromSubtags(
      languageCode: parts.first,
      scriptCode: parts.length > 1 && parts[1].length == 4 ? parts[1] : null,
    );
  }

  String call(String key, [Map<String, Object> variables = const {}]) {
    final String fallback = webUiMessages[key] ?? _nativeEnglish[key] ?? key;
    final int? index = _indexes[key];
    final String candidate = _nativeEnglish.containsKey(key)
        ? _nativeMessages[key] ?? ''
        : index != null && index < _messages.length
        ? _messages[index]
        : '';
    // A malformed translated placeholder must not lose an important count,
    // resource identity or confirmation parameter. Fall back per message.
    final String template =
        candidate.isNotEmpty && _samePlaceholders(candidate, fallback)
        ? candidate
        : fallback;
    return interpolate(template, variables);
  }

  /// Looks up a literal UI template; unknown native extensions retain English.
  ///
  /// This is deliberately not a translation service. Only widget-owned control
  /// labels belong here. The checked-in native message inventory makes missing
  /// translations visible to reviewers and translation contributors.
  String text(String english, [Map<String, Object> variables = const {}]) {
    final String? key = _englishKeys[english] ?? nativeUiKeys[english];
    if (key != null) return call(key, variables);
    return interpolate(english, variables);
  }

  static String interpolate(String template, Map<String, Object> variables) =>
      template.replaceAllMapped(_placeholder, (Match match) {
        final String name = match.group(1)!;
        return variables.containsKey(name) ? '${variables[name]}' : match[0]!;
      });

  static bool _samePlaceholders(String first, String second) {
    String signature(String value) =>
        (_placeholder
                .allMatches(value)
                .map((Match match) => match.group(1)!)
                .toList()
              ..sort())
            .join('|');
    return signature(first) == signature(second);
  }

  static Future<UiStrings> load(String? language, {AssetBundle? bundle}) async {
    final String locale = normalizeLocale(language);
    if (locale == 'en') return english;
    List<String> messages = const <String>[];
    Map<String, String> native = const <String, String>{};
    final AssetBundle assets = bundle ?? rootBundle;
    try {
      final Object? decoded = jsonDecode(
        await assets.loadString('assets/locales/$locale.json'),
      );
      if (decoded is List<Object?> && decoded.every((item) => item is String)) {
        messages = decoded.cast<String>();
      }
    } on Object {
      // Missing or malformed packs deliberately fall back message by message.
    }
    try {
      final Object? decoded = jsonDecode(
        await assets.loadString('assets/native_locales/$locale.json'),
      );
      if (decoded is Map<String, Object?>) {
        native = <String, String>{
          for (final entry in decoded.entries)
            if (entry.value is String) entry.key: entry.value! as String,
        };
      }
    } on Object {
      // Native extensions fall back independently of the reference pack.
    }
    return UiStrings(locale, messages, native);
  }

  static String normalizeLocale(String? language) {
    final String value = (language ?? 'en').trim().replaceAll('_', '-');
    if (value.isEmpty) return 'en';
    final String normalized = value.toLowerCase();
    if (normalized == 'zh-cn' || normalized == 'zh-hans') return 'zh-Hans';
    if (normalized == 'zh-tw' || normalized == 'zh-hant') return 'zh-Hant';
    final String exact = supportedLocales.firstWhere(
      (String locale) => locale.toLowerCase() == normalized,
      orElse: () => '',
    );
    if (exact.isNotEmpty) return exact;
    final String languageCode = normalized.split('-').first;
    return supportedLocales.contains(languageCode) ? languageCode : 'en';
  }
}

/// Placed above the Navigator so dialogs and newly pushed routes use the same
/// current pack as the reader and rebuild when its selected Bible changes.
class UiStringsScope extends InheritedWidget {
  const UiStringsScope({
    required this.strings,
    required super.child,
    super.key,
  });

  final UiStrings strings;

  @override
  bool updateShouldNotify(UiStringsScope oldWidget) =>
      !identical(strings, oldWidget.strings);
}
