import 'dart:collection';

import '../../core/json.dart';

const int bibleModelVersion = 2;

final class Translation {
  const Translation({
    required this.translation,
    required this.abbreviation,
    required this.lang,
    required this.language,
    required this.direction,
    required this.sha,
    this.description = '',
    this.encoding = '',
    this.distributionLcsh = '',
    this.distributionVersion = '',
    this.distributionVersionDate = '',
    this.distributionAbbreviation = '',
    this.distributionAbout = '',
    this.distributionLicense = '',
    this.distributionSourceType = '',
    this.distributionSource = '',
    this.distributionVersification = '',
    this.distributionHistory = const <String, String>{},
    this.url = '',
    this.extra = const <String, Object?>{},
    this.source,
    this.titles = const <ScriptureTitle>[],
    this.introduction = const <ScriptureIntroduction>[],
  });

  factory Translation.fromJson(Object? value) {
    final JsonMap json = _sourceRecord(value, 'translation');
    const Set<String> known = <String>{
      'translation',
      'abbreviation',
      'description',
      'lang',
      'language',
      'direction',
      'encoding',
      'distribution_lcsh',
      'distribution_version',
      'distribution_version_date',
      'distribution_abbreviation',
      'distribution_about',
      'distribution_license',
      'distribution_sourcetype',
      'distribution_source',
      'distribution_versification',
      'distribution_history',
      'url',
      'sha',
      'modelVersion',
    };
    return Translation(
      translation: requireString(json, 'translation'),
      abbreviation: requireString(json, 'abbreviation').toLowerCase(),
      description: _optionalSourceString(json, 'description'),
      lang: _optionalSourceString(json, 'lang', 'en'),
      language: _optionalSourceString(json, 'language'),
      direction: _optionalSourceString(json, 'direction', 'LTR'),
      encoding: _optionalSourceString(json, 'encoding'),
      distributionLcsh: _optionalSourceString(json, 'distribution_lcsh'),
      distributionVersion: _optionalSourceString(json, 'distribution_version'),
      distributionVersionDate: _optionalSourceString(
        json,
        'distribution_version_date',
      ),
      distributionAbbreviation: _optionalSourceString(
        json,
        'distribution_abbreviation',
      ),
      distributionAbout: _optionalSourceString(json, 'distribution_about'),
      distributionLicense: _optionalSourceString(json, 'distribution_license'),
      distributionSourceType: _optionalSourceString(
        json,
        'distribution_sourcetype',
      ),
      distributionSource: _optionalSourceString(json, 'distribution_source'),
      distributionVersification: _optionalSourceString(
        json,
        'distribution_versification',
      ),
      distributionHistory: stringMap(json['distribution_history']),
      url: _optionalSourceString(json, 'url'),
      sha: requireString(json, 'sha'),
      source: json,
      titles: _optionalRecords(json, 'titles', ScriptureTitle.fromJson),
      introduction: _optionalRecords(
        json,
        'introduction',
        ScriptureIntroduction.fromJson,
      ),
      extra: Map<String, Object?>.fromEntries(
        json.entries.where(
          (MapEntry<String, Object?> item) => !known.contains(item.key),
        ),
      ),
    );
  }

  final String translation;
  final String abbreviation;
  final String description;
  final String lang;
  final String language;
  final String direction;
  final String encoding;
  final String distributionLcsh;
  final String distributionVersion;
  final String distributionVersionDate;
  final String distributionAbbreviation;
  final String distributionAbout;
  final String distributionLicense;
  final String distributionSourceType;
  final String distributionSource;
  final String distributionVersification;
  final Map<String, String> distributionHistory;
  final String url;
  final String sha;
  final Map<String, Object?> extra;
  final JsonMap? source;
  final List<ScriptureTitle> titles;
  final List<ScriptureIntroduction> introduction;

  bool get isRtl => direction.toUpperCase() == 'RTL';
  String get resolvedLanguage =>
      language.trim().isEmpty ? lang.toUpperCase() : language.trim();

