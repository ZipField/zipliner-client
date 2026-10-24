import 'dart:async';
import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/accounts/application/client_accounts.dart';
import 'package:zipliner_client/features/accounts/storage/local_guest_store.dart';
import 'package:zipliner_client/shared/http/api_client.dart';
import 'package:zipliner_client/shared/http/api_exception.dart';
import 'package:zipliner_client/features/accounts/storage/token_store.dart';

class PendingApi extends ApiClient {
  PendingApi() : super(baseUrl: 'https://api.test', cookieJar: CookieJar());
  final session = Completer<dynamic>();
  @override
  Future<dynamic> get(
    String path, {
    Map<String, Object?>? query,
    bool auth = false,
  }) {
    if (path == '/api/account/session') return session.future;
    return Future.value(
      path.endsWith('/roles')
          ? [
              {'gameAccountId': 'game-a', 'roleId': 'role-a', 'serverId': '1'},
            ]
          : [
              {'id': 'game-a', 'provider': 'skland'},
            ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<ClientAccounts> accounts(PendingApi api) async {
    FlutterSecureStorage.setMockInitialValues({
      LocalGuestStore.legacyKey: jsonEncode([
        {'id': 'local-a', 'token': 'local-token', 'region': 'skland'},
      ]),
    });
    final fw = await TfFramework.initialize(
      designSystems: const [Material3DesignSystem()],
      store: TfMemoryPreferenceStore(),
      settingsBuilder: (_) => [],
    );
    await fw.preferences.set(ClientAccounts.modePreference, 'cloud');
    final guest = LocalGuestStore();
    return ClientAccounts(api, fw.preferences, guest, TokenRepository(guest));
  }

  test('local profile is usable while cloud restoration is pending; late success cannot switch it back', () async {
    final api = PendingApi();
    final profile = await accounts(api);
    await profile.initialize();
    expect(profile.initialized, isTrue);
    expect(profile.busy, isFalse);
    expect(profile.restoringCloud, isTrue);
    await profile.enterGuest();
    expect((await profile.localTokens.list()).single.token, 'local-token');
    api.session.complete({'accountId': 'cloud-a'});
    await Future<void>.delayed(Duration.zero);
    expect(profile.mode, ClientAccountMode.guest);
    expect(profile.identity, isNull);
    profile.dispose();
  });

  test('late unauthorized cloud response cannot invalidate the selected local profile', () async {
    final api = PendingApi();
    final profile = await accounts(api);
    await profile.initialize();
    await profile.enterGuest();
    api.session.completeError(const ApiException('Expired', statusCode: 401));
    await Future<void>.delayed(Duration.zero);
    expect(profile.mode, ClientAccountMode.guest);
    expect(profile.error, isNull);
    expect((await profile.localTokens.list()).single.id, 'local-a');
    profile.dispose();
  });

  test(
    'background cloud restoration loads the bound accounts and roles',
    () async {
      final api = PendingApi();
      final profile = await accounts(api);
      await profile.initialize();
      api.session.complete({'accountId': 'cloud-a'});
      for (var i = 0; i < 20 && profile.restoringCloud; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(profile.restoringCloud, isFalse);
      expect(profile.mode, ClientAccountMode.cloud);
      expect(profile.gameAccounts.single.id, 'game-a');
      expect(profile.gameRoles.single.roleId, 'role-a');
      expect(
        profile.useLocalCredentials,
        isFalse,
        reason: 'Direct transport does not mean local credentials',
      );
      profile.dispose();
    },
  );

  test('switching credential sources preserves independent role selections and labels', () async {
    final api = PendingApi();
    final profile = await accounts(api);
    await profile.initialize();
    api.session.complete({'accountId': 'cloud-a'});
    for (var i = 0; i < 20 && profile.restoringCloud; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(profile.restoringCloud, isFalse);
    await profile.selectRole('game-a:1:role-a');
    expect(profile.credentialSourceLabel, 'Zipliner 绑定账号');
    expect(await profile.selectedRole(), 'game-a:1:role-a');

    await profile.useLocalAccounts(true);
    await profile.selectRole('local-a:1:role-a');
    expect(profile.credentialSourceLabel, '本机账号');
    expect(await profile.selectedRole(), 'local-a:1:role-a');

    await profile.useLocalAccounts(false);
    expect(profile.credentialSourceLabel, 'Zipliner 绑定账号');
    expect(await profile.selectedRole(), 'game-a:1:role-a');
    await profile.useLocalAccounts(true);
    expect(await profile.selectedRole(), 'local-a:1:role-a');
    profile.dispose();
  });
}
