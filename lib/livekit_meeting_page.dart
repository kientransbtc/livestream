import 'package:flutter/material.dart';

import 'livekit_models.dart';
import 'main.dart' show LiveKitDemoPage;

/// Production entry point for the reusable LiveKit meeting UI.
///
/// The token is already minted by the backend. This page never needs the
/// LiveKit API key or API secret.
class LiveKitMeetingPage extends StatelessWidget {
  const LiveKitMeetingPage({
    super.key,
    required this.room,
    required this.credentials,
    required this.participantName,
    this.appBarAction,
  });

  final LiveKitRoom room;
  final LiveKitJoinCredentials credentials;
  final String participantName;
  final Widget? appBarAction;

  @override
  Widget build(BuildContext context) {
    return LiveKitDemoPage(
      initialRoomName: room.id,
      initialRoomTitle: room.title,
      initialParticipantName: participantName,
      serverUrl: credentials.serverUrl,
      participantToken: credentials.participantToken,
      initialRole: credentials.role,
      autoConnect: true,
      appBarAction: appBarAction,
    );
  }
}
