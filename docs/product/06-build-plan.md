# 可重复构建计划

## 当前环境结论

当前 Windows 主机已具备 Visual Studio Build Tools 2022、Windows SDK、CMake、Ninja、Android SDK 36 和 Android NDK r28c。以下内容需要固定或补齐：

- Rust 1.75；当前的 1.96 保留并侧边安装，不卸载。
- Windows x64/Android 构建使用 Flutter 3.24.5。
- Flutter-Rust Bridge 生成使用 Flutter 3.22.3、`flutter_rust_bridge_codegen` 1.80.1 和 `cargo-expand` 1.0.95。
- vcpkg 提交 `9e593bb18ea69cc5095e012465dcd675a822ed0d`。
- LLVM/Clang 15.0.6 和 NASM。
- Java 至少 17；当前命令行 `JAVA_HOME` 指向 JDK 8，构建时改用 Android Studio 自带 JDK 21 或独立 JDK 17。

## 为什么首构建使用 CI

上游未将 Flutter-Rust Bridge 生成文件提交到 Git，必须在构建前生成。Android 的 Rust/vcpkg/NDK 脚本按 Ubuntu 编写，直接改写成 Windows 脚本会在产品代码之前增加不必要的变量。

因此第一次构建只启用三个任务：

1. Ubuntu 生成 Bridge 产物。
2. Windows Server 2022 构建 Windows x64 未签名调试产物。
3. Ubuntu 构建 Android arm64 测试签名 APK。

不在首次构建中加入 Windows ARM/x86、Android armv7/x86、MSI、便携自解压、商业签名和全平台发布。

## 产物门槛

### Windows x64

- 可在 Windows 10/11 启动。
- 不要求安装商业签名证书。
- 可完成两台 Windows 之间的连接、看屏和键鼠操作。
- 质量监视器可显示编码器、FPS、码率和网络路径。
- 首轮产物是可运行的 Flutter 文件夹，不含虚拟显示和远程打印驱动；进入 IT 支持 Alpha 前补齐完整安装包及 UAC/驱动测试。

### Android arm64

- 安装到 Android 10 或以上真机。
- 可发起远控，也可在用户授予录屏和无障碍权限后接受远控。
- 断开会话或撤销权限后，必须停止画面和输入。
- 首次只验证 arm64，其他 ABI 后续增加。
- POC 使用独立 application ID `com.carriez.flutter_hbb.poc` 和固定测试签名，构建编号随 CI 运行增加。CI 校验 APK 包名、显示名与签名，并随安装包附带证书指纹和 SHA-256。

## 远端仓库要求

当前源码仓库为 `https://github.com/yyy779383-ui/remote-control-poc`，默认分支 `main`。只启用专用 POC 工作流，上游定时发布和其他工作流保持停用。

开发期可以使用私有仓库，但每个交给外部测试者或用户的 EXE/APK 都必须同时提供其对应的 AGPL 源码获取方式。发布不得依赖 RustDesk 上游的临时 CI 产物，必须使用自有仓库和自有构建记录。
