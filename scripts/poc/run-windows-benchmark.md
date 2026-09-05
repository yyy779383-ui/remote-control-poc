# 有超时保护的 Windows 本机基准

先下载并解压本项目 CI 的 `poc-windows-performance-tools`，用 PowerShell 7 执行以下命令，将路径替换成实际的 `benchmark.exe` 路径：

```powershell
pwsh -NoProfile -File .\scripts\poc\run-windows-benchmark.ps1 -BenchmarkPath 'D:\Downloads\windows-performance\target\release\examples\benchmark.exe' -Codec vp9 -Count 1
pwsh -NoProfile -File .\scripts\poc\run-windows-benchmark.ps1 -BenchmarkPath 'D:\Downloads\windows-performance\target\release\examples\benchmark.exe' -Codec h264 -Count 1
```

`-BenchmarkPath` 必填，不固定某次构建编号。编码器可选 `vp8`、`vp9`、`av1`、`h264`、`h265`，默认 `vp9`；`-Count` 默认 30；`-TimeoutSeconds` 默认 45，范围 1–60 秒。先用一帧确认流程，再增加帧数；单帧数据不能代表稳定性能。

每次运行新建 `build/poc/benchmark-时间-GUID/`，不覆盖已有结果。`report.json` 保存工具指标，`runner.json` 保存启动状态、文件 SHA-256、退出码及报告校验结果，`stdout.log` 和 `stderr.log` 保存本地原始日志。该目录已被 Git 忽略，不会自动上传。原始日志可能包含驱动和本机诊断信息，分享前应检查内容。

脚本隐藏基准进程窗口，异步读取输出；超过时间只终止本次启动的进程及其子进程。子进程退出码为 0、报告匹配指定编码器、`submitted_frames` 等于请求帧数，且 `encoded_packets` 和 `decoded_frames` 均大于零，才判定通过。脚本退出码 `0` 表示通过，`1` 表示运行、校验或日志保存失败，`124` 表示超时。

工具只读取当前主显示器画面并在内存中编解码，不保存截图或录像，不需要启动 Windows 远控客户端，也不建立远程连接。脚本不操作桌面、浏览器、网络或系统设置。工具自身的硬件探测会写入独立的 `RustDeskCodecBenchmark` 缓存，不覆盖官方 RustDesk 配置。

采集依赖桌面产生新画面；锁屏、显示不可用或长时间画面不变时，工具可能退出或达到外层超时。需要较长测试时，由用户保持桌面正常显示并重复同一段测试内容。

H.264/H.265 硬件链路可能缓冲首帧，而当前工具不做最后的 drain；若一帧测试没有解码输出，只能说本次结果不充分，可以改为 `-Count 30` 再测。日志中其他品牌 GPU 不可用的探测消息也不等于整个测试失败，应以最终选中的实现、进程退出码和报告校验为准。

这里测的是本机采集、像素转换、编码和解码阶段，不包含网络传输、远端显示或输入回传，也不计算画质评分。不能把一次结果当成产品的实际远程 FPS、操作延迟或清晰度排名。H.264/H.265 当前是 RAM 路径，不代表 VRAM 零拷贝表现。更详细的指标口径见同目录 `benchmark.md`。
