# Client 目录与维护约定

## 目录职责

```text
lib/
  main.dart                    进程入口、单实例、异常处理、悬浮窗子进程分流
  app/
    bootstrap.dart             框架、日志和平台初始化
    app_services.dart          生产/测试依赖装配与资源所有权
    app_scope.dart             界面访问应用依赖的入口
    app.dart                   应用组件和主题挂载
    home_shell.dart            主导航与主界面生命周期
    app_preferences.dart       用户设置定义；保留已有存储键
    diagnostics.dart           聚合各功能的诊断信息
  shared/
    http/                     HTTP 请求、Cookie、CSRF 和 API 异常
    logging/                  应用日志
    serialization/            通用 JSON 处理
    formatting/               坐标和数值的文本格式化
    widgets/                  多功能共用的界面组件
  integrations/skland/         森空岛/SKPort 请求、签名、协议模型与定位 WebSocket
  platform/desktop/            单实例、游戏窗口定位/选择、系统快捷键、平台兼容处理
  features/
    accounts/
      models/                 Zipliner 账号模型、登录结果
      storage/                游客档案、凭据存储与旧数据迁移
      application/            账号状态、账号管理操作、登录请求
      presentation/           账号入口、列表、详情、绑定/重新登录导航
        login/                登录页面与扫码、验证码、SKPort 表单
    position/
      models/                 连接状态、错误解释
      connections/            独立的网站坐标上传连接
      application/            定位连接、角色选择、重连、接收时序统计
      presentation/           坐标主页、状态、读数及账号操作入口
    collection/               采集控制、识别算法、识别结果、导出与文件记录
    overlay/                  悬浮窗控制、子进程通信、跟随布局、显示及设置界面
    weak_network/             弱网控制、辅助进程桥接、坐标证据传递、风险提示
    maps/
      application/            地图名称加载
      presentation/           地图名称及限高/限低配置查看
    settings/
      application/            更新检测
      presentation/           设置列表、更新提示和帮助
```

小功能保持平铺；文件确实增多时再分层。不要为了统一外形给每个目录建立空的 domain/data/application/presentation 子目录，也不要为每个类添加只有一个实现的接口或空转发封装。

## 关键边界

- `main.dart` 选择主界面或悬浮窗子进程入口；不要为了调用更新弹窗而导入整个应用启动文件。
- `AppServices` 是组合根，负责创建服务、连接跨功能事件并持有资源。界面通过 `AppScope.of(context)` 获取依赖。HTTP、协议和算法实现不应反向导入界面或导航。
- `PositionMonitor` 负责连接、角色、接收状态和恢复。它持有 `collection`，向采集控制器提供当前连接上下文和坐标；采集控制器不打开或重连定位连接。
- `CollectionController` 持有采集、识别和记录状态。异步获取标记时保留连接 revision 检查，避免旧连接的数据覆盖新连接。采集消息及状态变更继续通知主定位界面。
- `DirectAccountSessions` 复用应用会话内成功的账号初始化结果。`DesktopPositionPublisher` 只处理网站订阅通知和坐标上传，不拥有官方定位连接；后台异常不关闭本机直连。
- 登录页面返回 `LoginResult` 或云端绑定成功结果。新增、重新登录和账号管理跳转由外层动作负责；账号列表与登录页面不互相导航导入。
- `DetectedZiplineStop` 是独立数据模型。识别器、记录器和导出器共同依赖它，导出器不再反向依赖识别器。
- 多个功能共用的内容才放 `shared`。业务类不能因为“可能被复用”就被塞入通用工具目录。

## Windows 网络辅助程序

```text
network_helper/
  helper.py                    命令行/父进程握手入口和顶层异常收尾
  engine.py                    网络引擎、控制命令、连接与资源清理
  frame_stream.py              下行帧解析与排队
  weak_state.py                弱网状态和时限
  coordinate_gate.py           坐标判据
  transport.py                 重定向与传输
  game_connection.py           游戏连接检查和临时连接操作
  process_target.py            目标进程匹配
  process_identity.py          辅助进程身份
  driver_service.py            驱动服务清理
  helper_hotkeys.py            辅助程序快捷键
  network_log.py               网络日志
  build.ps1                    PyInstaller 构建入口
  write_licenses.py            依赖许可收集
  tests/                       Python 业务测试
```

保留 `helper.py` 构建入口、辅助程序 exe 名称、发布目录和控制消息格式。引擎内部仍有较长连接处理方法，但不要仅为了缩短文件就改写协议识别、释放判据、锁范围或退出次序；这类行为调整需另开明确任务并验证。

## 测试与变更方式

`test/` 按 `app/`、`features/`、`integrations/`、`shared/` 对应源码职责。共用的假接口、假 WebSocket 和响应数据放在 `test/support/`，不能从另一个 `*_test.dart` 导入夹具。

```sh
flutter analyze
flutter test
python -m unittest discover -s network_helper -p 'test_*.py'
```

移动文件时同步更新真实调用方和测试引用，不保留只为兼容旧目录的转发文件。本项目的原生平台工程、发布脚本和发行文件仍保持在根目录的 `windows/`、`linux/`、`android/`、`packaging/` 中。

目录整理不应改变安全存储键、游客迁移规则、偏好设置键、应用数据目录、进程参数或 IPC 字段。改变这些持久化/通信契约时，必须单独说明兼容和迁移方式。
