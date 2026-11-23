/// Feed client — fallback stub (neither dart:io nor dart:html).
/// Never used in practice; keeps the conditional export total.
library;

import 'package:flutter/foundation.dart';

/// Explicit connection states (see feed_client.dart).
enum FeedState { disconnected, connecting, connected, unreachable }

/// No-op feed client.
class FeedClient extends ChangeNotifier {
  FeedState get state => FeedState.disconnected;

  String? get lastError => 'feed client unavailable on this platform';

  String? get connectedTo => null;

  Map<String, dynamic>? get latestSnapshot => null;

  bool get isConnected => false;

  Future<void> connect(String hostPort) async {}

  Future<void> disconnect() async {}

  Future<Map<String, dynamic>> sendRecordStart(
          Map<String, dynamic> config) async =>
      {'ok': false, 'summary': 'feed client unavailable'};

  Future<Map<String, dynamic>> sendRecordStop() async =>
      {'ok': false, 'summary': 'feed client unavailable'};
}
