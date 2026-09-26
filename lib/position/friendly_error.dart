/// 出错后可以一键执行的补救操作。
enum FixAction { login, relogin, agreePolicy, reconnect }

/// 把森空岛 / 连接层的原始报错翻译成普通用户看得懂的说明。
class FriendlyError {
  const FriendlyError({
    required this.title,
    this.hint,
    this.action,
    this.retryable = false,
    this.retryDelay,
    required this.raw,
  });

  final String title;
  final String? hint;
  final FixAction? action;

  /// 可以自动重连（网络抖动、角色暂时不在线等）。
  final bool retryable;

  /// 固定的重试间隔；为空时按退避表递增。
  final Duration? retryDelay;

  /// 原始消息，放进诊断信息便于排查。
  final String raw;

  static FriendlyError explain(String raw) {
    final text = raw.toLowerCase();
    bool has(String s) => text.contains(s.toLowerCase());

    if (has('未找到终末地角色')) {
      return FriendlyError(
        title: '这个账号下没有终末地角色',
        hint: '请先在森空岛 App 里绑定终末地角色，然后点“重新连接”。',
        action: FixAction.reconnect,
        raw: raw,
      );
    }
    if (has('位置同步政策') || has('position policy')) {
      return FriendlyError(
        title: '需要同意森空岛的位置同步政策',
        hint: '森空岛要求同意相关政策后才会下发坐标。点下面的按钮即可一键同意，效果与在森空岛地图工具里打开“位置同步”相同。',
        action: FixAction.agreePolicy,
        raw: raw,
      );
    }
    if (has('token 无效') ||
        has('已过期') ||
        has('失效') ||
        has('鉴权信息无效') ||
        has('code=10002') ||
        has('请重新登录') ||
        has('请求失败: 401') ||
        has('请求失败: 403')) {
      return FriendlyError(
        title: '登录已失效',
        hint: '森空岛的登录会过期，或在别处修改密码后失效。请到“账号管理”里重新登录这个账号。',
        action: FixAction.relogin,
        raw: raw,
      );
    }
    if (has('角色不在线')) {
      return FriendlyError(
        title: '没有收到坐标',
        hint: '请先进入游戏并登录这个角色；如果已经在游戏里，请到森空岛 App 的地图工具确认“位置同步”已打开。工具会自动重试。',
        retryable: true,
        retryDelay: const Duration(seconds: 15),
        raw: raw,
      );
    }
    if (has('无法连接') || has('超时') || has('网络') || has('请求失败: 5') || has('connection')) {
      return FriendlyError(title: '网络连接失败', hint: '请检查电脑或手机的网络，工具会自动重试。', retryable: true, raw: raw);
    }
    if (has('websocket') || has('连接已断开') || has('服务器关闭连接') || has('无效的')) {
      return FriendlyError(title: '连接中断', hint: '正在自动重连。', retryable: true, raw: raw);
    }
    return FriendlyError(title: raw, action: FixAction.reconnect, raw: raw);
  }
}
