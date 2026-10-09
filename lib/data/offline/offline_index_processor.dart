import 'bible_index_processor.dart';
import 'study_index_processor.dart';

/// Both platform workers execute identical strict validators and indexing code.
Iterable<Map<String, Object?>> indexOfflineSource(Map<String, Object?> input) =>
    switch (input['operation']) {
      'bible' => indexBibleSource(
        (input['bytes']! as List).cast<int>(),
        input['abbreviation']! as String,
        input['sha']! as String,
      ),
      'study' => indexStudySource(input),
      _ => throw const FormatException('Unknown offline indexing operation.'),
    };