  JsonMap toJson() => source != null
      ? Map<String, Object?>.from(source!)
      : <String, Object?>{
          ...extra,
          'modelVersion': bibleModelVersion,
          'translation': translation,
          'abbreviation': abbreviation,
          'description': description,
          'lang': lang,
          'language': language,
          'direction': direction,
          'encoding': encoding,
          'distribution_lcsh': distributionLcsh,
          'distribution_version': distributionVersion,
          'distribution_version_date': distributionVersionDate,
          'distribution_abbreviation': distributionAbbreviation,
          'distribution_about': distributionAbout,
          'distribution_license': distributionLicense,
          'distribution_sourcetype': distributionSourceType,
          'distribution_source': distributionSource,
          'distribution_versification': distributionVersification,
          'distribution_history': distributionHistory,
          'url': url,
          'sha': sha,
          if (titles.isNotEmpty)
            'titles': titles.map((item) => item.toJson()).toList(),
          if (introduction.isNotEmpty)
            'introduction': introduction.map((item) => item.toJson()).toList(),
        };
}

/// A catalogue book number is a source identifier, not a 1..66 enum.
final class BibleBook {
  const BibleBook({
    required this.number,
    required this.name,
    required this.sha,
    this.direction = 'LTR',
    this.url = '',
    this.source,
    this.titles = const <ScriptureTitle>[],
    this.introduction = const <ScriptureIntroduction>[],
  });
  factory BibleBook.fromJson(Object? value) {
    final JsonMap json = _sourceRecord(value, 'book');
    return BibleBook(
      number: _sourceBookNumber(json, 'nr'),
      name: requireString(json, 'name'),
      sha: _optionalSourceString(json, 'sha'),
      direction: _optionalSourceString(json, 'direction', 'LTR'),
      url: _optionalSourceString(json, 'url'),
      source: json,
      titles: _optionalRecords(json, 'titles', ScriptureTitle.fromJson),
      introduction: _optionalRecords(
        json,
        'introduction',
        ScriptureIntroduction.fromJson,
      ),
    );
  }
  final int number;
  final String name, sha, direction, url;
  final JsonMap? source;
  final List<ScriptureTitle> titles;
  final List<ScriptureIntroduction> introduction;
  bool get isRtl => direction.toUpperCase() == 'RTL';
  JsonMap get extra => source ?? const <String, Object?>{};
  JsonMap toJson() => source != null
      ? Map<String, Object?>.from(source!)
      : <String, Object?>{
          'nr': number,
          'name': name,
          'sha': sha,
          'direction': direction,
          if (url.isNotEmpty) 'url': url,
          if (titles.isNotEmpty)
            'titles': titles.map((item) => item.toJson()).toList(),
          if (introduction.isNotEmpty)
            'introduction': introduction.map((item) => item.toJson()).toList(),
        };
}

/// Intro nodes are navigation content, never fabricated Scripture verses.
final class ChapterInfo {
  const ChapterInfo({
    required this.chapter,
    required this.name,
    required this.sha,
    this.url = '',
    this.isIntroduction = false,
    this.nestedChapter,
    this.source,
  });
  factory ChapterInfo.fromJson(Object? value) {
    final JsonMap json = _sourceRecord(value, 'chapter index');
    return ChapterInfo(
      chapter: requireInt(json, 'chapter'),
      name: requireString(json, 'name'),
      sha: _optionalSourceString(json, 'sha'),
      url: _optionalSourceString(json, 'url'),
      source: json,
      isIntroduction: optionalBool(json, '_introduction'),
      nestedChapter: json['_nestedChapter'] == null
          ? null
          : WholeTranslationChapter.fromJson(json['_nestedChapter']),
    );
  }
  final int chapter;
  final String name, sha, url;
  final bool isIntroduction;
  final WholeTranslationChapter? nestedChapter;
  final JsonMap? source;
  JsonMap toJson() => <String, Object?>{
    ...?(source),
    'chapter': chapter,
    'name': name,
    'sha': sha,
    if (url.isNotEmpty) 'url': url,
    if (isIntroduction) '_introduction': true,
    if (nestedChapter != null) '_nestedChapter': nestedChapter!.toJson(),
  };
}

