import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../core/request_cancellation.dart';
import '../domain/models/public_topic.dart';
import '../domain/models/service_envelopes.dart';
import '../domain/models/study_context.dart';
import '../domain/repositories/public_topics_repository.dart';
import '../domain/repositories/study_preferences_repository.dart';

/// Catalogue discovery, public reading, local visibility, and explicit private
/// copying have separate state so an unavailable association cannot block reading.
final class TopicsController extends ChangeNotifier {
  TopicsController({
    required this.repository,
    required this.preferences,
    required this.copyRepository,
  });

  final PublicTopicsRepository repository;
  final StudyPreferencesRepository preferences;
  final PublicTopicCopyRepository copyRepository;
  final RequestOwner _catalogueOwner = RequestOwner();
  final RequestOwner _topicOwner = RequestOwner();
  final RequestOwner _namesOwner = RequestOwner();
  bool _disposed = false;
  StudyContext? context;
  PublicTopicDiscovery? discovery;
  PublicTopicCatalogue? catalogue;
  PublicTopic? selectedTopic;
  String? selectedTopicId;
  String locale = 'en';
  List<PublicTopicLocale> availableLocales = const <PublicTopicLocale>[];
  Map<String, String> localizedNames = const <String, String>{};
  Set<String> relatedIds = const <String>{};
  final Set<String> followed = <String>{};
  final Set<String> hidden = <String>{};
  final Set<String> savingPreferences = <String>{};
  bool loading = false;
  bool loadingTopic = false;
  bool loadingNames = false;
  bool restoringPreferences = false;
  bool copying = false;
  Object? error;
  Object? topicError;
  Object? associationError;
  Object? localeError;
  Object? preferenceError;
  Object? copyError;
  PublicTopicCopyResult? copyResult;

  String nameOf(PublicTopicSummary topic) =>
      localizedNames[topic.id] ?? topic.name;

  Future<void> initialize(StudyContext newContext) async {
    final RequestCancellation request = _catalogueOwner.begin();
    _topicOwner.cancel();
    _namesOwner.cancel();
    context = newContext;
    selectedTopic = null;
    selectedTopicId = null;
    topicError = null;
    copyError = null;
    copyResult = null;
    relatedIds = const <String>{};
    associationError = null;
    loading = true;
    restoringPreferences = true;
    loadingTopic = false;
    error = null;
    _notify();
    try {
      final PublicTopicDiscovery discovered = await repository.discovery(
        cancellation: request,
      );
      final PublicTopicCatalogue topics = await repository.catalogue(
        cancellation: request,
      );
      final List<PublicTopicLocale> locales = await repository.locales(
        cancellation: request,
      );
      if (!_catalogueOwner.owns(request)) return;
      if (discovered.topicCount != topics.topics.length ||
          discovered.associationCount !=
              topics.topics.fold<int>(
                0,
                (int total, PublicTopicSummary topic) =>
                    total + topic.verseCount,
              )) {
        throw const ApiFormatException(
          'The public-topic catalogue changed during discovery. Please retry.',
        );
      }
      discovery = discovered;
      catalogue = topics;
      availableLocales = locales;
      // Keep the picker valid while saved preferences and localized names load.
      locale = 'en';
      localizedNames = const <String, String>{};
      followed.clear();
      hidden.clear();
      loading = false;
      _notify();
      // Visibility is local preference data. Its failure never makes a public
      // catalogue or the captured reader context disappear.
      await _loadPreferences(topics, request);
      if (!_catalogueOwner.owns(request)) return;
      final String requestedLocale = newContext.language
          .toLowerCase()
          .replaceAll('_', '-');
      final String chosenLocale =
          locales.any(
            (PublicTopicLocale value) => value.code == requestedLocale,
          )
          ? requestedLocale
          : locales.any(
              (PublicTopicLocale value) =>
                  value.code == requestedLocale.split('-').first,
            )
          ? requestedLocale.split('-').first
          : 'en';
      await selectLocale(chosenLocale);
      if (!_catalogueOwner.owns(request)) return;
      if (newContext.book < 1 ||
          newContext.book > 66 ||
          newContext.chapter < 1 ||
          newContext.chapter > 150) {
        // A limitation of this public dataset, never of Bible navigation.
        associationError = const FormatException(
          'This public dataset covers books 1–66 and regular chapters. Browse all topics below.',
        );
      } else {
        try {
          final PublicTopicAssociations associations = await repository.chapter(
            newContext.book,
            newContext.chapter,
            cancellation: request,
          );
          if (_catalogueOwner.owns(request)) {
            relatedIds = associations.forVerse(newContext.verseNumber);
          }
        } on RequestCancelledException {
          return;
        } catch (failure) {
          if (_catalogueOwner.owns(request)) associationError = failure;
        }
      }
    } on RequestCancelledException {
      return;
    } catch (failure) {
      if (_catalogueOwner.owns(request)) error = failure;
    } finally {
      if (_catalogueOwner.owns(request)) {
        loading = false;
        restoringPreferences = false;
        _notify();
      }
    }
  }

