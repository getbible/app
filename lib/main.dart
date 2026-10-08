import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'application/app_state.dart';
import 'presentation/reader_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final AppState state = await AppState.create();
  runApp(
    ChangeNotifierProvider.value(value: state, child: const GetBibleApp()),
  );
}

class GetBibleApp extends StatelessWidget {
  const GetBibleApp({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    return MaterialApp(
      title: 'getBible.live',
      locale: Locale(state.ui.locale),
      debugShowCheckedModeBanner: false,
      themeMode: switch (state.preferences.appearanceMode) {
        AppearanceMode.system => ThemeMode.system,
        AppearanceMode.light => ThemeMode.light,
        AppearanceMode.dark => ThemeMode.dark,
      },
      theme: _readerTheme(state.preferences.lightPalette, Brightness.light),
      darkTheme: _readerTheme(state.preferences.darkPalette, Brightness.dark),
      home: Directionality(
        textDirection: state.isUiRtl ? TextDirection.rtl : TextDirection.ltr,
        child: const ReaderScreen(),
      ),
    );
  }
}

ThemeData _readerTheme(String palette, Brightness brightness) {
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
