import 'package:signalr_netcore/signalr_client.dart';

import 'api.dart';
import 'models.dart';

/// Подписка на статусы проекта через SignalR (`/hubs/projects` через Kong, FR-C3).
class ProjectHub {
  ProjectHub(this.api, this.projectId, this.onStatus);

  final Api api;
  final String projectId;
  final void Function(StatusUpdate) onStatus;
  HubConnection? _conn;

  Future<void> connect() async {
    final conn = HubConnectionBuilder()
        .withUrl('${api.base}/hubs/projects',
            options: HttpConnectionOptions(
              accessTokenFactory: api.accessToken,
              transport: HttpTransportType.WebSockets,
              skipNegotiation: true,
              requestTimeout: 15000,
            ))
        .withAutomaticReconnect()
        .build();
    conn.on('status', (args) {
      final m = args?.firstOrNull;
      if (m is Map<String, dynamic>) onStatus(StatusUpdate.fromJson(m));
    });
    // После переподключения группа SignalR теряется: подписываемся заново.
    conn.onreconnected(({connectionId}) => conn.invoke('Subscribe', args: [projectId]));
    await conn.start();
    await conn.invoke('Subscribe', args: [projectId]);
    _conn = conn;
  }

  Future<void> close() async => _conn?.stop();
}
