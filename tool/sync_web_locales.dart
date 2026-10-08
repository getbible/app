import 'dart:io';

/// Copies the compact UI locale contract from a sibling checkout of
/// getbible/app.getbible.life. Run from this repository's root:
///
///   dart run tool/sync_web_locales.dart ../app.getbible.life
void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/sync_web_locales.dart <web-repository>',
    );
    exitCode = 64;
    return;
  }
  final Directory source = Directory('${arguments.single}/public/locales');
  final Directory target = Directory('assets/locales');
  if (!source.existsSync()) {
    stderr.writeln('Locale source does not exist: ${source.path}');
    exitCode = 66;
    return;
  }
  target.createSync(recursive: true);
  final List<File> files =
      source
          .listSync()
          .whereType<File>()
          .where((File file) => file.path.endsWith('.json'))
          .toList()
        ..sort((File left, File right) => left.path.compareTo(right.path));
  for (final File file in files) {
    final String name = file.uri.pathSegments.last;
    file.copySync('${target.path}/$name');
  }
  stdout.writeln('Copied ${files.length} locale contract files.');
}