  Future<void> _loadPreferences(
    PublicTopicCatalogue topics,
    RequestCancellation request,
  ) async {
    preferenceError = null;
    try {
      for (final PublicTopicSummary topic in topics.topics) {
        final String scope = scopedPublicTopic(
          repository.sourceScope,
          topic.id,
        );
        final bool isFollowed = await preferences.topicFollowed(scope);
        final bool isHidden = await preferences.topicHidden(scope);
        if (!_catalogueOwner.owns(request)) return;
        if (isFollowed) followed.add(topic.id);
        if (isHidden) hidden.add(topic.id);
      }
    } catch (failure) {
      if (_catalogueOwner.owns(request)) preferenceError = failure;
    }
    if (_catalogueOwner.owns(request)) {
      restoringPreferences = false;
      _notify();
    }
  }

  Future<void> selectLocale(String newLocale) async {
    if (!availableLocales.any(
      (PublicTopicLocale item) => item.code == newLocale,
    )) {
      throw const FormatException('Choose an available topic-name language.');
    }
    final RequestCancellation request = _namesOwner.begin();
    locale = newLocale;
    localizedNames = const <String, String>{};
    localeError = null;
    loadingNames = newLocale != 'en';
    _notify();
    if (newLocale == 'en') return;
    try {
      final PublicTopicNames names = await repository.names(
        newLocale,
        cancellation: request,
      );
      if (_namesOwner.owns(request)) localizedNames = names.names;
    } on RequestCancelledException {
      return;
    } catch (failure) {
      if (_namesOwner.owns(request)) localeError = failure;
    } finally {
      if (_namesOwner.owns(request)) {
        loadingNames = false;
        _notify();
      }
    }
  }

  Future<void> selectTopic(String id) async {
    if (!(catalogue?.topics.any((PublicTopicSummary item) => item.id == id) ??
        false)) {
      throw const FormatException('Choose an exact published topic id.');
    }
    final RequestCancellation request = _topicOwner.begin();
    selectedTopicId = id;
    selectedTopic = null;
    topicError = null;
    copyError = null;
    copyResult = null;
    loadingTopic = true;
    _notify();
    try {
      final PublicTopic topic = await repository.topic(
        id,
        cancellation: request,
      );
      if (_topicOwner.owns(request)) selectedTopic = topic;
    } on RequestCancelledException {
      return;
    } catch (failure) {
      if (_topicOwner.owns(request)) topicError = failure;
    } finally {
      if (_topicOwner.owns(request)) {
        loadingTopic = false;
        _notify();
      }
    }
  }

  void closeTopic() {
    _topicOwner.cancel();
    selectedTopic = null;
    selectedTopicId = null;
    loadingTopic = false;
    topicError = null;
    _notify();
  }

  Future<void> setFollowed(String id, bool value) =>
      _savePreference(id, value, follow: true);
  Future<void> setHidden(String id, bool value) =>
      _savePreference(id, value, follow: false);

  Future<void> _savePreference(
    String id,
    bool value, {
    required bool follow,
  }) async {
    if (restoringPreferences || savingPreferences.contains(id)) return;
    if (!(catalogue?.topics.any((PublicTopicSummary topic) => topic.id == id) ??
        false)) {
      throw const FormatException('Choose an exact published topic id.');
    }
    savingPreferences.add(id);
    preferenceError = null;
    _notify();
    try {
      final String scope = scopedPublicTopic(repository.sourceScope, id);
      if (follow) {
        await preferences.setTopicFollowed(scope, value);
      } else {
        await preferences.setTopicHidden(scope, value);
      }
      final Set<String> target = follow ? followed : hidden;
      if (value) {
        target.add(id);
      } else {
        target.remove(id);
      }
    } catch (failure) {
      preferenceError = failure;
    } finally {
      savingPreferences.remove(id);
      _notify();
    }
  }

  Future<PublicTopicCopyPreview> previewCopy() async {
    final PublicTopic? topic = selectedTopic;
    final StudyContext? captured = context;
    if (topic == null || captured == null) {
      throw StateError('Choose a loaded topic first.');
    }
    return copyRepository.preview(
      topic: topic,
      sourceScope: repository.sourceScope,
      translation: captured.translation,
    );
  }

  Future<bool> copy(PublicTopicCopyPreview preview) async {
    if (copying) return false;
    copying = true;
    copyError = null;
    _notify();
    try {
      final PublicTopicCopyResult result = await copyRepository.copy(preview);
      if (selectedTopicId == preview.topic.id) copyResult = result;
      return true;
    } catch (failure) {
      if (selectedTopicId == preview.topic.id) copyError = failure;
      return false;
    } finally {
      copying = false;
      _notify();
    }
  }

  void dismiss() {
    _catalogueOwner.cancel();
    _topicOwner.cancel();
    _namesOwner.cancel();
    loading = false;
    loadingTopic = false;
    loadingNames = false;
    restoringPreferences = false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    dismiss();
    super.dispose();
  }
}
