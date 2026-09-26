/// 构建信息。发布流水线用 `--dart-define=APP_VERSION=v1.2.3` 注入版本号。
abstract final class AppInfo {
  static const name = '终末地坐标工具';
  static const version = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
  static const repository = 'ZipField/zipliner-client';
  static const homepage = 'https://github.com/$repository';
  static const releasesPage = '$homepage/releases';
  static const issuesPage = '$homepage/issues';
  static const latestReleaseApi = 'https://api.github.com/repos/$repository/releases/latest';
  static const license = 'GPL-3.0-or-later';

  static bool get isRelease => version != 'dev';
}
