# Windows 测试包基础检查

下载本项目 CI 的 `poc-windows-x64-unsigned` 构建产物并完整解压。保留 EXE、DLL 和 `data` 文件夹的原有相对位置；不要只取出 `rustdesk.exe`。本脚本用于 Windows x64 的 Release Flutter bundle，不适用于安装器或单文件压缩启动器。

在项目目录的 PowerShell 7 中执行，将路径替换为包含 `rustdesk.exe` 的解压目录：

```powershell
pwsh -NoProfile -File .\scripts\poc\test-windows-package.ps1 -BundlePath 'D:\Downloads\poc-windows-x64-unsigned'
```

脚本检查 EXE、基础运行库、资源和 Windows x64 文件格式，只启动 `rustdesk.exe --version`，默认最多等待 15 秒；可用 `-TimeoutSeconds` 调整为 1–60 秒。源码中的版本分支先于服务启动返回，Flutter runner 随即退出，不创建远控窗口。脚本不会正常打开 GUI、安装或启动服务、修改远控配置，也不会提权、解锁文件或替你处理系统安全提示。只对本项目可信构建产物使用；文件名和格式检查不能证明任意第三方 EXE 安全。

默认报告为 `build/poc/windows-package-smoke.json`，此目录已被 Git 忽略，不会自动上传。报告记录文件检查结果、EXE 的 SHA-256/文件版本、读取到的版本号和子进程退出码，不记录用户名、绝对路径或原始进程输出。可以用 `-OutputPath` 改变保存位置。

脚本退出码：`0` 表示基础文件和版本启动检查通过；`1` 表示文件缺失、启动/运行失败、超时或报告写入失败；`2` 表示进程退出码为 0，但版本输出无法确认，不能判为通过。超时只终止脚本启动的测试进程及其子进程。

这不是 GUI 或端到端验收。即使通过，也仍需后续检查窗口显示、远程连接、输入控制、编解码、画质、延迟和弱网表现；本步骤不能证明这些能力正常。
