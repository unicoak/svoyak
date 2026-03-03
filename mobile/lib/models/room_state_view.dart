class PlayerView {
  PlayerView({
    required this.userId,
    required this.name,
    required this.score,
    required this.connected,
    required this.isHost,
    required this.canBuzz,
  });

  final String userId;
  final String name;
  final int score;
  final bool connected;
  final bool isHost;
  final bool canBuzz;

  factory PlayerView.fromMap(Map<String, dynamic> raw) {
    return PlayerView(
      userId: raw['userId']?.toString() ?? '',
      name: raw['name']?.toString() ?? 'Player',
      score: (raw['score'] as num?)?.toInt() ?? 0,
      connected: raw['connected'] as bool? ?? false,
      isHost: raw['isHost'] as bool? ?? false,
      canBuzz: raw['canBuzz'] as bool? ?? false,
    );
  }
}

class QuestionView {
  QuestionView({
    required this.id,
    required this.roundNo,
    required this.boardRow,
    required this.boardCol,
    required this.prompt,
    required this.answerDisplay,
    required this.answerComment,
    required this.points,
    required this.revealDurationMs,
    required this.revealedMs,
    required this.revealResumedAtServerMs,
  });

  final String id;
  final int roundNo;
  final int boardRow;
  final int boardCol;
  final String prompt;
  final String answerDisplay;
  final String answerComment;
  final int points;
  final int revealDurationMs;
  final int revealedMs;
  final int? revealResumedAtServerMs;

  factory QuestionView.fromMap(Map<String, dynamic> raw) {
    final int fallbackRevealDurationMs =
        (((raw['prompt']?.toString() ?? '').length * 34).clamp(1800, 9000))
            .toInt();
    return QuestionView(
      id: raw['id']?.toString() ?? '',
      roundNo: (raw['roundNo'] as num?)?.toInt() ?? 1,
      boardRow: (raw['boardRow'] as num?)?.toInt() ?? 0,
      boardCol: (raw['boardCol'] as num?)?.toInt() ?? 0,
      prompt: raw['prompt']?.toString() ?? '',
      answerDisplay: raw['answerDisplay']?.toString() ?? '',
      answerComment: raw['answerComment']?.toString() ?? '',
      points: (raw['points'] as num?)?.toInt() ?? 0,
      revealDurationMs: (raw['revealDurationMs'] as num?)?.toInt() ??
          fallbackRevealDurationMs,
      revealedMs: (raw['revealedMs'] as num?)?.toInt() ?? 0,
      revealResumedAtServerMs:
          (raw['revealResumedAtServerMs'] as num?)?.toInt(),
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
    this.answerDeadlineServerMs,
    this.readStartedAtServerMs,
    this.readEndsAtServerMs,
    this.buzzOpenAtServerMs,
    this.buzzCloseAtServerMs,
    this.autoNextQuestionAtServerMs,
    this.buzzWindowMs = 7000,
    this.allowFalseStarts = true,
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
  final int? answerDeadlineServerMs;
  final int? readStartedAtServerMs;
  final int? readEndsAtServerMs;
  final int? buzzOpenAtServerMs;
  final int? buzzCloseAtServerMs;
  final int? autoNextQuestionAtServerMs;
  final int buzzWindowMs;
  final bool allowFalseStarts;

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
    final settings = _asMap(state['settings']);
    final buzzer = _asMap(game['buzzer']);
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
      answerDeadlineServerMs: (answering['deadlineServerMs'] as num?)?.toInt(),
      readStartedAtServerMs: (buzzer['readStartedAtServerMs'] as num?)?.toInt(),
      readEndsAtServerMs: (buzzer['readEndsAtServerMs'] as num?)?.toInt(),
      buzzOpenAtServerMs: (buzzer['openAtServerMs'] as num?)?.toInt(),
      buzzCloseAtServerMs: (buzzer['closeAtServerMs'] as num?)?.toInt(),
      autoNextQuestionAtServerMs:
          (game['autoNextQuestionAtServerMs'] as num?)?.toInt(),
      buzzWindowMs: (settings['buzzWindowMs'] as num?)?.toInt() ?? 7000,
      allowFalseStarts: settings['allowFalseStarts'] as bool? ?? true,
    );
  }
}
