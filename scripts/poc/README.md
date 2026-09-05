# POC 开发脚本

## 构建环境体检

```powershell
pwsh -File .\scripts\poc\check-toolchain.ps1
```

需要机器可读取的结果时：

```powershell
pwsh -File .\scripts\poc\check-toolchain.ps1 -Json
```

脚本只读取环境和仓库状态，不安装依赖，也不修改系统配置。

## 测试工具

- [Windows 测试包基础检查](windows-package-test.md)：检查完整解压包和版本启动，不打开远控界面。
- [本机编解码测试](benchmark.md)：测量采集、转换、编码和解码阶段。
- [离线画质测试画面](quality-scene.md)：提供文字、细线和运动测试内容。
- [Android 真机准备](device-setup.md)：连接手机后再安装并手动授权，不需要现在完成。
