import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

const liveKitDemoUrl = String.fromEnvironment(
  'LIVEKIT_URL',
  defaultValue: 'wss://kientest-dwegt4vm.livekit.cloud',
);

// Credentials for this local demo only. In HiSale, keep these on the backend
// and replace this function with the authenticated session-token API.
const _apiKey = String.fromEnvironment('LIVEKIT_API_KEY');
const _apiSecret = String.fromEnvironment('LIVEKIT_API_SECRET');

/// Signs a fresh room-scoped JWT with a unique identity on every join attempt.
String createDemoLiveKitToken({
  required String room,
  required String participantName,
  required String role,
}) {
  final roomName = room.trim();
  if (roomName.isEmpty) throw ArgumentError('Nhập Room ID.');
  if (_apiKey.isEmpty || _apiSecret.isEmpty) {
    throw StateError(
      'Demo token requires LIVEKIT_API_KEY and LIVEKIT_API_SECRET dart defines.',
    );
  }

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final random = Random.secure();
  final identity =
      'demo-${_encode(List<int>.generate(16, (_) => random.nextInt(256)))}';
  final header = _encode(
    utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})),
  );
  final payload = _encode(
    utf8.encode(
      jsonEncode({
        'iss': _apiKey,
        'sub': identity,
        'name': participantName,
        'iat': now,
        'nbf': now - 5,
        'exp': now + const Duration(hours: 1).inSeconds,
        'metadata': jsonEncode({
          'role': role,
          if (role == 'host') 'host_state': 'claiming',
        }),
        'video': {
          'roomJoin': true,
          'room': roomName,
          'canSubscribe': true,
          // Hand approval is simulated in this demo's UI. Both roles need
          // publish grants so an approved student can enable mic/screen share
          // without a backend. Production BE must enforce these grants.
          'canPublish': true,
          'canPublishData': true,
          'canUpdateOwnMetadata': true,
        },
      }),
    ),
  );
  final signingInput = '$header.$payload';
  final signature = Hmac(
    sha256,
    utf8.encode(_apiSecret),
  ).convert(utf8.encode(signingInput));
  return '$signingInput.${_encode(signature.bytes)}';
}

String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
