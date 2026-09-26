/// 森空岛（国服）与 SKPort（国际服）使用不同的域名与 appCode。
enum SklandRegion {
  skland,
  skport;

  static SklandRegion parse(String? value) => value?.trim().toLowerCase() == 'skport' ? skport : skland;

  bool get isSkport => this == skport;

  String get label => isSkport ? 'SKPort' : '森空岛';

  /// 与后端 `SklandService.ResolveRegionByServerId` 一致：只有服务器 `1` 属于国服。
  static SklandRegion fromServerId(String? serverId) =>
      (serverId == null || serverId.trim().isEmpty || serverId.trim() == '1') ? skland : skport;
}

/// `generate_cred_by_code` 的结果；`token` 用于请求签名。
class CredentialResult {
  const CredentialResult({required this.cred, required this.userId, required this.token});

  final String cred;
  final String userId;
  final String token;
}

class RoleBinding {
  const RoleBinding({required this.serverId, required this.roleId, this.nickname, this.channelName, this.level});

  final String serverId;
  final String roleId;
  final String? nickname;
  final String? channelName;
  final int? level;

  String get displayName {
    final name = (nickname == null || nickname!.trim().isEmpty) ? roleId : nickname!;
    return (channelName == null || channelName!.trim().isEmpty) ? name : '$channelName - $name';
  }
}

/// 一个 token 下的一个角色，`key` 用于在重连后恢复选择。
class RoleSession {
  const RoleSession({required this.tokenId, required this.region, required this.credential, required this.binding});

  final String tokenId;
  final SklandRegion region;
  final CredentialResult credential;
  final RoleBinding binding;

  String get key => '$tokenId:${binding.serverId}:${binding.roleId}';

  String get displayName => binding.displayName;
}

class PositionSnapshot {
  const PositionSnapshot(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;
}

/// 地图上的滑索标记，`pos` 是 3x3 占地的一个角。
class ZiplineMark {
  const ZiplineMark(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;
}

class QrSession {
  const QrSession({required this.scanId, required this.scanUrl});

  final String scanId;
  final String scanUrl;
}

enum QrState { pendingScan, pendingConfirm, confirmed, error }

class QrStatus {
  const QrStatus(this.state, {this.message, this.token});

  final QrState state;
  final String? message;

  /// 状态为 [QrState.confirmed] 时已换取到的登录 token。
  final String? token;
}

/// 森空岛接口返回的业务错误，`message` 可直接展示给用户。
class SklandException implements Exception {
  const SklandException(this.message);

  final String message;

  @override
  String toString() => message;
}
