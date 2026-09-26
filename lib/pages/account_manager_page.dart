import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tf_framework/tf_framework.dart';

import '../core/services.dart';
import '../position/friendly_error.dart';
import '../position/token_store.dart';
import '../skland/skland_models.dart';
import 'login_page.dart';

class _AccountRow {
  _AccountRow(this.account);

  final StoredToken account;
  String? roles;
  String? error;
  bool loading = true;

  bool get expired => error != null && FriendlyError.explain(error!).action == FixAction.relogin;
}

/// 账号管理，对应原工具的 `TokenManagerWindow`：查看、添加、重新登录、移除账号。
class AccountManagerPage extends StatefulWidget {
  const AccountManagerPage({super.key});

  @override
  State<AccountManagerPage> createState() => _AccountManagerPageState();
}

class _AccountManagerPageState extends State<AccountManagerPage> {
  List<_AccountRow>? _rows;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_rows == null && !_loading) _load();
  }

  Future<void> _load() async {
    final services = AppServices.of(context);
    setState(() => _loading = true);
    final accounts = await services.tokens.list();
    final rows = [for (final a in accounts) _AccountRow(a)];
    if (!mounted) return;
    setState(() => _rows = rows);
    await Future.wait(rows.map((row) => _check(services, row)));
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _check(AppServices services, _AccountRow row) async {
    try {
      final credential = await services.skland.login(row.account.token, row.account.region);
      final roles = await services.skland.getRoleBindings(credential, row.account.region);
      row.roles = roles.map((r) => '${r.displayName}（服务器 ${r.serverId}）').join('、');
      final label = roles.map((r) => r.displayName).join('、');
      if (label.isNotEmpty) unawaited(services.tokens.setLabel(row.account.id, label));
    } on SklandException catch (e) {
      row.error = e.message;
    } catch (_) {
      row.error = '检查失败';
    }
    row.loading = false;
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    if (await addAccount(context) && mounted) await _load();
  }

  Future<void> _relogin(_AccountRow row) async {
    if (await reloginAccount(context, row.account) && mounted) await _load();
  }

  Future<void> _remove(_AccountRow row, String name) async {
    final confirmed = await showTfConfirm(
      context,
      title: '移除账号',
      message: '确定移除“$name”？移除后需要重新登录才能再次使用。',
      confirmLabel: '移除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final services = AppServices.of(context);
    await services.tokens.remove(row.account.id);
    unawaited(services.monitor.start());
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final theme = Theme.of(context);
    return TfScaffold(
      title: '账号管理',
      actions: [TfIconButton(icon: Icons.refresh, tooltip: '刷新', onPressed: _loading ? null : _load)],
      body: TfListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  rows == null ? '正在加载账号...' : (rows.isEmpty ? '还没有账号' : '已添加 ${rows.length} 个账号'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              TfButton(label: '添加账号', icon: Icons.person_add_alt, onPressed: _loading ? null : _add),
            ],
          ),
          if (rows == null)
            const TfLoadingState()
          else if (rows.isEmpty)
            TfEmptyState(
              icon: Icons.person_off_outlined,
              title: '还没有账号',
              message: '添加森空岛或 SKPort 账号后才能同步坐标',
              action: TfButton(label: '登录', icon: Icons.login, onPressed: _add),
            )
          else
            TfSection(
              footer: '账号凭据用系统加密保存在本机，只用于连接森空岛。可以添加多个账号，在“坐标”页切换角色。',
              children: [for (final (index, row) in rows.indexed) _tile(context, index, row)],
            ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, int index, _AccountRow row) {
    final scheme = Theme.of(context).colorScheme;
    final name = row.account.label ?? '账号 ${index + 1}';
    final String detail;
    if (row.loading) {
      detail = '正在检查登录状态...';
    } else if (row.expired) {
      detail = '登录已失效，请重新登录';
    } else if (row.error != null) {
      detail = row.error!;
    } else {
      detail = row.roles?.isNotEmpty ?? false ? row.roles! : '未找到终末地角色';
    }
    return TfListTile(
      leading: Icon(
        row.error != null ? Icons.error_outline : Icons.account_circle_outlined,
        color: row.error != null ? scheme.error : null,
      ),
      title: Text(name),
      subtitle: Text(
        '${row.account.region.label} · $detail',
        style: row.error != null ? TextStyle(color: scheme.error) : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (row.error != null) TfButton.secondary(label: '重新登录', onPressed: _loading ? null : () => _relogin(row)),
          TfIconButton(
            icon: Icons.delete_outline,
            tooltip: '移除',
            onPressed: _loading ? null : () => _remove(row, name),
          ),
        ],
      ),
    );
  }
}