/// Lexical coordinates refer to whitespace words, not character offsets.
final class ScriptureToken {
  const ScriptureToken(this.source);
  factory ScriptureToken.fromJson(Object? value) {
    final JsonMap json = _sourceRecord(value, 'Scripture token');
    requireString(json, 'token');
    requireInt(json, 'word_start');
    requireInt(json, 'word_end');
    for (final String key in <String>['lemma', 'morph', 'xlit']) {
      if (!json.containsKey(key)) continue;
      final JsonMap groups = requireJsonMap(json[key], 'token $key');
      for (final Object? group in groups.values) {
        final List<Object?> values = requireJsonList(group, 'token $key group');
        if (values.any((value) => value is! String)) {
          throw FormatException('Token $key values must be strings.');
        }
      }
    }
    if (json.containsKey('src')) {
      final List<Object?> src = requireJsonList(json['src'], 'token src');
      if (src.any((value) => value is! int && value is! String)) {
        throw const FormatException(
          'Token source values must be integers or strings.',
        );
      }
    }
    for (final String key in <String>['morphSegmented', 'variant']) {
      _optionalBoolean(json, key);
    }
    return ScriptureToken(json);
  }
  final JsonMap source;
  String get token => requireString(source, 'token');
  int get wordStart => requireInt(source, 'word_start');
  int get wordEnd => requireInt(source, 'word_end');
  Object? get lemma => source['lemma'];
  Object? get morph => source['morph'];
  Object? get xlit => source['xlit'];
  List<Object?> get src => source['src'] is List
      ? (source['src'] as List).cast<Object?>()
      : const <Object?>[];
  JsonMap get attributes => source;
  JsonMap toJson() => Map<String, Object?>.from(source);
}

/// Token ranges are zero-based inclusive; word ranges are one-based inclusive.
final class ScriptureSpan {
  const ScriptureSpan(this.source);
  factory ScriptureSpan.fromJson(Object? value) {
    final JsonMap json = _sourceRecord(value, 'Scripture span');
    requireString(json, 'tag');
    requireString(json, 'span');
    for (final String key in <String>[
      'token_start',
      'token_end',
      'word_start',
      'word_end',
    ]) {
      requireInt(json, key);
    }
    if (json.containsKey('attrs')) {
      final JsonMap attrs = requireJsonMap(json['attrs'], 'span attributes');
      if (attrs.values.any((value) => value is! String)) {
        throw const FormatException('Span attributes must be strings.');
      }
    }
    return ScriptureSpan(json);
  }
  final JsonMap source;
  String get tag => requireString(source, 'tag');
  String get span => requireString(source, 'span');
  int get tokenStart => requireInt(source, 'token_start');
  int get tokenEnd => requireInt(source, 'token_end');
  int get wordStart => requireInt(source, 'word_start');
  int get wordEnd => requireInt(source, 'word_end');
  Map<String, String> get attrs => stringMap(source['attrs']);
  JsonMap toJson() => Map<String, Object?>.from(source);
}

final class ScriptureTitle {
  const ScriptureTitle(this.source);
  factory ScriptureTitle.fromJson(Object? value) {
    final JsonMap json = _sourceRecord(value, 'Scripture title');
    requireString(json, 'text');
    _optionalRecords(json, 'tokens', ScriptureToken.fromJson);
    _optionalRecords(json, 'spans', ScriptureSpan.fromJson);
    _optionalBoolean(json, 'canonical');
    return ScriptureTitle(json);
  }
  final JsonMap source;
  String get text => requireString(source, 'text');
  String get type => _optionalSourceString(source, 'type');
  bool? get canonical =>
      source['canonical'] is bool ? source['canonical'] as bool : null;
  String get subtype => _optionalSourceString(source, 'subtype');
  List<ScriptureToken> get tokens =>
      _optionalRecords(source, 'tokens', ScriptureToken.fromJson);
  List<ScriptureSpan> get spans =>
      _optionalRecords(source, 'spans', ScriptureSpan.fromJson);
  JsonMap toJson() => Map<String, Object?>.from(source);
}

final class ScriptureIntroduction {
  const ScriptureIntroduction(this.source);
  factory ScriptureIntroduction.fromJson(Object? value) {
    final JsonMap json = _sourceRecord(value, 'Scripture introduction');
    requireString(json, 'text');
    return ScriptureIntroduction(json);
  }
  final JsonMap source;
  String get text => requireString(source, 'text');
  JsonMap toJson() => Map<String, Object?>.from(source);
}

