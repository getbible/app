import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:provider/provider.dart';

import 'application/app_state.dart';
import 'core/ui_strings.dart';
import 'data/platform/native_reader_links.dart';
import 'domain/models/passage.dart';
import 'presentation/app_bootstrap.dart';
import 'presentation/reader_router.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  runApp(ReaderBootstrap());
}

/// Owns startup resources and captures the launch route before the temporary
/// loading application can report its own root route to the browser.
class ReaderBootstrap extends StatelessWidget {
  ReaderBootstrap({super.key, Future<AppState> Function()? createState})
    : _createState = createState ?? _createDefaultState,
      _launchUri = _captureLaunchUri();

  final Future<AppState> Function() _createState;
  final Uri _launchUri;

  static Future<AppState> _createDefaultState() =>
      AppState.create(initialize: false);

  static Uri _captureLaunchUri() {
    // PathUrlStrategy removes the document's deployment base (for example
    // /flutter/) and preserves the literal query before storage/plugin awaits.
    final location =
        urlStrategy?.getPath() ??
        WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    final uri = Uri.tryParse(location);
    return uri == null
        ? Uri(path: '/invalid-native-link')
        : readerLinkLocation(uri) ?? Uri(path: '/invalid-native-link');
  }

  @override
  Widget build(BuildContext context) => AppBootstrap<_ReaderSession>(
    create: () => _ReaderSession.create(_createState, _launchUri),
    discard: (session) async {
      session.links.dispose();
      await session.state.close();
    },
    builder: (context, session) => ChangeNotifierProvider.value(
      value: session.state,
      child: GetBibleApp(
        initialize: true,
        ownsState: true,
        links: session.links,
        initialUri: session.initialUri,
      ),
    ),
  );
}

final class _ReaderSession {
  const _ReaderSession(this.state, this.links, this.initialUri);
  final AppState state;
  final NativeReaderLinks links;
  final Uri? initialUri;
  static Future<_ReaderSession> create(
    Future<AppState> Function() createState,
    Uri launchUri,
  ) async {
    final links = NativeReaderLinks();
    try {
      final nativeUri = await links.initial();
      final state = await createState();
      return _ReaderSession(
        state,
        links,
        nativeUri == null
            ? launchUri
            : readerLinkLocation(nativeUri) ??
                  Uri(path: '/invalid-native-link'),
      );
    } catch (_) {
      links.dispose();
      rethrow;
    }
  }
}

class GetBibleApp extends StatefulWidget {
  const GetBibleApp({
    super.key,
    this.initialUri,
    this.initialize = false,
    this.ownsState = false,
    this.links,
  });
  final Uri? initialUri;
  final bool initialize;

  /// Injected test/host states retain their caller's explicit lifetime.
  final bool ownsState;
  final NativeReaderLinks? links;

  @override
  State<GetBibleApp> createState() => _GetBibleAppState();
}

