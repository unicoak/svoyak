class PublicRoomView {
  PublicRoomView({
    required this.roomId,
    required this.roomCode,
    required this.status,
    required this.hostName,
    required this.playersCount,
    required this.maxPlayers,
    required this.hasFreeSlots,
    required this.createdAtMs,
  });

  final String roomId;
  final String roomCode;
  final String status;
  final String hostName;
  final int playersCount;
  final int maxPlayers;
  final bool hasFreeSlots;
  final int createdAtMs;

  factory PublicRoomView.fromMap(Map<String, dynamic> raw) {
    return PublicRoomView(
      roomId: raw['roomId']?.toString() ?? '',
      roomCode: raw['roomCode']?.toString() ?? '',
      status: raw['status']?.toString() ?? 'LOBBY',
      hostName: raw['hostName']?.toString() ?? 'Host',
      playersCount: (raw['playersCount'] as num?)?.toInt() ?? 0,
      maxPlayers: (raw['maxPlayers'] as num?)?.toInt() ?? 0,
      hasFreeSlots: raw['hasFreeSlots'] as bool? ?? false,
      createdAtMs: (raw['createdAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}