final class EditorialHeading {
  const EditorialHeading(this.source);
  final JsonMap source;
  int get order => optionalInt(source, 'order');
  int get anchorVerse =>
      optionalInt(requireJsonMap(source['anchor'], 'heading anchor'), 'verse');
  String get text => requireString(source, 'text');
  String get headingType => _optionalSourceString(source, 'heading_type');
  bool? get canonical =>
      source['canonical'] is bool ? source['canonical'] as bool : null;
  JsonMap toJson() => Map<String, Object?>.from(source);
}

final class EditorialParagraph {
  const EditorialParagraph(this.source);
  final JsonMap source;
  int get order => optionalInt(source, 'order');
  int get start => requireInt(source, 'start');
  int get end => requireInt(source, 'end');
  JsonMap toJson() => Map<String, Object?>.from(source);
}

/// Keeps all emitted editorial entries in their original order, including
/// future source annotations that the reader does not yet style.
final class ChapterEditorial {
  const ChapterEditorial(this.entries);
  factory ChapterEditorial.fromJson(Object? value) {
    final List<JsonMap> entries = requireJsonList(value, 'chapter editorial')
        .map((item) => _sourceRecord(item, 'editorial entry'))
        .toList(growable: false);
    for (final JsonMap entry in entries) {
      if (entry['type'] == 'heading') {
        if (requireInt(entry, 'order') < 0) {
          throw const FormatException('Editorial order must be nonnegative.');
        }
        requireString(entry, 'text');
        requireString(entry, 'heading_type');
        if (entry['canonical'] is! bool) {
          throw const FormatException('Heading canonical must be boolean.');
        }
        final JsonMap anchor = requireJsonMap(
          entry['anchor'],
          'heading anchor',
        );
        requireInt(anchor, 'verse');
        if (anchor['edge'] != 'before') {
          throw const FormatException(
            'An editorial heading requires a before anchor.',
          );
        }
      } else if (entry['type'] == 'paragraph') {
        if (requireInt(entry, 'order') < 0) {
          throw const FormatException('Editorial order must be nonnegative.');
        }
        if (requireInt(entry, 'start') > requireInt(entry, 'end')) {
          throw const FormatException(
            'An editorial paragraph range is reversed.',
          );
        }
      }
    }
    return ChapterEditorial(entries);
  }
  final List<JsonMap> entries;
  List<EditorialHeading> get headings => entries
      .where((item) => item['type'] == 'heading')
      .map(EditorialHeading.new)
      .toList(growable: false);
  List<EditorialParagraph> get paragraphs => entries
      .where((item) => item['type'] == 'paragraph')
      .map(EditorialParagraph.new)
      .toList(growable: false);
  List<Object?> toJson() => entries
      .map((item) => Map<String, Object?>.from(item))
      .toList(growable: false);
}

final class Verse {
  const Verse({
    required this.chapter,
    required this.verse,
    required this.name,
    required this.text,
    this.paragraph,
    this.tokens = const <ScriptureToken>[],
    this.spans = const <ScriptureSpan>[],
    this.titles = const <ScriptureTitle>[],
    this.source,
  });
  factory Verse.fromJson(Object? value, {int? fallbackChapter}) {
    final JsonMap json = _sourceRecord(value, 'verse');
    final int resolvedChapter = json.containsKey('chapter')
        ? requireInt(json, 'chapter')
        : fallbackChapter ?? 0;
    if (resolvedChapter < 1 ||
        requireInt(json, 'verse') < 1 ||
        requireString(json, 'text').isEmpty) {
      throw const FormatException(
        'Scripture verses require positive source coordinates and nonempty original text.',
      );
    }
    return Verse(
      chapter: json.containsKey('chapter')
          ? requireInt(json, 'chapter')
          : fallbackChapter ??
                (throw const FormatException('Verse chapter is required.')),
      verse: requireInt(json, 'verse'),
      name: _optionalSourceString(json, 'name'),
      text: requireString(json, 'text'),
      paragraph: _optionalBoolean(json, 'paragraph'),
      source: json,
      tokens: _optionalRecords(json, 'tokens', ScriptureToken.fromJson),
      spans: _optionalRecords(json, 'spans', ScriptureSpan.fromJson),
      titles: _optionalRecords(json, 'titles', ScriptureTitle.fromJson),
    );
  }
  final int chapter, verse;
  final String name, text;
  final bool? paragraph;
  final List<ScriptureToken> tokens;
  final List<ScriptureSpan> spans;
  final List<ScriptureTitle> titles;
  final JsonMap? source;
  JsonMap get extra => source ?? const <String, Object?>{};
  JsonMap toJson() => source != null
      ? Map<String, Object?>.from(source!)
      : <String, Object?>{
          'chapter': chapter,
          'verse': verse,
          'name': name,
          'text': text,
          if (paragraph != null) 'paragraph': paragraph,
          if (tokens.isNotEmpty)
            'tokens': tokens.map((item) => item.toJson()).toList(),
          if (spans.isNotEmpty)
            'spans': spans.map((item) => item.toJson()).toList(),
          if (titles.isNotEmpty)
            'titles': titles.map((item) => item.toJson()).toList(),
        };
}

