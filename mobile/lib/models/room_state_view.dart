class PlayerView {
  PlayerView({
    required this.userId,
    required this.name,
    required this.score,
    required this.connected,
    required this.isHost,
  });

  final String userId;
  final String name;
  final int score;
  final bool connected;
  final bool isHost;

  factory PlayerView.fromMap(Map<String, dynamic> raw) {
    return PlayerView(
      userId: raw['userId']?.toString() ?? '',
      name: raw['name']?.toString() ?? 'Player',
      score: (raw['score'] as num?)?.toInt() ?? 0,
      connected: raw['connected'] as bool? ?? false,
      isHost: raw['isHost'] as bool? ?? false,
    );
  }
}

class QuestionView {
  QuestionView({
    required this.id,
    required this.prompt,
    required this.points,
  });

  final String id;
  final String prompt;
  final int points;

  factory QuestionView.fromMap(Map<String, dynamic> raw) {
    return QuestionView(
      id: raw['id']?.toString() ?? '',
      prompt: raw['prompt']?.toString() ?? '',
      points: (raw['points'] as num?)?.toInt() ?? 0,
    );
  }
}

class RoomStateView {
  RoomStateView({
    required this.version,
    required this.roomCode,
    required this.visibility,
    required this.status,
    required this.players,
    required this.remainingQuestionIds,
    required this.playedQuestionIds,
    this.currentQuestion,
    this.activeAnswerUserId,
  });

  final int version;
  final String roomCode;
  final String visibility;
  final String status;
  final List<PlayerView> players;
  final List<String> remainingQuestionIds;
  final List<String> playedQuestionIds;
  final QuestionView? currentQuestion;
  final String? activeAnswerUserId;

  bool get isQuestionOpen => status == 'QUESTION_OPEN' || status == 'ANSWERING';

  static Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }

    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }

    return <String, dynamic>{};
  }

  static List<String> _asStringList(dynamic raw) {
    if (raw is List) {
      return raw.map((value) => value.toString()).toList();
    }

    return <String>[];
  }

  factory RoomStateView.fromRoomStatePayload(Map<String, dynamic> payload) {
    final state = _asMap(payload['state']);
    final playersMap = _asMap(state['players']);
    final players = playersMap.values
        .map((item) => PlayerView.fromMap(_asMap(item)))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final game = _asMap(state['game']);
    final board = _asMap(game['board']);
    final currentQuestionRaw = game['currentQuestion'];
    final currentQuestion = currentQuestionRaw == null
        ? null
        : QuestionView.fromMap(_asMap(currentQuestionRaw));

    final answering = _asMap(game['answering']);

    return RoomStateView(
      version: (payload['version'] as num?)?.toInt() ??
          (state['version'] as num?)?.toInt() ??
          0,
      roomCode: state['code']?.toString() ?? '',
      visibility: state['visibility']?.toString() ?? 'PRIVATE',
      status: state['status']?.toString() ?? 'LOBBY',
      players: players,
      remainingQuestionIds: _asStringList(board['remainingQuestionIds']),
      playedQuestionIds: _asStringList(board['playedQuestionIds']),
      currentQuestion: currentQuestion,
      activeAnswerUserId: answering['activeUserId']?.toString(),
    );
  }
}
