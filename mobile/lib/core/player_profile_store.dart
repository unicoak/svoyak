import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class PlayerProfile {
  PlayerProfile({
    required this.userId,
    required this.nickname,
    required this.experience,
    required this.rating,
  });

  final String userId;
  final String nickname;
  final int experience;
  final int rating;
}

class PlayerProfileStore {
  static const String _userIdKey = 'profile.user_id';
  static const String _nicknameKey = 'profile.nickname';
  static const String _experienceKey = 'profile.experience';
  static const String _ratingKey = 'profile.rating';

  Future<PlayerProfile?> loadProfile() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    final String? userId = prefs.getString(_userIdKey);
    final String? nickname = prefs.getString(_nicknameKey);

    if (userId == null ||
        userId.isEmpty ||
        nickname == null ||
        nickname.isEmpty) {
      return null;
    }

    return PlayerProfile(
      userId: userId,
      nickname: nickname,
      experience: prefs.getInt(_experienceKey) ?? 0,
      rating: prefs.getInt(_ratingKey) ?? 1000,
    );
  }

  Future<PlayerProfile> registerProfile({
    required String nickname,
  }) async {
    final String normalizedNickname = nickname.trim();
    if (normalizedNickname.isEmpty) {
      throw ArgumentError('Nickname must not be empty');
    }

    final PlayerProfile profile = PlayerProfile(
      userId: const Uuid().v4(),
      nickname: normalizedNickname,
      experience: 0,
      rating: 1000,
    );

    await saveProfile(profile);
    return profile;
  }

  Future<void> saveProfile(PlayerProfile profile) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userIdKey, profile.userId);
    await prefs.setString(_nicknameKey, profile.nickname);
    await prefs.setInt(_experienceKey, profile.experience);
    await prefs.setInt(_ratingKey, profile.rating);
  }

  Future<void> clearProfile() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userIdKey);
    await prefs.remove(_nicknameKey);
    await prefs.remove(_experienceKey);
    await prefs.remove(_ratingKey);
  }
}
