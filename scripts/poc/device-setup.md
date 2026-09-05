# Android POC 真机准备

先使用现有 Windows 电脑和一部 Android 手机。Android 控制 Android 的测试阶段需要两部手机。脚本运行环境为 PowerShell 7（`pwsh`），并需要 Android SDK 的 Platform-Tools 与 Build-Tools。

## 1. 连接手机

1. 在 Android 设置的“关于手机”里连续点击“版本号”，按手机提示开启“开发者选项”。各品牌名称可能不同。
2. 在“开发者选项”中开启“USB 调试”，用能传数据的 USB 线连接 Windows 电脑。
3. 解锁手机，在“允许 USB 调试”弹窗里点“允许”。只对你信任的这台电脑授权。

这些手机设置需要你亲自操作；脚本不会自动授权，也不会启动模拟器。部分品牌安装应用时还需要手动允许“通过 USB 安装”，遇到手机提示后再处理即可。

## 2. 收集测试设备配置

在项目目录的 PowerShell 7 中执行：

```powershell
pwsh -NoProfile -File .\scripts\poc\collect-device-info.ps1
```

报告保存在 `build/poc/device-info.json`。这里已被 Git 忽略，不会随代码提交，也不会自动上传。报告只包含 Windows 的 CPU、GPU、内存、系统/显卡驱动版本，以及已授权 Android 手机的品牌、型号和系统版本；不记录账号、序列号、IP、Android ID 或屏幕内容。

手机暂时没有连接也能生成 Windows 报告，稍后连接后重复运行即可更新。该命令不会安装应用。

## 3. 安装 POC 测试包

等开发者确认构建成功并提供本项目 APK 后执行，把路径替换为实际下载位置：

```powershell
pwsh -NoProfile -File .\scripts\poc\install-android-poc.ps1 -ApkPath 'D:\Downloads\remote-control-poc.apk'
```

脚本先检查连接和授权，再读取 APK 内部应用 ID。只接受 `com.carriez.flutter_hbb.poc`，不会把官方 RustDesk APK 当作 POC 安装；正常更新只使用 `adb install -r`，不会卸载应用或清除数据。若旧 POC 与新包签名不同，会报错并保留旧应用，请将情况告诉开发者处理。

安装成功后会尝试打开测试应用。若连接多台手机，最容易的处理方式是先只保留本次测试的手机；也可以运行 `adb devices` 查看设备标识，并用以下方式指定。设备标识只用于选择安装目标，不会写入设备报告：

```powershell
pwsh -NoProfile -File .\scripts\poc\install-android-poc.ps1 -ApkPath 'D:\Downloads\remote-control-poc.apk' -DeviceId '填入目标设备标识'
```

退出码：`0` 表示安装并打开成功；`1` 表示前置检查或安装失败；`2` 表示已安装但未能自动打开，需在手机上手动打开。脚本不会无限等待设备，检测不到时会提示后退出。

## 4. 开始受控测试

当 Windows 或另一部 Android 要控制这部手机时，按 POC 应用提示，在手机上亲自确认屏幕共享/录屏授权，并在 Android 无障碍设置中允许这个 POC 应用的输入控制服务。每次弹出系统授权提示都由你决定是否同意；脚本不能代替这些操作。

首次测试保持手机解锁、亮屏和应用在前台，先确认画面与点击、滑动、返回正常，再测试后台和网络变化。受保护页面、锁屏、系统弹窗等能力依赖 Android 与厂商限制，不能据一次普通页面操作就判断“所有页面都可完整控制”。

测试结束可在 POC 应用中停止屏幕共享，关闭它的无障碍服务，并在开发者选项中关闭 USB 调试。
