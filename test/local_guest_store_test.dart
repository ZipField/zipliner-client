import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zipliner_client/account/local_guest_store.dart';
import 'package:zipliner_client/position/token_store.dart';
import 'package:zipliner_client/skland/skland_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  final old = jsonEncode([
    const StoredToken(
      id: 'original',
      token: 'skland-token',
      region: SklandRegion.skland,
      label: '国服角色',
    ).toJson(),
    const StoredToken(
      id: 'international',
      token: 'skport-token',
      region: SklandRegion.skport,
    ).toJson(),
  ]);

  test('旧账号和角色选择迁入游客档案，保留原键且重复初始化不覆盖新档案', () async {
    FlutterSecureStorage.setMockInitialValues({LocalGuestStore.legacyKey: old});
    final guest = LocalGuestStore(legacySelectedRole: 'original:1:42');
    final repository = TokenRepository(guest);
    final migrated = await repository.list();
    expect(migrated.map((t) => t.id), ['original', 'international']);
    expect(migrated.last.region, SklandRegion.skport);
    expect(migrated.first.label, '国服角色');
    expect(await guest.role(), 'original:1:42');
    expect(await guest.role(defaultRole: true), 'original:1:42');
    expect(await storage.read(key: LocalGuestStore.legacyKey), old);
    await repository.replace('original', 'updated-token', SklandRegion.skland);
    final reopened = LocalGuestStore(legacySelectedRole: 'ignored');
    expect((await reopened.load()).first.token, 'updated-token');
    expect(await reopened.role(), 'original:1:42');
    expect(await storage.read(key: LocalGuestStore.legacyKey), old);
  });

  test('旧数据损坏时停止迁移，不能写入空档案覆盖旧凭据', () async {
    FlutterSecureStorage.setMockInitialValues({
      LocalGuestStore.legacyKey: '{invalid',
    });
    await expectLater(LocalGuestStore().initialize(), throwsFormatException);
    expect(await storage.read(key: LocalGuestStore.profileKey), isNull);
    expect(await storage.read(key: LocalGuestStore.legacyKey), '{invalid');
  });

  test('各账号默认角色、默认账号和当前角色独立保存，兼容旧默认角色', () async {
    FlutterSecureStorage.setMockInitialValues({LocalGuestStore.legacyKey: old});
    final guest = LocalGuestStore(legacySelectedRole: 'original:1:42');
    await guest.initialize();
    await guest.setRole('international:2:8', asDefault: true);
    expect(await guest.defaultAccount(), 'original');
    expect(await guest.defaultRoleFor('international'), 'international:2:8');
    expect(await guest.role(defaultRole: true), 'original:1:42');
    await guest.setDefaultAccount('international');
    expect(await guest.role(defaultRole: true), 'international:2:8');
    expect(await guest.role(), 'original:1:42');
    final reopened = LocalGuestStore();
    expect(await reopened.defaultAccount(), 'international');
    expect(await reopened.defaultRoleFor('original'), 'original:1:42');
    expect(await storage.read(key: LocalGuestStore.legacyKey), old);
  });

  test('并发标签更新和移除账号不能互相覆盖或复活已删除账号', () async {
    FlutterSecureStorage.setMockInitialValues({LocalGuestStore.legacyKey: old});
    final repository = TokenRepository(LocalGuestStore());
    await Future.wait([
      repository.setLabel('original', '新名称'),
      repository.remove('international'),
      repository.add('third-token', SklandRegion.skland),
    ]);
    final values = await repository.list();
    expect(values, hasLength(2));
    expect(values.any((t) => t.id == 'international'), isFalse);
    expect(values.first.label, '新名称');
    expect(values.last.token, 'third-token');
  });
}
