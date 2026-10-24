import 'package:zipliner_client/integrations/skland/skland_models.dart';

class ZiplinerIdentity {
  ZiplinerIdentity(this.data);
  final Map<String, dynamic> data;
  String get id => data['accountId'] as String;
  String get name =>
      (data['displayName'] ?? data['handle'] ?? 'Zipliner 账号').toString();
}

class CloudGameAccount {
  CloudGameAccount(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'].toString();
  String get label =>
      (data['label'] ?? data['providerUserId'] ?? id).toString();
  SklandRegion get region =>
      SklandRegion.parse((data['region'] ?? data['provider']).toString());
  bool get isDefault => data['isDefault'] == true;
  String get status => (data['status'] ?? '').toString();
}

class CloudGameRole {
  CloudGameRole(this.data);
  final Map<String, dynamic> data;
  String get accountId => data['gameAccountId'].toString();
  String get roleId => data['roleId'].toString();
  String get serverId => data['serverId'].toString();
  String get name => (data['nickname'] ?? roleId).toString();
  bool get isDefault => data['isDefault'] == true;
  String get key => '$accountId:$serverId:$roleId';
  RoleSession session(SklandRegion region) => RoleSession(
    tokenId: accountId,
    region: region,
    binding: RoleBinding(serverId: serverId, roleId: roleId, nickname: name),
    gameAccountId: accountId,
  );
}
