class AppConfig {
  static const String _defaultProductionBackendUrl =
      'https://unicoak-svoyak-eccc.twc1.net';
  static const String _configuredBackendUrl =
      String.fromEnvironment('BACKEND_URL', defaultValue: '');

  static String get backendUrl {
    final String configured = _configuredBackendUrl.trim();
    if (configured.isNotEmpty) {
      return configured;
    }

    return _defaultProductionBackendUrl;
  }
}
