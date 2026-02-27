import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/public_room_view.dart';
import '../models/room_state_view.dart';
import '../models/socket_event.dart';
import 'app_config.dart';
import 'game_socket_service.dart';
import 'time_sync_service.dart';

class GameController extends ChangeNotifier {
  GameController({
    GameSocketService? socketService,
  }) : _socketService = socketService ?? GameSocketService(AppConfig.backendUrl);

  final GameSocketService _socketService;
  final TimeSyncService _timeSyncService = TimeSyncService();
  final Map<String, int> _pendingTimeSamples = <String, int>{};
  final List<String> _logs = <String>[];

  final String _userId = const Uuid().v4();

  StreamSubscription<SocketEventEnvelope>? _eventsSubscription;

  bool isBusy = false;
  bool isConnected = false;
  String statusMessage = 'Disconnected';
  String createRoomVisibility = 'PRIVATE';

  String? roomCode;
  String? selfUserId;
  String? reconnectToken;
  RoomStateView? roomState;
  List<PublicRoomView> publicRooms = <PublicRoomView>[];
  DateTime? publicRoomsUpdatedAt;

  List<String> get logs => List<String>.unmodifiable(_logs);
  int get offsetMs => _timeSyncService.offsetMs;
  int get rttMs => _timeSyncService.rttMs;

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
    }, errorPrefix: 'Connection failed');
  }

  Future<void> createRoom({
    required String packageId,
    required String displayName,
    String? visibility,
  }) async {
    await _runAction(() async {
      await ensureConnected(displayName);
      await _socketService.createRoom(
        packageId: packageId,
        displayName: displayName,
        visibility: visibility ?? createRoomVisibility,
      );
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
      statusMessage = 'Public rooms refresh failed: $error';
      _appendLog(statusMessage);
    } finally {
      isBusy = false;
      notifyListeners();
    }
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
      await _socketService.selectQuestion(roomCode: code, questionId: questionId);
      _appendLog('select_question sent: $questionId');
    }, errorPrefix: 'Select question failed');
  }

  Future<void> buzz() async {
    final code = roomCode;
    final currentQuestionId = roomState?.currentQuestion?.id;
    if (code == null || currentQuestionId == null || currentQuestionId.isEmpty) {
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
      _appendLog('buzz_attempt sent (offset=$offsetMs, rtt=${rttMs == 0 ? 120 : rttMs})');
    }, errorPrefix: 'Buzz failed');
  }

  Future<void> submitAnswer(String answerText) async {
    final code = roomCode;
    final currentQuestionId = roomState?.currentQuestion?.id;

    if (code == null || currentQuestionId == null || answerText.trim().isEmpty) {
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

  Future<void> syncTime() async {
    if (!_socketService.isConnected) {
      return;
    }

    final sampleId = DateTime.now().microsecondsSinceEpoch.toString();
    final t0ClientMs = DateTime.now().millisecondsSinceEpoch;
    _pendingTimeSamples[sampleId] = t0ClientMs;

    await _runAction(() async {
      await _socketService.syncTime(sampleId: sampleId, t0ClientMs: t0ClientMs);
      _appendLog('sync_time sent ($sampleId)');
    }, errorPrefix: 'Time sync failed', notify: false);
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
      _appendLog('leave_room sent');
    }, errorPrefix: 'Leave room failed');
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
      statusMessage = '$errorPrefix: $error';
      _appendLog(statusMessage);
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
        statusMessage = 'Socket connected';
        _appendLog('Socket connected');
        break;
      case 'disconnect':
        isConnected = false;
        statusMessage = 'Socket disconnected';
        _appendLog('Socket disconnected: ${envelope.payload}');
        break;
      case 'room_joined':
        final roomStateRaw = _asMap(payload['state']);
        roomCode = payload['roomCode']?.toString() ?? roomCode;
        selfUserId = payload['selfUserId']?.toString() ?? selfUserId;
        reconnectToken = payload['reconnectToken']?.toString() ?? reconnectToken;
        roomState = RoomStateView.fromRoomStatePayload(<String, dynamic>{
          'state': roomStateRaw,
          'version': roomStateRaw['version'],
        });
        _appendLog('Joined room: $roomCode');
        break;
      case 'room_state':
        roomState = RoomStateView.fromRoomStatePayload(payload);
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
            _appendLog('Clock sync updated: offset=$offsetMs, rtt=$rttMs');
          }
        }
        break;
      case 'question_opened':
      case 'buzz_locked':
      case 'answer_result':
      case 'question_closed':
      case 'host_migrated':
      case 'player_presence':
        _appendLog('${envelope.event}: $payload');
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

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    _socketService.dispose();
    super.dispose();
  }
}
