/// Small local choices are independent of public resource caches and of the
/// reader's established versioned appearance/annotation preferences.
abstract interface class StudyPreferencesRepository {
  Future<String?> dictionary(String language, String family);
  Future<void> setDictionary(String language, String family, String module);
  Future<String?> commentary(String language);
  Future<void> setCommentary(String language, String module);
  Future<bool> topicFollowed(String scopedTopic);
  Future<void> setTopicFollowed(String scopedTopic, bool followed);
  Future<bool> topicHidden(String scopedTopic);
  Future<void> setTopicHidden(String scopedTopic, bool hidden);
}
