import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/public_room_view.dart';
import '../models/quiz_package_view.dart';
import '../models/room_state_view.dart';
import '../models/socket_event.dart';
import 'app_config.dart';
import 'game_socket_service.dart';
import 'time_sync_service.dart';

class GameController extends ChangeNotifier {
  GameController({
    required String userId,
    GameSocketService? socketService,
  })  : _userId = userId,
        _socketService =
            socketService ?? GameSocketService(AppConfig.backendUrl);

  final GameSocketService _socketService;
  final TimeSyncService _timeSyncService = TimeSyncService();
  final Map<String, int> _pendingTimeSamples = <String, int>{};
  final List<String> _logs = <String>[];

  final String _userId;

  StreamSubscription<SocketEventEnvelope>? _eventsSubscription;
  Timer? _syncTicker;
  Timer? _heartbeatTicker;

  bool isBusy = false;
  bool isConnected = false;
  String statusMessage = 'Disconnected';
  String createRoomVisibility = 'PRIVATE';
  bool createRoomAllowFalseStarts = true;
  String? flashMessage;
  int _flashMessageVersion = 0;
  String _lastDraftSent = '';
  String? _lastDraftQuestionId;

  String? roomCode;
  String? selfUserId;
  String? reconnectToken;
  RoomStateView? roomState;
  List<PublicRoomView> publicRooms = <PublicRoomView>[];
  List<QuizPackageView> availablePackages = <QuizPackageView>[];
  DateTime? publicRoomsUpdatedAt;
  DateTime? packagesUpdatedAt;
  String? selectedPackageId;

  List<String> get logs => List<String>.unmodifiable(_logs);
  int get offsetMs => _timeSyncService.offsetMs;
  int get rttMs => _timeSyncService.rttMs;
  int get flashMessageVersion => _flashMessageVersion;

  bool get isHost {
    final me = _currentPlayer();
    return me?.isHost ?? false;
  }

  Future<void> ensureConnected(String displayName) async {
    _eventsSubscription ??= _socketService.events.listen(_onSocketEvent);

    if (_socketService.isConnected) {
      isConnected = true;
      statusMessage = 'Connected';
      notifyListeners();
      return;
    }

    await _runAction(() async {
      await _socketService.connect(userId: _userId, displayName: displayName);
      isConnected = true;
      statusMessage = 'Connected as $displayName';
      _appendLog('Socket connected');
      await syncTime();
      _startRoomTelemetryLoops();
    }, errorPrefix: 'Connection failed');
  }

  Future<void> createRoom({
    required String packageId,
    required String displayName,
    String? visibility,
  }) async {
    await _runAction(() async {
      await ensureConnected(displayName);
      final data = await _socketService.createRoom(
        packageId: packageId,
        displayName: displayName,
        visibility: visibility ?? createRoomVisibility,
        allowFalseStarts: createRoomAllowFalseStarts,
      );
      final String resolvedPackageId =
          data['packageId']?.toString() ?? packageId;
      selectedPackageId = resolvedPackageId;
      _appendLog('create_room package: $resolvedPackageId');
      _appendLog('create_room sent');
    }, errorPrefix: 'Create room failed');
  }

  Future<void> joinRoom({
    required String roomCode,
    required String displayName,
  }) async {
    await _runAction(() async {
      await ensureConnected(displayName);
      await _socketService.joinRoom(
        roomCode: roomCode,
        displayName: displayName,
        reconnectToken: reconnectToken,
      );
      _appendLog('join_room sent: ${roomCode.toUpperCase()}');
    }, errorPrefix: 'Join room failed');
  }

  void setCreateRoomVisibility(String visibility) {
    if (visibility != 'PUBLIC' && visibility != 'PRIVATE') {
      return;
    }
    createRoomVisibility = visibility;
    notifyListeners();
  }

  void setCreateRoomAllowFalseStarts(bool allow) {
    createRoomAllowFalseStarts = allow;
    notifyListeners();
  }

