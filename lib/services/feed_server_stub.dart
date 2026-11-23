/// Feed server — web stub. The web build is a CLIENT of the feed,
/// never a server (a browser cannot bind a socket). All calls are
/// no-ops; see feed_server.dart for the protocol.
library;

/// Default feed-server port (kept in sync with the io build).
const int kFeedServerPort = 49163;

/// No-op feed server for the web build.
class FeedServer {
  bool get isServing => false;

  int get clientCount => 0;

  int get port => kFeedServerPort;

  String get addressLabel => 'off (web build is a feed client)';

  // No-op on web: the web build is a feed client, never a server.
  set recording(bool v) {}

  Future<String> start({
    required Future<String> Function(Map<String, dynamic>) onRecordStart,
    required Future<String> Function() onRecordStop,
    int port = kFeedServerPort,
  }) async =>
      'off (web build is a feed client)';

  Future<void> stop() async {}

  void broadcastSnapshot(Map<String, dynamic> snapshot) {}
}
