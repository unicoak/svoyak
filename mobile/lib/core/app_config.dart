class AppConfig {
  static const String backendUrl =
      String.fromEnvironment('BACKEND_URL', defaultValue: 'http://localhost:3000');
}