  Future<void> refreshPublicRooms({int limit = 20}) async {
    isBusy = true;
    notifyListeners();

    try {
      _eventsSubscription ??= _socketService.events.listen(_onSocketEvent);

      if (!_socketService.isConnected) {
        await _socketService.connect(
          userId: _userId,
          displayName: _displayNameOrDefault(),
        );
      }

      final data = await _socketService.listPublicRooms(limit: limit);
      final roomsRaw = data['rooms'];

      if (roomsRaw is List) {
        publicRooms = roomsRaw
            .map((dynamic room) => PublicRoomView.fromMap(_asMap(room)))
            .toList();
      } else {
        publicRooms = <PublicRoomView>[];
      }

      publicRoomsUpdatedAt = DateTime.now();
      statusMessage = 'Public rooms loaded';
      _appendLog('public rooms updated: ${publicRooms.length}');
    } catch (error) {
      final String userMessage = _friendlyErrorMessage(
        error,
        fallbackPrefix: 'Public rooms refresh failed',
      );
      statusMessage = userMessage;
      _appendLog('Public rooms refresh failed: $error');
      _pushFlash(userMessage);
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<void> refreshPackages({
    String? query,
    int? difficulty,
    int limit = 20,
  }) async {
    isBusy = true;
    notifyListeners();

    try {
      _eventsSubscription ??= _socketService.events.listen(_onSocketEvent);

      if (!_socketService.isConnected) {
        await _socketService.connect(
          userId: _userId,
          displayName: _displayNameOrDefault(),
        );
      }

      final data = await _socketService.listPackages(
        query: query,
        difficulty: difficulty,
        limit: limit,
      );
      final packagesRaw = data['packages'];

      if (packagesRaw is List) {
        availablePackages = packagesRaw
            .map((dynamic item) => QuizPackageView.fromMap(_asMap(item)))
            .where((QuizPackageView item) => item.id.isNotEmpty)
            .toList();
      } else {
        availablePackages = <QuizPackageView>[];
      }

      if (availablePackages.isEmpty) {
        selectedPackageId = null;
      } else if (selectedPackageId == null ||
          !availablePackages
              .any((QuizPackageView item) => item.id == selectedPackageId)) {
        selectedPackageId = availablePackages.first.id;
      }

      packagesUpdatedAt = DateTime.now();
      statusMessage = 'Packages loaded';
      _appendLog('packages updated: ${availablePackages.length}');
    } catch (error) {
      final String userMessage = _friendlyErrorMessage(
        error,
        fallbackPrefix: 'Packages refresh failed',
      );
      statusMessage = userMessage;
      _appendLog('Packages refresh failed: $error');
      _pushFlash(userMessage);
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  void setSelectedPackage(String packageId) {
    selectedPackageId = packageId;
    notifyListeners();
  }

  Future<void> joinPublicRoom({
    required String roomCode,
    required String displayName,
  }) async {
    await joinRoom(roomCode: roomCode, displayName: displayName);
  }

  Future<void> startGame() async {
    final code = roomCode;
    if (code == null || code.isEmpty) {
      return;
    }

    await _runAction(() async {
      await _socketService.startGame(code);
      _appendLog('start_game sent');
    }, errorPrefix: 'Start game failed');
  }

  Future<void> selectQuestion(String questionId) async {
    final code = roomCode;
    if (code == null || code.isEmpty || questionId.isEmpty) {
      return;
    }

    await _runAction(() async {
      await _socketService.selectQuestion(
          roomCode: code, questionId: questionId);
      _appendLog('select_question sent: $questionId');
    }, errorPrefix: 'Select question failed');
  }

  Future<void> selectNextQuestion() async {
    final List<String> remaining =
        roomState?.remainingQuestionIds ?? <String>[];
    if (remaining.isEmpty) {
      return;
    }

    await selectQuestion(remaining.first);
  }

  Future<void> buzz() async {
    final code = roomCode;
    final currentQuestionId = roomState?.currentQuestion?.id;
    if (code == null ||
        currentQuestionId == null ||
        currentQuestionId.isEmpty) {
      return;
    }

    final pressClientMs = DateTime.now().millisecondsSinceEpoch;

    await _runAction(() async {
      await _socketService.buzzAttempt(
        roomCode: code,
        questionId: currentQuestionId,
        pressClientMs: pressClientMs,
        offsetMs: offsetMs,
        rttMs: rttMs == 0 ? 120 : rttMs,
      );
      _appendLog(
          'buzz_attempt sent (offset=$offsetMs, rtt=${rttMs == 0 ? 120 : rttMs})');
    }, errorPrefix: 'Buzz failed');
  }

  Future<void> submitAnswer(String answerText) async {
    final code = roomCode;
    final currentQuestionId = roomState?.currentQuestion?.id;

    if (code == null ||
        currentQuestionId == null ||
        answerText.trim().isEmpty) {
      return;
    }

    await _runAction(() async {
      await _socketService.submitAnswer(
        roomCode: code,
        questionId: currentQuestionId,
        answerText: answerText,
      );
      _appendLog('answer_submitted sent');
    }, errorPrefix: 'Submit answer failed');
  }

  void updateAnswerDraft(String answerText) {
    final code = roomCode;
    final currentQuestionId = roomState?.currentQuestion?.id;
    if (code == null || currentQuestionId == null || currentQuestionId.isEmpty) {
      return;
    }

    final bool isMyAnsweringTurn = roomState?.status == 'ANSWERING' &&
        roomState?.activeAnswerUserId == selfUserId;
    if (!isMyAnsweringTurn) {
      return;
    }

    final String normalized = answerText.trim();
    if (_lastDraftQuestionId == currentQuestionId && _lastDraftSent == normalized) {
      return;
    }
    _lastDraftQuestionId = currentQuestionId;
    _lastDraftSent = normalized;

    _socketService.emitAnswerDraft(
      roomCode: code,
      questionId: currentQuestionId,
      answerText: normalized,
    );
  }

  Future<void> syncTime() async {
    if (!_socketService.isConnected) {
      return;
    }

    final sampleId = DateTime.now().microsecondsSinceEpoch.toString();
    final t0ClientMs = DateTime.now().millisecondsSinceEpoch;
    _pendingTimeSamples[sampleId] = t0ClientMs;

    try {
      await _socketService.syncTime(sampleId: sampleId, t0ClientMs: t0ClientMs);
    } catch (error) {
      _appendLog('sync_time failed: $error');
    }
  }

  Future<void> leaveRoom() async {
    final code = roomCode;
    if (code == null || code.isEmpty) {
      return;
    }

    await _runAction(() async {
      await _socketService.leaveRoom(code);
      roomCode = null;
      roomState = null;
      _lastDraftQuestionId = null;
      _lastDraftSent = '';
      _stopRoomTelemetryLoops();
      _appendLog('leave_room sent');
    }, errorPrefix: 'Leave room failed');
  }

  Future<void> sendHeartbeat() async {
    final code = roomCode;
    if (code == null || !_socketService.isConnected) {
      return;
    }

    try {
      await _socketService.heartbeat(
        roomCode: code,
        clientNowMs: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (error) {
      _appendLog('heartbeat failed: $error');
    }
  }

  Future<void> _pushSyncMetricsToServer({String? sampleId}) async {
    final code = roomCode;
    if (code == null || !_socketService.isConnected) {
      return;
    }

    try {
      await _socketService.syncTimeMetrics(
        roomCode: code,
        offsetMs: offsetMs,
        rttMs: rttMs == 0 ? 120 : rttMs,
        sampleId: sampleId,
      );
    } catch (error) {
      _appendLog('sync_time_metrics failed: $error');
    }
  }

  void _startRoomTelemetryLoops() {
    if (!_socketService.isConnected || roomCode == null) {
      return;
    }

    _stopRoomTelemetryLoops();
    _syncTicker = Timer.periodic(const Duration(seconds: 12), (_) {
      unawaited(syncTime());
    });
    _heartbeatTicker = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(sendHeartbeat());
    });
  }

  void _stopRoomTelemetryLoops() {
    _syncTicker?.cancel();
    _heartbeatTicker?.cancel();
    _syncTicker = null;
    _heartbeatTicker = null;
  }

  String _displayNameOrDefault() {
    final fallback = 'Player-${_userId.substring(0, 6)}';
    final currentSelfUserId = selfUserId;
    if (currentSelfUserId == null) {
      return fallback;
    }

    for (final player in roomState?.players ?? <PlayerView>[]) {
      if (player.userId == currentSelfUserId && player.name.trim().isNotEmpty) {
        return player.name.trim();
      }
    }

    return fallback;
  }

  PlayerView? _currentPlayer() {
    final currentSelfUserId = selfUserId;
    if (currentSelfUserId == null) {
      return null;
    }

    for (final player in roomState?.players ?? <PlayerView>[]) {
      if (player.userId == currentSelfUserId) {
        return player;
      }
    }

    return null;
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    required String errorPrefix,
    bool notify = true,
  }) async {
    isBusy = true;
    if (notify) {
      notifyListeners();
    }

    try {
      await action();
      statusMessage = 'OK';
    } catch (error) {
      final String userMessage = _friendlyErrorMessage(
        error,
        fallbackPrefix: errorPrefix,
      );
      statusMessage = userMessage;
      _appendLog('$errorPrefix: $error');
      _pushFlash(userMessage);
    } finally {
      isBusy = false;
      if (notify) {
        notifyListeners();
      }
    }
  }

  void _onSocketEvent(SocketEventEnvelope envelope) {
    final payload = _asMap(envelope.payload);

    switch (envelope.event) {
      case 'connect':
        isConnected = true;
        statusMessage = 'Соединение установлено';
        _appendLog('Socket connected');
        _startRoomTelemetryLoops();
        break;
      case 'disconnect':
        isConnected = false;
        statusMessage = 'Соединение потеряно';
        _stopRoomTelemetryLoops();
        _appendLog('Socket disconnected: ${envelope.payload}');
        break;
      case 'room_joined':
        final roomStateRaw = _asMap(payload['state']);
        roomCode = payload['roomCode']?.toString() ?? roomCode;
        selfUserId = payload['selfUserId']?.toString() ?? selfUserId;
        reconnectToken =
            payload['reconnectToken']?.toString() ?? reconnectToken;
        roomState = RoomStateView.fromRoomStatePayload(<String, dynamic>{
          'state': roomStateRaw,
          'version': roomStateRaw['version'],
        });
        _lastDraftQuestionId = null;
        _lastDraftSent = '';
        _startRoomTelemetryLoops();
        unawaited(syncTime());
        _appendLog('Joined room: $roomCode');
        break;
      case 'room_state':
        roomState = RoomStateView.fromRoomStatePayload(payload);
        if (roomState?.status != 'ANSWERING') {
          _lastDraftQuestionId = null;
          _lastDraftSent = '';
        }
        break;
      case 'time_sync':
        final sampleId = payload['sampleId']?.toString();
        if (sampleId != null && _pendingTimeSamples.containsKey(sampleId)) {
          final t0 = _pendingTimeSamples.remove(sampleId)!;
          final t1 = (payload['t1ServerRecvMs'] as num?)?.toInt();
          final t2 = (payload['t2ServerSendMs'] as num?)?.toInt();
          final t3 = DateTime.now().millisecondsSinceEpoch;

          if (t1 != null && t2 != null) {
            _timeSyncService.addSample(
              t0ClientSendMs: t0,
              t1ServerRecvMs: t1,
              t2ServerSendMs: t2,
              t3ClientRecvMs: t3,
            );
            unawaited(_pushSyncMetricsToServer(sampleId: sampleId));
            _appendLog('Clock sync updated: offset=$offsetMs, rtt=$rttMs');
          }
        }
        break;
      case 'question_opened':
      case 'buzzer_window_opened':
      case 'buzz_locked':
      case 'player_presence':
        _appendLog('${envelope.event}: $payload');
        break;
      case 'answer_result':
        _appendLog('answer_result: $payload');
        final String? resultUserId = payload['userId']?.toString();
        if (resultUserId == selfUserId) {
          final bool isCorrect = payload['isCorrect'] == true;
          final bool timedOut = payload['timedOut'] == true;
          final int scoreDelta = (payload['scoreDelta'] as num?)?.toInt() ?? 0;
          final String message;
          if (timedOut && isCorrect) {
            message = 'Время вышло, введённый ответ засчитан: +$scoreDelta';
          } else if (timedOut) {
            message = 'Время вышло: $scoreDelta очков.';
          } else if (isCorrect) {
            message = 'Верно! +$scoreDelta';
          } else {
            message = 'Неверно: $scoreDelta';
          }
          statusMessage = message;
          _pushFlash(message);
        }
        break;
      case 'question_closed':
        _appendLog('question_closed: $payload');
        break;
      case 'host_migrated':
        _appendLog('host_migrated: $payload');
        final String? newHostUserId = payload['newHostUserId']?.toString();
        if (newHostUserId != null && newHostUserId == selfUserId) {
          const String message = 'Ты теперь ведущий комнаты.';
          statusMessage = message;
          _pushFlash(message);
        }
        break;
      case 'buzz_rejected':
        final String reason = payload['reason']?.toString() ?? 'BUZZ_REJECTED';
        final String message = _friendlyBuzzRejectReason(reason);
        statusMessage = message;
        _pushFlash(message);
        _appendLog('buzz_rejected: $payload');
        break;
      case 'error':
        final message = payload['message']?.toString() ?? 'Server error';
        statusMessage = 'Server error: $message';
        _appendLog(statusMessage);
        break;
      default:
        break;
    }

    notifyListeners();
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      return raw;
    }

    if (raw is Map) {
      return raw.map((dynamic key, dynamic value) =>
          MapEntry<String, dynamic>(key.toString(), value));
    }

    return <String, dynamic>{};
  }

  void _appendLog(String line) {
    _logs.insert(0, '${DateTime.now().toIso8601String()} | $line');
    if (_logs.length > 80) {
      _logs.removeRange(80, _logs.length);
    }
  }

  void _pushFlash(String message) {
    flashMessage = message;
    _flashMessageVersion += 1;
  }

  String _friendlyErrorMessage(
    Object error, {
    required String fallbackPrefix,
  }) {
    if (error is SocketAckException) {
      return _friendlyAckCode(error.code);
    }

    if (error is SocketConnectionException) {
      return 'Нет соединения с сервером. Проверь интернет и адрес backend.';
    }

    if (error is TimeoutException) {
      return 'Сервер не отвечает. Попробуй ещё раз через пару секунд.';
    }

    if (error is StateError) {
      return 'Проблема с подключением к серверу.';
    }

    return '$fallbackPrefix: $error';
  }

  String _friendlyAckCode(String code) {
    switch (code) {
      case 'PACKAGE_NOT_FOUND':
        return 'Пакет вопросов не найден на сервере.';
      case 'INVALID_PACKAGE_STRUCTURE':
        return 'Пакет не подходит по формату игры.';
      case 'EMPTY_PACKAGE':
        return 'В выбранном пакете нет вопросов.';
      case 'ROOM_NOT_FOUND':
        return 'Комната не найдена.';
      case 'ROOM_FULL':
        return 'Комната уже заполнена.';
      case 'HOST_ONLY':
        return 'Это действие доступно только ведущему.';
      case 'INVALID_ROOM_STATUS':
        return 'Сейчас это действие недоступно.';
      case 'OUT_OF_ORDER_QUESTION':
        return 'Вопросы играются строго по порядку.';
      case 'FALSE_START':
        return 'Фальстарт: ты заблокирован на этот вопрос.';
      case 'TOO_EARLY':
        return 'Слишком рано. Вопрос ещё читается.';
      case 'BUZZ_WINDOW_CLOSED':
        return 'Время на кнопку уже вышло.';
      case 'LOCKED_OUT':
        return 'Ты не можешь нажимать кнопку на этом вопросе.';
      case 'DUPLICATE_BUZZ':
        return 'Попытка уже засчитана.';
      case 'QUESTION_MISMATCH':
        return 'Неверный вопрос в запросе.';
      case 'NOT_ACTIVE_ANSWERER':
        return 'Сейчас отвечает другой игрок.';
      default:
        return 'Ошибка: $code';
    }
  }

  String _friendlyBuzzRejectReason(String reason) {
    return _friendlyAckCode(reason);
  }

  @override
  void dispose() {
    _stopRoomTelemetryLoops();
    _eventsSubscription?.cancel();
    _socketService.dispose();
    super.dispose();
  }
}
