import '../../core/json.dart';
import 'passage.dart';

enum AppearanceMode { system, light, dark }

enum ReaderLayout { lines, paragraph }

enum ReadingWidth { constrained, full }

final class ReaderPreferences {
  const ReaderPreferences({
    this.version = 1,
    this.appearanceMode = AppearanceMode.system,
    this.lightPalette = 'white',
    this.darkPalette = 'black',
    this.readerFont = 'serif',
    this.textSize = 20,
    this.readingWidth = ReadingWidth.full,
    this.layout = ReaderLayout.lines,
    this.activeMarkingGroupId = 'adultery',
    this.highContrast = false,
    this.reduceMotion = false,
    this.showSourceStyles = true,
  });

  factory ReaderPreferences.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'reader preferences');
    return ReaderPreferences(
      version: optionalInt(json, 'version', 1),
      appearanceMode: AppearanceMode.values.firstWhere(
        (AppearanceMode item) =>
            item.name == optionalString(json, 'appearanceMode', 'system'),
        orElse: () => AppearanceMode.system,
      ),
      lightPalette: optionalString(json, 'lightPalette', 'white'),
      darkPalette: optionalString(json, 'darkPalette', 'black'),
      readerFont: optionalString(json, 'readerFont', 'serif'),
      textSize: optionalDouble(json, 'textSize', 20).clamp(16, 36),
      readingWidth: ReadingWidth.values.firstWhere(
        (ReadingWidth item) =>
            item.name == optionalString(json, 'readingWidth', 'full'),
        orElse: () => ReadingWidth.full,
      ),
      layout: ReaderLayout.values.firstWhere(
        (ReaderLayout item) =>
            item.name == optionalString(json, 'layout', 'lines'),
        orElse: () => ReaderLayout.lines,
      ),
      activeMarkingGroupId: optionalString(
        json,
        'activeMarkingGroupId',
        'adultery',
      ),
      highContrast: optionalBool(json, 'highContrast'),
      reduceMotion: optionalBool(json, 'reduceMotion'),
      showSourceStyles: optionalBool(json, 'showSourceStyles', true),
    );
  }

  final int version;
  final AppearanceMode appearanceMode;
  final String lightPalette;
  final String darkPalette;
  final String readerFont;
  final double textSize;
  final ReadingWidth readingWidth;
  final ReaderLayout layout;
  final String activeMarkingGroupId;
  final bool highContrast;
  final bool reduceMotion;
  final bool showSourceStyles;

  ReaderPreferences copyWith({
    AppearanceMode? appearanceMode,
    String? lightPalette,
    String? darkPalette,
    String? readerFont,
    double? textSize,
    ReadingWidth? readingWidth,
    ReaderLayout? layout,
    String? activeMarkingGroupId,
    bool? highContrast,
    bool? reduceMotion,
    bool? showSourceStyles,
  }) => ReaderPreferences(
    appearanceMode: appearanceMode ?? this.appearanceMode,
    lightPalette: lightPalette ?? this.lightPalette,
    darkPalette: darkPalette ?? this.darkPalette,
    readerFont: readerFont ?? this.readerFont,
    textSize: (textSize ?? this.textSize).clamp(16, 36),
    readingWidth: readingWidth ?? this.readingWidth,
    layout: layout ?? this.layout,
    activeMarkingGroupId: activeMarkingGroupId ?? this.activeMarkingGroupId,
    highContrast: highContrast ?? this.highContrast,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    showSourceStyles: showSourceStyles ?? this.showSourceStyles,
  );

  JsonMap toJson() => <String, Object?>{
    'version': version,
    'appearanceMode': appearanceMode.name,
    'lightPalette': lightPalette,
    'darkPalette': darkPalette,
    'readerFont': readerFont,
    'textSize': textSize,
    'readingWidth': readingWidth.name,
    'layout': layout.name,
    'activeMarkingGroupId': activeMarkingGroupId,
    'highContrast': highContrast,
    'reduceMotion': reduceMotion,
    'showSourceStyles': showSourceStyles,
  };
}

final class LastReadingPosition {
  const LastReadingPosition({
    required this.passage,
    required this.verse,
    this.alignment = 0.15,
    required this.updatedAt,
  });

  factory LastReadingPosition.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'last reading position');
    return LastReadingPosition(
      passage: Passage.fromJson(json['passage']),
      verse: requireInt(json, 'verse'),
      alignment: optionalDouble(json, 'alignment', 0.15).clamp(0, 1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        requireInt(json, 'updatedAt'),
        isUtc: true,
      ),
    );
  }

  final Passage passage;
  final int verse;
  final double alignment;
  final DateTime updatedAt;

  JsonMap toJson() => <String, Object?>{
    'version': 1,
    'passage': passage.toJson(),
    'verse': verse,
    'alignment': alignment,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };
}
