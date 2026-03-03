import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import '../models/socket_event.dart';

class SocketAckException implements Exception {
  SocketAckException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'SocketAckException($code): $message';
}

class SocketConnectionException implements Exception {
  SocketConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GameSocketService {
  GameSocketService(this.serverUrl);

  final String serverUrl;
  final StreamController<SocketEventEnvelope> _eventsController =
      StreamController<SocketEventEnvelope>.broadcast();

  io.Socket? _socket;

  Stream<SocketEventEnvelope> get events => _eventsController.stream;

  bool get isConnected => _socket?.connected ?? false;

  Future<void> connect({
    required String userId,
    required String displayName,
  }) async {
    if (isConnected) {
      return;
    }

    final completer = Completer<void>();

    _socket?.dispose();
    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(<String>['websocket'])
          .disableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(5)
          .setReconnectionDelay(600)
          .setAuth(<String, dynamic>{
            'userId': userId,
            'displayName': displayName,
          })
          .build(),
    );

    _socket!.onConnect((_) {
      _eventsController.add(SocketEventEnvelope(event: 'connect'));
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    _socket!.onDisconnect((reason) {
      _eventsController.add(
        SocketEventEnvelope(event: 'disconnect', payload: reason),
      );
    });

    _socket!.onConnectError((error) {
      if (!completer.isCompleted) {
        completer.completeError(
          SocketConnectionException('Connection error: $error'),
        );
      }
    });

    _socket!.onError((error) {
      if (!completer.isCompleted) {
        completer.completeError(
          SocketConnectionException('Socket error: $error'),
        );
      }
      _eventsController.add(
        SocketEventEnvelope(event: 'error', payload: error),
      );
    });

    _socket!.onAny((event, payload) {
      _eventsController.add(
        SocketEventEnvelope(event: event.toString(), payload: payload),
      );
    });

    _socket!.connect();
    try {
      await completer.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw SocketConnectionException(
        'Connection timeout: server did not respond in time.',
      );
    }
  }

  Future<void> disconnect() async {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }

  Future<Map<String, dynamic>> createRoom({
    required String packageId,
    required String displayName,
    required String visibility,
    required bool allowFalseStarts,
  }) {
    return _emitWithAck('create_room', <String, dynamic>{
      'packageId': packageId,
      'displayName': displayName,
      'visibility': visibility,
      'settings': <String, dynamic>{
        'allowFalseStarts': allowFalseStarts,
      },
    });
  }

  Future<Map<String, dynamic>> listPublicRooms({int limit = 20}) {
    return _emitWithAck('list_public_rooms', <String, dynamic>{
      'limit': limit,
    });
  }

  Future<Map<String, dynamic>> listPackages({
    String? query,
    int? difficulty,
    int limit = 20,
  }) {
    return _emitWithAck('list_packages', <String, dynamic>{
      'limit': limit,
      if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
      if (difficulty != null) 'difficulty': difficulty,
    });
  }

  Future<Map<String, dynamic>> joinRoom({
    required String roomCode,
    required String displayName,
    String? reconnectToken,
  }) {
    return _emitWithAck('join_room', <String, dynamic>{
      'roomCode': roomCode.toUpperCase(),
      'displayName': displayName,
      if (reconnectToken != null && reconnectToken.isNotEmpty)
        'reconnectToken': reconnectToken,
    });
  }

  Future<Map<String, dynamic>> startGame(String roomCode) {
    return _emitWithAck('start_game', <String, dynamic>{'roomCode': roomCode});
  }

  Future<Map<String, dynamic>> selectQuestion({
    required String roomCode,
    required String questionId,
  }) {
    return _emitWithAck('select_question', <String, dynamic>{
      'roomCode': roomCode,
      'questionId': questionId,
    });
  }

  Future<Map<String, dynamic>> buzzAttempt({
    required String roomCode,
    required String questionId,
    required int pressClientMs,
    required int offsetMs,
    required int rttMs,
  }) {
    return _emitWithAck('buzz_attempt', <String, dynamic>{
      'roomCode': roomCode,
      'questionId': questionId,
      'pressClientMs': pressClientMs,
      'offsetMs': offsetMs,
      'rttMs': rttMs,
      'sampleId': DateTime.now().microsecondsSinceEpoch.toString(),
    });
  }

  Future<Map<String, dynamic>> submitAnswer({
    required String roomCode,
    required String questionId,
    required String answerText,
  }) {
    return _emitWithAck('answer_submitted', <String, dynamic>{
      'roomCode': roomCode,
      'questionId': questionId,
      'answerText': answerText,
      'submittedClientMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void emitAnswerDraft({
    required String roomCode,
    required String questionId,
    required String answerText,
  }) {
    final socket = _socket;
    if (socket == null || !socket.connected) {
      return;
    }

    socket.emit('answer_draft', <String, dynamic>{
      'roomCode': roomCode,
      'questionId': questionId,
      'answerText': answerText,
    });
  }

  Future<Map<String, dynamic>> syncTime({
    required String sampleId,
    required int t0ClientMs,
  }) {
    return _emitWithAck('sync_time', <String, dynamic>{
      'sampleId': sampleId,
      't0ClientMs': t0ClientMs,
    });
  }

  Future<Map<String, dynamic>> syncTimeMetrics({
    required String roomCode,
    required int offsetMs,
    required int rttMs,
    String? sampleId,
  }) {
    return _emitWithAck('sync_time_metrics', <String, dynamic>{
      'roomCode': roomCode,
      'offsetMs': offsetMs,
      'rttMs': rttMs,
      if (sampleId != null && sampleId.isNotEmpty) 'sampleId': sampleId,
    });
  }

  Future<Map<String, dynamic>> heartbeat({
    required String roomCode,
    required int clientNowMs,
  }) {
    return _emitWithAck('heartbeat', <String, dynamic>{
      'roomCode': roomCode,
      'clientNowMs': clientNowMs,
    });
  }

  Future<Map<String, dynamic>> leaveRoom(String roomCode) {
    return _emitWithAck('leave_room', <String, dynamic>{'roomCode': roomCode});
  }

  Future<Map<String, dynamic>> _emitWithAck(
    String event,
    Map<String, dynamic> payload,
  ) async {
    final socket = _socket;
    if (socket == null || !socket.connected) {
      throw SocketConnectionException('Socket is not connected');
    }

    final completer = Completer<Map<String, dynamic>>();

    socket.emitWithAck(
      event,
      payload,
      ack: (dynamic raw) {
        completer.complete(_asMap(raw));
      },
    );

    final response = await completer.future.timeout(const Duration(seconds: 8));

    if (response['ok'] != true) {
      final error = _asMap(response['error']);
      throw SocketAckException(
        code: error['code']?.toString() ?? 'UNKNOWN',
        message: error['message']?.toString() ?? 'Unknown socket error',
      );
    }

    return _asMap(response['data']);
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

  Future<void> dispose() async {
    await disconnect();
    await _eventsController.close();
  }
}
