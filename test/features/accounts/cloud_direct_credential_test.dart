import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tf_framework/tf_framework.dart';
import 'package:zipliner_client/features/accounts/application/client_accounts.dart';
import 'package:zipliner_client/features/accounts/models/account_models.dart';
import 'package:zipliner_client/features/accounts/storage/local_guest_store.dart';
import 'package:zipliner_client/features/accounts/storage/token_store.dart';
import 'package:zipliner_client/integrations/skland/skland_models.dart';
import 'package:zipliner_client/shared/http/api_client.dart';

class _CredentialApi extends ApiClient {
  _CredentialApi() : super(baseUrl: 'https://api.test', cookieJar: CookieJar());

  int provisions = 0;

  @override
  Future<dynamic> post(
    String path, {
    Object? body,
    Map<String, Object?>? query,
    bool auth = false,
  }) async {
    if (path != '/api/account/game-accounts/direct-credential') {
      throw StateError('unexpected POST $path');
    }
    provisions++;
    final accountId = (body as Map)['gameAccountId'] as String;
    return {
      'gameAccountId': accountId,
      'token': 'credential-for-$accountId',
      'region': 'skland',
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'provisions once per cloud owner and keeps guest credentials isolated',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final framework = await TfFramework.initialize(
        designSystems: const [Material3DesignSystem()],
        store: TfMemoryPreferenceStore(),
        settingsBuilder: (_) => [],
      );
      final guest = LocalGuestStore();
      await guest.save(const [
        StoredToken(
          id: 'guest',
          token: 'guest-secret',
          region: SklandRegion.skland,
        ),
      ]);
      final api = _CredentialApi();
      final accounts =
          ClientAccounts(
              api,
              framework.preferences,
              guest,
              TokenRepository(guest),
            )
            ..mode = ClientAccountMode.cloud
            ..identity = ZiplinerIdentity({'accountId': 'owner-a'});
      const role = RoleSession(
        tokenId: 'bound-account',
        region: SklandRegion.skland,
        gameAccountId: 'bound-account',
        binding: RoleBinding(roleId: 'role-a', serverId: 'server-a'),
      );

      final first = await accounts.directTokenFor(role);
      final cached = await accounts.directTokenFor(role);
      expect(first.token, 'credential-for-bound-account');
      expect(cached.token, first.token);
      expect(api.provisions, 1);

      accounts.identity = ZiplinerIdentity({'accountId': 'owner-b'});
      await accounts.directTokenFor(role);
      expect(
        api.provisions,
        2,
        reason: 'a different cloud owner has a separate secure-store key',
      );
      accounts.identity = ZiplinerIdentity({'accountId': 'owner-a'});
      expect((await accounts.directTokenFor(role)).token, first.token);
      expect(api.provisions, 2);

      accounts.mode = ClientAccountMode.guest;
      await expectLater(
        accounts.directTokenFor(role),
        throwsA(isA<SklandException>()),
      );
      expect(api.provisions, 2);
      expect(
        (await TokenRepository(guest).list()).single.token,
        'guest-secret',
      );
      accounts.dispose();
    },
  );
}