final class BibleChapter {
  const BibleChapter({
    required this.translation,
    required this.abbreviation,
    required this.language,
    required this.direction,
    required this.bookNumber,
    required this.bookName,
    required this.chapter,
    required this.name,
    required this.verses,
    this.editorial,
    this.source,
    this.titles = const <ScriptureTitle>[],
    this.introduction = const <ScriptureIntroduction>[],
  });
  factory BibleChapter.fromJson(Object? value) {
    final JsonMap json = _sourceRecord(value, 'chapter');
    final int chapter = requireInt(json, 'chapter');
    return BibleChapter(
      translation: _optionalSourceString(json, 'translation'),
      abbreviation: requireString(json, 'abbreviation').toLowerCase(),
      language: _optionalSourceString(json, 'language'),
      direction: _optionalSourceString(json, 'direction', 'LTR'),
      bookNumber: _sourceBookNumber(json, 'book_nr'),
      bookName: requireString(json, 'book_name'),
      chapter: chapter,
      name: requireString(json, 'name'),
      verses: _chapterVerses(json, chapter, 'chapter verses'),
      source: json,
      editorial: json.containsKey('editorial')
          ? ChapterEditorial.fromJson(json['editorial'])
          : null,
      titles: _optionalRecords(json, 'titles', ScriptureTitle.fromJson),
      introduction: _optionalRecords(
        json,
        'introduction',
        ScriptureIntroduction.fromJson,
      ),
    );
  }
  final String translation, abbreviation, language, direction;
  final int bookNumber, chapter;
  final String bookName, name;
  final List<Verse> verses;
  final ChapterEditorial? editorial;
  final List<ScriptureTitle> titles;
  final List<ScriptureIntroduction> introduction;
  final JsonMap? source;
  JsonMap get extra => source ?? const <String, Object?>{};
  String get lang => _optionalSourceString(extra, 'lang');
  String get encoding => _optionalSourceString(extra, 'encoding');
  bool get isRtl => direction.toUpperCase() == 'RTL';
  bool get isIntroduction =>
      verses.isEmpty && (introduction.isNotEmpty || titles.isNotEmpty);
  JsonMap toJson() => source != null
      ? Map<String, Object?>.from(source!)
      : <String, Object?>{
          'translation': translation,
          'abbreviation': abbreviation,
          'language': language,
          'direction': direction,
          'book_nr': bookNumber,
          'book_name': bookName,
          'chapter': chapter,
          'name': name,
          'verses': verses.map((item) => item.toJson()).toList(),
          if (editorial != null) 'editorial': editorial!.toJson(),
          if (titles.isNotEmpty)
            'titles': titles.map((item) => item.toJson()).toList(),
          if (introduction.isNotEmpty)
            'introduction': introduction.map((item) => item.toJson()).toList(),
        };
}

