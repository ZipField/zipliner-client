import '../core/api_client.dart';
import '../core/json.dart';

class ServerHealth {
  const ServerHealth({required this.status, required this.version, this.timestamp});

  factory ServerHealth.fromJson(Json json) =>
      ServerHealth(status: json.str('status'), version: json.str('version'), timestamp: json.time('timestamp'));

  final String status;
  final String version;
  final DateTime? timestamp;

  bool get isHealthy => status == 'Healthy';
}

/// `System` 分组。当前只接入健康检查，用来验证客户端与服务端的连通。
class SystemApi {
  const SystemApi(this._client);

  final ApiClient _client;

  Future<ServerHealth> health() async => ServerHealth.fromJson(asJson(await _client.get('/health')));
}
