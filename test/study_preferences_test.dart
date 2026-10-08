import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/data/repositories/sql_settings_repository.dart';
import 'package:getbible_live/data/repositories/sql_study_preferences_repository.dart';
import 'package:getbible_live/domain/models/preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'concurrent scoped Study choices preserve reader and private preferences',
    () async {
      final LocalDatabase database = await LocalDatabase.memory();
      addTearDown(database.close);
      final SqlStudyPreferencesRepository study = SqlStudyPreferencesRepository(
        database,
      );
      final SqlSettingsRepository reader = SqlSettingsRepository(database);
      await reader.savePreferences(const ReaderPreferences(textSize: 29));
      await Future.wait<void>(<Future<void>>[
        study.setDictionary('en:x', 'word', 'first'),
        study.setDictionary('en', 'x:word', 'second'),
        study.setCommentary('en', 'abbott'),
        study.setTopicFollowed('https://one.example/v1|shared', true),
        study.setTopicHidden('https://two.example/v1|shared', true),
      ]);
      expect(await study.dictionary('en:x', 'word'), 'first');
      expect(await study.dictionary('en', 'x:word'), 'second');
      expect(await study.commentary('en'), 'abbott');
      expect(
        await study.topicFollowed('https://one.example/v1|shared'),
        isTrue,
      );
      expect(await study.topicHidden('https://one.example/v1|shared'), isFalse);
      expect(
        await study.topicFollowed('https://two.example/v1|shared'),
        isFalse,
      );
      expect(await study.topicHidden('https://two.example/v1|shared'), isTrue);
      expect((await reader.getPreferences()).textSize, 29);
    },
  );
}
