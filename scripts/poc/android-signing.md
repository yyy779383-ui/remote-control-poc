# Android POC 安装身份和测试签名

默认构建沿用上游 RustDesk。只有构建进程显式设置 `REMOTE_CONTROL_POC=true` 时，才启用独立测试身份和签名：

| 项目 | 默认构建 | POC 构建 |
| --- | --- | --- |
| 安装包 ID | `com.carriez.flutter_hbb` | `com.carriez.flutter_hbb.poc` |
| 启动器/系统应用名称 | RustDesk | Remote Control POC |
| 无障碍服务名称 | RustDesk Input | Remote Control POC Input |
| URL scheme | `rustdesk://` | `remote-control-poc://` |
| 调试开机广播 | `com.carriez.flutter_hbb.DEBUG_BOOT_COMPLETED` | `com.carriez.flutter_hbb.poc.DEBUG_BOOT_COMPLETED` |

这样可以与官方版并存，并让录屏、无障碍、通知等授权对应独立的测试应用。Kotlin namespace 和 JNI 类名保留上游值；它们是代码身份，不是安装包 ID。应用内和部分通知文本暂时仍显示 RustDesk 品牌，正式命名前不做全局替换。

## 构建凭据

构建进程需要以下环境变量。密码不能出现在命令行参数、仓库、构建产物或日志里：

- `REMOTE_CONTROL_POC=true`
- `REMOTE_CONTROL_POC_KEYSTORE_PATH`：已存在 keystore 的绝对路径，必须位于源码仓库之外。
- `REMOTE_CONTROL_POC_STORE_PASSWORD`
- `REMOTE_CONTROL_POC_KEY_ALIAS`
- `REMOTE_CONTROL_POC_KEY_PASSWORD`

POC 开启而缺少任意凭据时构建立即失败；不会回退到临时 debug 签名。debug、profile、release 构建使用同一 POC 签名，避免切换构建模式后无法覆盖升级。

CI 使用固定的测试密钥，每轮构建复用它。建议 GitHub Actions Secrets 使用：

- `ANDROID_POC_KEYSTORE_BASE64`：keystore 文件的 base64 编码。
- `ANDROID_POC_STORE_PASSWORD`
- `ANDROID_POC_KEY_ALIAS`
- `ANDROID_POC_KEY_PASSWORD`

CI 将 base64 secret 解码到 `$RUNNER_TEMP/remote-control-poc.p12`，将上述 Secrets 映射到构建环境变量。解码步骤使用严格 shell 错误处理及 `umask 077`，任务结束清理该文件。keystore 不进入 artifact/cache。

Windows 首次运行 `pwsh -File scripts/poc/initialize-test-signing.ps1` 可创建并上传固定测试密钥。该脚本重复执行会复用原密钥；本地备份位于 `%LOCALAPPDATA%/RemoteControlPOC/Signing`，密码使用 Windows DPAPI 加密，仅当前 Windows 账号可解密。迁移电脑前应单独做好可恢复备份。

构建命令与上游保持一致，不需要 flavor：

```bash
cd flutter
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

这是内部测试签名，不是商店发行签名。必须备份原始测试 keystore 及密码；GitHub Secrets 不可读回。APK 更新必须同时满足安装包 ID、签名相同以及合适的 versionCode。

## 检验安装包

构建后执行 Android SDK 的 `apksigner verify --verbose --print-certs <apk>`，确认 APK 签名有效，保存证书 SHA-256 指纹用于跨轮构建比较。使用 `apkanalyzer manifest application-id <apk>` 检验包 ID，使用 `apkanalyzer manifest print <apk>` 检验两个显示名、URL scheme、调试广播及组件完整类名。

真机最小验收：

1. 已装官方 RustDesk 时安装 POC，两者都应存在，官方配置不应被替换。
2. 系统设置中的录屏、无障碍、通知权限指向 Remote Control POC。
3. 启动 POC，授权并完成一次 Windows → Android 和 Android → Android 连接。
4. 下一轮使用同一密钥和更高 versionCode 构建，通过 `adb install -r <apk>` 升级，确认 POC 配置与权限保留。

已检查源码中的固定 Android 包名：manifest package、Kotlin package/import、JNI 名字应保留；系统设置跳转使用 `context.packageName`。主工程没有自定义 ContentProvider authorities；最终 APK 仍需检查依赖插件合并后的 providers。
