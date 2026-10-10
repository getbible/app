{{flutter_js}}
{{flutter_build_config}}

// The verified app shell owns service-worker registration. Flutter's generated
// offline-first worker must not compete for the same deployment scope.
_flutter.loader.load();
