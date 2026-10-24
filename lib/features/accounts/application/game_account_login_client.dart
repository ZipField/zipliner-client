import 'package:zipliner_client/app/app_services.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';

/// Shared login form transport. Cloud credentials never enter the guest store.
class GameAccountLoginClient {
  GameAccountLoginClient(
    this.services, {
    required this.cloud,
    this.reauthenticateAccountId,
  }) : _ownerId = services.accounts?.identity?.id;
  final AppServices services;
  final bool cloud;
  final String? reauthenticateAccountId;
  Map<String, Object?> get _target => {
    if (reauthenticateAccountId != null)
      'reauthenticateAccountId': reauthenticateAccountId,
  };
  final String? _ownerId;

  void _checkOwner() {
    if (_ownerId == null ||
        services.accounts?.isCloud != true ||
        services.accounts?.identity?.id != _ownerId) {
      throw const SklandException('Zipliner 登录状态已变更，请重新打开绑定页面。');
    }
  }

  Future<QrSession> createQrSession() async {
    if (!cloud) return services.skland.createQrSession();
    _checkOwner();
    final data = await services.accounts!.api.post(
      '/api/account/game-accounts/skland/qr/create',
      auth: true,
    ) as Map;
    return QrSession(
      scanId: data['scanId'] as String,
      scanUrl: data['scanUrl'] as String,
    );
  }

  Future<QrStatus> pollQrStatus(String id) async {
    if (!cloud) return services.skland.pollQrStatus(id);
    _checkOwner();
    final data = await services.accounts!.api.get(
      '/api/account/game-accounts/skland/qr/poll',
      query: {'scanId': id, ..._target},
      auth: true,
    ) as Map;
    final state = switch (data['state']) {
      'Confirmed' => QrState.confirmed,
      'PendingConfirm' => QrState.pendingConfirm,
      'Error' => QrState.error,
      _ => QrState.pendingScan,
    };
    return QrStatus(state, message: data['message'] as String?);
  }

  Future<void> sendPhoneCode(String phone) async {
    if (!cloud) return services.skland.sendPhoneCode(phone);
    _checkOwner();
    await services.accounts!.api.post(
      '/api/account/migration/skland/send-code',
      auth: true,
      body: {'phone': phone},
    );
  }

  /// A null token means the cloud binding completed, not a local login.
  Future<String?> phoneCodeLogin(String phone, String code) async {
    if (!cloud) return services.skland.phoneCodeLogin(phone, code);
    _checkOwner();
    final proof = await services.accounts!.api.post(
      '/api/account/migration/skland/phone-code',
      auth: true,
      query: _target,
      body: {'phone': phone, 'code': code},
    ) as Map;
    _checkOwner();
    if (proof['requiresMigration'] != false) {
      await services.accounts!.api.post(
        '/api/account/game-accounts/link-proof',
        auth: true,
        body: {'migrationToken': proof['migrationToken']},
      );
    } else if (proof['canonicalAccountId'] != services.accounts!.identity?.id) {
      throw const SklandException('该游戏账号已绑定至其他 Zipliner 账号。');
    }
    return null;
  }

  Future<String?> emailPasswordLogin(String email, String password) async {
    if (!cloud) return services.skland.emailPasswordLogin(email, password);
    _checkOwner();
    await services.accounts!.api.post(
      '/api/account/game-accounts/skport/link',
      auth: true,
      query: _target,
      body: {'email': email, 'password': password},
    );
    return null;
  }
}
