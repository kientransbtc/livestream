/// A room returned by HiSale's backend.
class LiveKitRoom {
  const LiveKitRoom({
    required this.id,
    required this.title,
    this.description,
    this.status,
    this.participantCount,
    this.maxParticipants,
    this.activeRecording = false,
    this.startedAt,
  });

  final String id;
  final String title;
  final String? description;
  final String? status;
  final int? participantCount;
  final int? maxParticipants;
  final bool activeRecording;
  final DateTime? startedAt;

  factory LiveKitRoom.fromJson(Map<String, dynamic> json) {
    final rawId =
        json['id'] ??
        json['room_id'] ??
        json['roomId'] ??
        json['room'] ??
        json['name'];
    final id = rawId?.toString().trim() ?? '';
    if (id.isEmpty) {
      throw const FormatException('LiveKit room is missing an id.');
    }

    final rawTitle = json['title'] ?? json['room_name'] ?? json['name'] ?? id;
    final metadata = json['metadata'] is Map
        ? Map<String, dynamic>.from(json['metadata'] as Map)
        : const <String, dynamic>{};
    final rawDescription = json['description'] ?? metadata['description'];
    final rawCount =
        json['participant_count'] ??
        json['participantCount'] ??
        json['num_participants'] ??
        json['count'];
    final rawMaxParticipants =
        json['max_participants'] ?? json['maxParticipants'];

    return LiveKitRoom(
      id: id,
      title: rawTitle.toString(),
      description: rawDescription?.toString(),
      status: json['status']?.toString(),
      participantCount: rawCount is num
          ? rawCount.toInt()
          : int.tryParse('$rawCount'),
      maxParticipants: rawMaxParticipants is num
          ? rawMaxParticipants.toInt()
          : int.tryParse('$rawMaxParticipants'),
      activeRecording:
          json['active_recording'] == true || json['activeRecording'] == true,
      startedAt: DateTime.tryParse(
        (json['started_at'] ?? json['startedAt'] ?? '').toString(),
      ),
    );
  }
}

/// Credentials minted by the backend for one room join attempt.
class LiveKitJoinCredentials {
  const LiveKitJoinCredentials({
    required this.serverUrl,
    required this.participantToken,
    this.role = 'audience',
  });

  final String serverUrl;
  final String participantToken;
  final String role;
}