final class WholeTranslation {
  const WholeTranslation({
    required this.translation,
    required this.abbreviation,
    required this.language,
    required this.lang,
    required this.direction,
    required this.books,
    this.source,
    this.titles = const <ScriptureTitle>[],
    this.introduction = const <ScriptureIntroduction>[],
  });
  factory WholeTranslation.fromJson(Object? value) {
    final JsonMap json = _sourceRecord(value, 'whole translation');
    return WholeTranslation(
      translation: requireString(json, 'translation'),
      abbreviation: requireString(json, 'abbreviation').toLowerCase(),
      language: _optionalSourceString(json, 'language'),
      lang: _optionalSourceString(json, 'lang', 'en'),
      direction: _optionalSourceString(json, 'direction', 'LTR'),
      books: requireJsonList(
        json['books'],
        'whole translation books',
      ).map(WholeTranslationBook.fromJson).toList(growable: false),
      source: json,
      titles: _optionalRecords(json, 'titles', ScriptureTitle.fromJson),
      introduction: _optionalRecords(
        json,
        'introduction',
        ScriptureIntroduction.fromJson,
      ),
    );
  }
  final String translation, abbreviation, language, lang, direction;
  final List<WholeTranslationBook> books;
  final List<ScriptureTitle> titles;
  final List<ScriptureIntroduction> introduction;
  final JsonMap? source;
  String get encoding => _optionalSourceString(extra, 'encoding');
  String get description => _optionalSourceString(extra, 'description');
  JsonMap get extra => source ?? const <String, Object?>{};
  JsonMap toJson() => source != null
      ? Map<String, Object?>.from(source!)
      : <String, Object?>{
          'translation': translation,
          'abbreviation': abbreviation,
          'language': language,
          'lang': lang,
          'direction': direction,
          'books': books.map((item) => item.toJson()).toList(),
          if (titles.isNotEmpty)
            'titles': titles.map((item) => item.toJson()).toList(),
          if (introduction.isNotEmpty)
            'introduction': introduction.map((item) => item.toJson()).toList(),
        };
}

final class WholeTranslationBook {
  const WholeTranslationBook({
    required this.number,
    required this.name,
    required this.chapters,
    this.source,
    this.titles = const <ScriptureTitle>[],
    this.introduction = const <ScriptureIntroduction>[],
  });
  factory WholeTranslationBook.fromJson(Object? value) {
    final JsonMap json = _sourceRecord(value, 'whole translation book');
    return WholeTranslationBook(
      number: _sourceBookNumber(json, 'nr'),
      name: requireString(json, 'name'),
      chapters: requireJsonList(
        json['chapters'],
        'whole translation chapters',
      ).map(WholeTranslationChapter.fromJson).toList(growable: false),
      source: json,
      titles: _optionalRecords(json, 'titles', ScriptureTitle.fromJson),
      introduction: _optionalRecords(
        json,
        'introduction',
        ScriptureIntroduction.fromJson,
      ),
    );
  }
  final int number;
  final String name;
  final List<WholeTranslationChapter> chapters;
  final List<ScriptureTitle> titles;
  final List<ScriptureIntroduction> introduction;
  final JsonMap? source;
  JsonMap get extra => source ?? const <String, Object?>{};
  JsonMap toJson() => source != null
      ? Map<String, Object?>.from(source!)
      : <String, Object?>{
          'nr': number,
          'name': name,
          'chapters': chapters.map((item) => item.toJson()).toList(),
          if (titles.isNotEmpty)
            'titles': titles.map((item) => item.toJson()).toList(),
          if (introduction.isNotEmpty)
            'introduction': introduction.map((item) => item.toJson()).toList(),
        };
}

