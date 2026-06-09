// Заглушка для платформ без dart:io (web). Настоящая реализация лежит в
// posthog_flutter_dart.dart и подключается условным экспортом, когда доступна
// dart.library.io (desktop/mobile). На web используется PosthogFlutterWeb,
// поэтому здесь нужен только класс-символ, чтобы баррел компилировался.
class PosthogFlutterDart {
  static void registerWith() {}
}
