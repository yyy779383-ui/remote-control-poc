# Android 模拟器安装与启动验证

日期：2026-09-05。用户提出可使用现有安卓模拟器测试，因此先补充模拟器验证，不再把真机连接作为安装检查的前置条件。

## 环境与成品

- 使用已有 MuMu 6.5.5.0 的“MuMu安卓设备-1”，Android 15 / API 35，1080×1920，4 核 / 4 GiB 配置。
- 实测 ABI 列表为 `x86_64,arm64-v8a,x86`，Native Bridge 为 `libnb.so`。当前环境可以安装并启动本轮 ARM64 APK，不需要为本次冒烟测试另编 x86 包；不据此保证其他模拟器版本兼容。
- 安装包：`build/poc/33948931947/android/rustdesk-poc-arm64-v8a.apk`。
- 包名 `com.carriez.flutter_hbb.poc`，versionCode `2002`；对应构建和 SHA-256 见[第一轮构建记录](08-first-build-validation.md)。
- 使用现有安装脚本和明确的模拟器目标安装，只执行 `adb install -r`，没有卸载应用、清除数据、创建实例或修改模拟器配置。

## 实际结果

| 项目 | 结果 |
| --- | --- |
| Android 启动完成、ABI 检查 | 通过 |
| APK 安装 | 成功 |
| 应用进程 | 检查时正常运行 |
| 主界面 | 已实际观察到，界面仍保留上游 RustDesk 品牌 |
| 共享屏幕页面 | 初次观察显示“服务未运行”；用户授权后，系统检查确认 MainService 存在且 MediaProjection 活动中 |
| 启动异常检查 | 本应用进程的 259 行近期日志中，未匹配到 FATAL EXCEPTION、Fatal signal、UnsatisfiedLinkError、dlopen failed；不等于证明所有错误不存在 |
| 录屏与输入控制授权 | 用户手动开启后，系统只读检查确认录屏授权和本应用无障碍输入服务均已生效 |
| Windows → Android 实际远控 | 未测试 |
| Android → Windows / Android → Android | 未测试 |
| 性能、功耗、真实手机兼容性 | 未验收 |

本机机器可读报告：`build/poc/33948931947/android/emulator-smoke.json`。报告不包含远控 ID、密码、模拟器端口或应用原始日志；没有把截图或原始日志提交到仓库。

## 授权交接与下一步

最初在“共享屏幕”页面停下，由用户自行确认系统录屏授权，并在 Android 无障碍设置中允许 `Remote Control POC Input`。随后界面观察与 Android 系统只读检查确认：POC 的 MediaProjection 已活动，无障碍输入服务已启用，MainService 已启动。

录屏会让受控端画面可见，无障碍输入服务可操作其他应用；不能通过脚本自动授予或绕过权限提示。电脑操作技能要求把此步骤交还用户，本轮没有代替用户同意授权。服务与权限是在用户操作后生效的，不是助手静默开启。

接下来建立 Windows → 此模拟器的会话，测试点击、滑动、返回、文本输入、横竖屏坐标和停止授权后的行为，再安排两端网络与画质测试。初始功能测试无需同时启动第二台模拟器；当前仍不能把“权限就绪”视为“远控已验证”。

## 模拟器结果的边界

ARM 原生库能否运行取决于镜像的转译支持，不能只看主 ABI 是否为 x86；本轮以实际安装和界面启动结果确认。[Android 官方说明](https://android-developers.googleblog.com/2020/03/run-arm-apps-on-android-emulator.html)

模拟器上的基准主要反映宿主机与虚拟化环境，不能代表手机的发热、耗电、硬件编解码效率或厂商后台限制，也不能把同机连接视为公网体验。[Google 性能测试说明](https://codelabs.developers.google.com/android-baseline-profiles-improve)

录屏授权与无障碍能力依照 Android 机制处理。[MediaProjection 文档](https://developer.android.com/media/grow/media-projection)、[AccessibilityService 文档](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService)

## 回归面

本轮仅新增、更新验证文档，未修改应用源码、签名、包名、编解码路径或既有安装脚本。助手的设备侧变更为启动上述现有模拟器并安装、打开独立 POC 应用；录屏和无障碍权限随后由用户手动开启。原有应用和数据未删除。