final class WholeTranslationChapter {
  const WholeTranslationChapter({
    required this.chapter,
    required this.name,
    required this.verses,
    this.source,
    this.editorial,
    this.titles = const <ScriptureTitle>[],
    this.introduction = const <ScriptureIntroduction>[],
  });
  factory WholeTranslationChapter.fromJson(Object? value) {
    final JsonMap json = _sourceRecord(value, 'whole translation chapter');
    final int chapter = requireInt(json, 'chapter');
    return WholeTranslationChapter(
      chapter: chapter,
      name: requireString(json, 'name'),
      verses: _chapterVerses(json, chapter, 'whole translation verses'),
      source: json,
      editorial: json.containsKey('editorial')
          ? ChapterEditorial.fromJson(json['editorial'])
          : null,
      titles: _optionalRecords(json, 'titles', ScriptureTitle.fromJson),
      introduction: _optionalRecords(
        json,
        'introduction',
        ScriptureIntroduction.fromJson,
      ),
    );
  }
  final int chapter;
  final String name;
  final List<Verse> verses;
  final ChapterEditorial? editorial;
  final List<ScriptureTitle> titles;
  final List<ScriptureIntroduction> introduction;
  final JsonMap? source;
  JsonMap get extra => source ?? const <String, Object?>{};
  bool get isIntroduction =>
      verses.isEmpty && (titles.isNotEmpty || introduction.isNotEmpty);
  BibleChapter toBibleChapter({
    required String abbreviation,
    required int bookNumber,
    required String bookName,
    String translation = '',
    String language = '',
    String direction = 'LTR',
    String lang = '',
    String encoding = '',
  }) => BibleChapter(
    translation: translation,
    abbreviation: abbreviation,
    language: language,
    direction: direction,
    bookNumber: bookNumber,
    bookName: bookName,
    chapter: chapter,
    name: name,
    verses: verses,
    editorial: editorial,
    titles: titles,
    introduction: introduction,
    source: <String, Object?>{
      ...toJson(),
      'abbreviation': abbreviation,
      'translation': translation,
      'language': language,
      'direction': direction,
      'lang': lang,
      'encoding': encoding,
      'book_nr': bookNumber,
      'book_name': bookName,
    },
  );
  JsonMap toJson() => source != null
      ? Map<String, Object?>.from(source!)
      : <String, Object?>{
          'chapter': chapter,
          'name': name,
          'verses': verses.map((item) => item.toJson()).toList(),
          if (editorial != null) 'editorial': editorial!.toJson(),
          if (titles.isNotEmpty)
            'titles': titles.map((item) => item.toJson()).toList(),
          if (introduction.isNotEmpty)
            'introduction': introduction.map((item) => item.toJson()).toList(),
        };
}

List<T> _optionalRecords<T>(
  JsonMap json,
  String key,
  T Function(Object?) parse,
) => !json.containsKey(key)
    ? <T>[]
    : requireJsonList(json[key], key).map(parse).toList(growable: false);

bool? _optionalBoolean(JsonMap json, String key) {
  if (!json.containsKey(key)) return null;
  if (json[key] is! bool) throw FormatException('$key must be a boolean.');
  return json[key] as bool;
}

// Deeply freeze a parsed source once. Nested factories reuse the views instead
// of duplicating an entire corpus at every translation/book/chapter layer.
JsonMap _sourceRecord(Object? value, String label) {
  if (value is UnmodifiableMapView<String, Object?>) return value;
  final JsonMap json = requireJsonMap(value, label);
  return UnmodifiableMapView<String, Object?>(
    json.map((key, item) => MapEntry(key, _freezeSource(item))),
  );
}

Object? _freezeSource(Object? value) {
  if (value is UnmodifiableMapView<String, Object?> ||
      value is UnmodifiableListView<Object?>) {
    return value;
  }
  if (value is Map) return _sourceRecord(value, 'source metadata');
  if (value is List) {
    return UnmodifiableListView<Object?>(
      value.map(_freezeSource).toList(growable: false),
    );
  }
  return value;
}

List<Verse> _chapterVerses(JsonMap json, int chapter, String label) {
  final List<Verse> verses = requireJsonList(json['verses'], label)
      .map((item) => Verse.fromJson(item, fallbackChapter: chapter))
      .toList(growable: false);
  if (verses.any((verse) => verse.chapter != chapter) ||
      verses.map((verse) => verse.verse).toSet().length != verses.length) {
    throw const FormatException(
      'Verse coordinates must be unique and belong to their containing chapter.',
    );
  }
  return List<Verse>.unmodifiable(verses);
}

String _optionalSourceString(JsonMap json, String key, [String fallback = '']) {
  if (!json.containsKey(key)) return fallback;
  return requireString(json, key);
}

int _sourceBookNumber(JsonMap json, String key) {
  final int number = requireInt(json, key);
  if (number < 1) {
    throw const FormatException('Source book identifiers must be positive.');
  }
  return number;
}