class _GetBibleAppState extends State<GetBibleApp> with WidgetsBindingObserver {
  late final ReaderRouter _navigation;
  final GlobalKey<ScaffoldMessengerState> _messenger =
      GlobalKey<ScaffoldMessengerState>();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _navigation = ReaderRouter(
      context.read<AppState>(),
      initialUri: widget.initialUri,
      initialize: widget.initialize,
    );
    widget.links?.addListener(_nativeLink);
    // A warm activation may have arrived while SQLite was opening.
    scheduleMicrotask(_nativeLink);
  }

  void _nativeLink() {
    if (!mounted) return;
    final uri = widget.links?.latest;
    if (uri != null) _navigation.openNative(uri);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.links?.removeListener(_nativeLink);
    widget.links?.dispose();
    _navigation.dispose();
    if (widget.ownsState) {
      unawaited(
        _navigation.state.close().catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              context: ErrorDescription('while closing private reader storage'),
            ),
          );
        }),
      );
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.inactive ||
        lifecycle == AppLifecycleState.paused) {
      unawaited(_flushOnSuspend());
    }
  }

  Future<void> _flushOnSuspend() async {
    try {
      await _navigation.state.study.notebooks.flush();
    } catch (_) {
      /* The retained journal remains owned by its controller. */
    }
    if (mounted && _navigation.state.study.notebooks.hasUndurableDrafts) {
      _showStorageNotice(
        'The latest notebook changes could not be saved. Return to Notebooks and retry before closing.',
      );
    }
  }

  void _showStorageNotice(String message) =>
      _messenger.currentState?.showSnackBar(
        SnackBar(
          content: Text(_navigation.state.ui.text(message)),
          duration: const Duration(seconds: 10),
        ),
      );

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (!widget.ownsState) return AppExitResponse.exit;
    if (_navigation.state.readerNavigationBlocked) {
      _showStorageNotice(
        'Save or close the verse note before closing the application.',
      );
      return AppExitResponse.cancel;
    }
    try {
      await _navigation.state.close();
      return AppExitResponse.exit;
    } catch (_) {
      _showStorageNotice(
        'The latest private changes could not be saved. Retry saving before closing.',
      );
      return AppExitResponse.cancel;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    return MaterialApp.router(
      routerConfig: _navigation.router,
      scaffoldMessengerKey: _messenger,
      title: 'getBible.live',
      locale: state.ui.flutterLocale,
      supportedLocales: UiStrings.supportedLocales
          .map((code) => UiStrings(code, const <String>[]).flutterLocale)
          .where(GlobalMaterialLocalizations.delegate.isSupported)
          .toList(growable: false),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      localeResolutionCallback: (requested, supported) =>
          requested != null &&
              GlobalMaterialLocalizations.delegate.isSupported(requested)
          ? requested
          : const Locale('en'),
      builder: (context, child) => UiStringsScope(
        strings: state.ui,
        child: Directionality(
          textDirection: state.ui.isRtl ? TextDirection.rtl : TextDirection.ltr,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations:
                  state.preferences.reduceMotion ||
                  MediaQuery.disableAnimationsOf(context),
            ),
            child: child!,
          ),
        ),
      ),
      debugShowCheckedModeBanner: false,
      themeMode: switch (state.preferences.appearanceMode) {
        AppearanceMode.system => ThemeMode.system,
        AppearanceMode.light => ThemeMode.light,
        AppearanceMode.dark => ThemeMode.dark,
      },
      theme: _readerTheme(
        state.preferences.lightPalette,
        Brightness.light,
        highContrast: state.preferences.highContrast,
      ),
      darkTheme: _readerTheme(
        state.preferences.darkPalette,
        Brightness.dark,
        highContrast: state.preferences.highContrast,
      ),
      highContrastTheme: _readerTheme(
        state.preferences.lightPalette,
        Brightness.light,
        highContrast: true,
      ),
      highContrastDarkTheme: _readerTheme(
        state.preferences.darkPalette,
        Brightness.dark,
        highContrast: true,
      ),
      themeAnimationDuration: state.preferences.reduceMotion
          ? Duration.zero
          : kThemeAnimationDuration,
    );
  }
}

ThemeData _readerTheme(
  String palette,
  Brightness brightness, {
  bool highContrast = false,
}) {
  final Color background = switch (palette) {
    'paper' => const Color(0xfff6f0e4),
    'ivory' => const Color(0xfffffced),
    'mist' => const Color(0xfff1f5f7),
    'brown' => const Color(0xff211b18),
    'charcoal' => const Color(0xff191b1d),
    'navy' => const Color(0xff111a28),
    'black' => const Color(0xff090909),
    _ => const Color(0xffffffff),
  };
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: brightness == Brightness.dark
        ? const Color(0xff7fc8f8)
        : const Color(0xff276b9c),
    brightness: brightness,
    contrastLevel: highContrast ? 1 : 0,
  ).copyWith(surface: background);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    canvasColor: background,
    useMaterial3: true,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
    ),
  );
}
