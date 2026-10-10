import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/ui_strings.dart';

/// Renders startup while opening local data, with a non-destructive retry when
/// platform storage or database migration is unavailable.
///
/// [create] must close any partially opened resource when it throws. Once
/// [builder] receives a resource, the application owns its normal shutdown.
/// [discard] closes a successfully created resource when this startup surface
/// was removed before the asynchronous open completed.
class AppBootstrap<T extends Object> extends StatefulWidget {
  const AppBootstrap({
    super.key,
    required this.create,
    required this.discard,
    required this.builder,
  });

  final Future<T> Function() create;
  final Future<void> Function(T resource) discard;
  final Widget Function(BuildContext context, T resource) builder;

  @override
  State<AppBootstrap<T>> createState() => _AppBootstrapState<T>();
}

class _AppBootstrapState<T extends Object> extends State<AppBootstrap<T>> {
  T? _resource;
  bool _opening = true;
  bool _failed = false;
  UiStrings _ui = UiStrings.english;

  @override
  void initState() {
    super.initState();
    unawaited(_loadUi());
    unawaited(_open());
  }

  Future<void> _loadUi() async {
    final strings = await UiStrings.load(
      WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag(),
    );
    if (mounted) setState(() => _ui = strings);
  }

  Future<void> _open() async {
    // The retry control disappears during opening. This additional guard also
    // protects against repeated activation before the next frame is painted.
    if (_resource != null || (!_failed && !_opening)) return;
    _failed = false;
    final create = widget.create;
    final discard = widget.discard;
    try {
      final resource = await create();
      if (!mounted) {
        await discard(resource);
        return;
      }
      setState(() {
        _resource = resource;
        _opening = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _failed = true;
      });
    }
  }

  void _retry() {
    if (_opening) return;
    setState(() => _opening = true);
    unawaited(_open());
  }

  @override
  Widget build(BuildContext context) {
    final resource = _resource;
    if (resource != null) return widget.builder(context, resource);
    final locale = _ui.flutterLocale;
    return MaterialApp(
      title: 'getBible.live',
      debugShowCheckedModeBanner: false,
      locale: GlobalMaterialLocalizations.delegate.isSupported(locale)
          ? locale
          : const Locale('en'),
      supportedLocales: GlobalMaterialLocalizations.delegate.isSupported(locale)
          ? [locale]
          : const [Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // The temporary loading/error surface must not create a Navigator or
      // consume the platform's launch route before the ready application does.
      builder: (context, _) => Directionality(
        textDirection: _ui.isRtl ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Image.asset(
                        'assets/branding/getbible_book.png',
                        height: 80,
                        excludeFromSemantics: true,
                      ),
                      const SizedBox(height: 24),
                      if (_opening) ...[
                        const Center(child: CircularProgressIndicator()),
                        const SizedBox(height: 16),
                        Text(
                          _ui.text('Opening local data'),
                          textAlign: TextAlign.center,
                        ),
                      ] else ...[
                        Semantics(
                          header: true,
                          liveRegion: true,
                          child: Text(
                            _ui.text('Local storage is unavailable'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _ui.text(
                            'The app could not open its local data. Check available storage and browser permissions, then retry. Do not clear site data to fix this error.',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(_ui.text('Your saved data has not been reset.')),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          autofocus: true,
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh),
                          label: Text(_ui.text('Retry')),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
