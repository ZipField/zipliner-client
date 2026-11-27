# Zipliner Client {{VERSION}}

本次更新修复坐标重连时的令牌复用问题，移除滑索数据采集，并补充 Windows 弱网连接诊断。

## 定位与账号

- 手动重试和自动重连每次新建定位连接时都会申请新令牌，避免因复用旧令牌而收到「鉴权信息无效」。
- 账号凭据、角色列表和位置同步授权继续使用会话缓存。
- 移除滑索手动查询、自动识别、JSON 导出、CSV 记录及悬浮窗识别提示。

## Windows 弱网诊断

- 连接结束时记录持续时间、上下行字节数、解析帧数及最先观察到的断开事件，便于排查短连接和解析异常。

## 下载

| 平台 | 文件 |
| --- | --- |
| Windows x64 | `zipliner-client-{{VERSION}}-windows-x64.zip` |
| Android | `zipliner-client-{{VERSION}}-android.apk` |
| Linux x64 | `zipliner-client-{{VERSION}}-linux-x64.tar.gz` |

`SHA256SUMS.txt` 提供各下载文件的校验值。Android 更新请使用同一签名的 APK 覆盖安装；Windows 和 Linux 更新前请先退出旧版本。
