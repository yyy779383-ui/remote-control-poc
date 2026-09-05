# Windows 编解码基准

从 POC 构建产物中取得 `benchmark.exe`，解压到可写目录，在该目录打开 PowerShell。工具捕获主显示器，测量本机采集、像素转换、编码、解码的耗时；不需要连接另一台电脑。

```powershell
.\benchmark.exe --help
.\benchmark.exe --codec=vp9 --count=300 --json=vp9.json
.\benchmark.exe --codec=h264 --count=300 --json=h264.json
```

也可使用 `--codec=all` 顺序测试所有编码器。H.264/H.265 需要包含 `hwcodec` 的构建；POC Windows 基准构建已启用该功能。全量模式会将不可用的硬编解码器记入 JSON 的 `skipped`，单独指定不可用的编码器则报错退出。

首次与后续硬编测试都会主动探测当前硬件，不依赖先运行 RustDesk。探测发生在计时区间外，可能花费数秒；编码器是否真正可用还取决于 GPU、驱动及当前分辨率。工具使用独立的 `RustDeskCodecBenchmark` 配置名称；Windows 探测缓存写入该名称的用户配置目录，不覆盖官方 RustDesk 配置。此工具直接调用原生探测，在驱动卡死的情况下仍可能需要手动关闭进程。

## 如何得到有用的数据

保持主显示器亮屏、会话未锁定，在主显示器持续播放同一段测试动画、滚动网页或移动窗口，直至测试结束。桌面采集器通常只返回有变化的新画面；静止桌面会等待，连续 10 秒没有成功采集的新帧时工具报错退出。`--count` 是成功送入编码器的帧数，不是等待次数，也不是编码包数。

每次记录屏幕分辨率、缩放、CPU/GPU、驱动、测试内容及机器是否接电。保持这些条件一致，用同一编码器对比修改前后的耗时。软件编码尤其是 AV1 可能较慢，可以先使用 `--count=30` 检查流程。

这个版本按顺序编码实时桌面，不重放同一组固定像素帧；不同编码器遇到的画面、帧间隔和 flush 策略可能不同。因此不能据此给不同编码器排清晰度或码率名次，也不能将结果直接当成远程连接的 FPS、鼠标响应延迟或网络带宽需求。它不测网络传输、远端显示、输入回传，也不计算 PSNR/SSIM 等画质指标。后续固定素材重放与端到端真机测试会补齐这些环节。

## JSON 指标含义

| 字段 | 含义 |
| --- | --- |
| `submitted_frames` | 成功提交给编码器的输入帧数 |
| `encoded_packets` | 收集到的编码包数，可能与输入帧数不同 |
| `decoded_frames` | 解码输出总帧数，包含软件解码器最终 flush 输出 |
| `decode_flush_frames` | 上述总帧数中由最终 flush 输出的部分，不应再次相加 |
| `bytes` | 收集到的编码包总字节数，不含协议、加密和网络开销 |
| `average_bytes_per_frame` | `bytes / submitted_frames`，分母是输入帧数 |
| `submitted_fps` / `packet_fps` | 输入帧数 / 编码包数分别除以采集到编码结束的实际耗时 |
| `megabits_per_second` | 编码包总位数除以同一实际耗时，以十进制 Mbit/s 表示；不是固定目标 FPS 下的码率 |
| `capture_timeouts` / `capture_wait` | 采集器返回 `WouldBlock` 的次数及等待耗时，单独记录，不算成功帧 |
| `capture` / `convert` / `encode` | 每次成功采集、像素转换、编码调用的耗时统计 |
| `decode` / `decode_flush` | 每个编码包的解码调用耗时 / 软件解码器最终 flush 耗时 |

阶段统计包括样本数、总耗时、平均值、P50、P95、P99、最大值。分位数按升序样本的 nearest-rank 定义取值：`ceil(百分比 × 样本数)` 对应的样本，不做插值。样本很少时 P95/P99 常等于最大值。采集到编码结束的实际耗时包含等待新画面、循环与进度输出，不包含之后执行的解码测试。

H.264/H.265 目前测试 RAM 路径，不代表 VRAM 零拷贝链路。硬件编解码可能存在缓冲，所以帧数与包数需要分别看；本版不对硬编解码器做最终 drain。查看 `implementation` 确认实际选中的编码器与解码器，不能仅凭 `h264` 标签认定解码一定用了硬件。

## 源码构建与统计测试

以下命令要求先准备项目的 Rust、MSVC、LLVM、vcpkg 原生依赖。直接使用已构建的 `benchmark.exe` 不需要安装这些开发依赖。

```powershell
cargo build --locked --release --package scrap --example benchmark --features hwcodec
cargo test --locked --package scrap --example benchmark --features hwcodec
```

统计测试只验证分位数、空样本以及输入帧数/编码包数/解码帧数的口径，不访问屏幕和 GPU；但整个 example 的编译和链接仍需要原生开发依赖。
