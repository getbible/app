import 'dart:convert';

import '../../domain/repositories/study_preferences_repository.dart';
import '../database/local_database.dart';

final class SqlStudyPreferencesRepository
    implements StudyPreferencesRepository {
  const SqlStudyPreferencesRepository(this._database);
  final LocalDatabase _database;

  String _key(String kind, Iterable<String> parts) =>
      'study:v1:$kind:${parts.map(Uri.encodeComponent).join(':')}';

  Future<String?> _readString(String key) async {
    final String? value = await _database.readSetting(key);
    if (value == null) return null;
    final Object? decoded = jsonDecode(value);
    if (decoded is! String) {
      throw const FormatException('Invalid study preference.');
    }
    return decoded;
  }

  Future<bool> _readBool(String key) async {
    final String? value = await _database.readSetting(key);
    if (value == null) return false;
    final Object? decoded = jsonDecode(value);
    if (decoded is! bool) {
      throw const FormatException('Invalid topic preference.');
    }
    return decoded;
  }

  @override
  Future<String?> dictionary(String language, String family) =>
      _readString(_key('dictionary', <String>[language, family]));
  @override
  Future<void> setDictionary(String language, String family, String module) =>
      _database.writeSetting(
        _key('dictionary', <String>[language, family]),
        module,
      );
  @override
  Future<String?> commentary(String language) =>
      _readString(_key('commentary', <String>[language]));
  @override
  Future<void> setCommentary(String language, String module) =>
      _database.writeSetting(_key('commentary', <String>[language]), module);
  @override
  Future<bool> topicFollowed(String scopedTopic) =>
      _readBool(_key('topic-followed', <String>[scopedTopic]));
  @override
  Future<void> setTopicFollowed(String scopedTopic, bool followed) => _database
      .writeSetting(_key('topic-followed', <String>[scopedTopic]), followed);
  @override
  Future<bool> topicHidden(String scopedTopic) =>
      _readBool(_key('topic-hidden', <String>[scopedTopic]));
  @override
  Future<void> setTopicHidden(String scopedTopic, bool hidden) => _database
      .writeSetting(_key('topic-hidden', <String>[scopedTopic]), hidden);
}
