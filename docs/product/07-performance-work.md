# 媒体热路径与改造顺序

## 当前基线判断

Windows 常规被控路径已具备 DXGI 纹理到 VRAM 硬编的优化分支，首要任务是验证合格设备是否稳定命中该分支，并量化 portable/UAC 等回退路径的损失。

Android 是首发性能改造的重点：

- 被控端当前主要经过 `MediaProjection -> ImageReader RGBA -> JNI -> Rust Vec -> YUV -> encoder`，存在整帧拷贝和颜色转换。
- 主控端当前主要经过 `decoder -> RGBA -> Dart Uint8List -> decodeImageFromPixels -> ui.Image`，每帧跨语言搬运并创建图片。

这两条路径会直接影响 Android 到 Windows、Windows 到 Android 和 Android 到 Android 的流畅度、功耗和发热。

## 关键代码位置

| 环节 | 主要文件 |
|---|---|
| Windows 捕获/编码 | `src/server/video_service.rs`、`libs/scrap/src/dxgi/mod.rs`、`libs/scrap/src/common/vram.rs` |
| 视频发送队列 | `src/server/service.rs`、`src/server/connection.rs` |
| Android 录屏 | `flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/MainService.kt` |
| Android 帧跨 JNI | `libs/scrap/src/android/ffi.rs`、`libs/scrap/src/common/android.rs` |
| 客户端接收/解码 | `src/client/io_loop.rs`、`src/client.rs`、`libs/scrap/src/common/codec.rs` |
| Android/Flutter 显示 | `src/flutter.rs`、`flutter/lib/models/native_model.dart`、`flutter/lib/models/model.dart` |
| 码率/帧率调节 | `src/server/video_qos.rs`、`libs/scrap/src/common/codec.rs` |
| 现有质量 HUD | `src/client/helper.rs`、`flutter/lib/common/widgets/overlay.dart` |

## 改造顺序

### PR 1：离线 benchmark

- 在 `libs/scrap/examples/benchmark.rs` 分别测量 capture、convert、encode 和 decode。
- 输出 average、P50、P95、P99、max、FPS、字节数和关键帧数。
- 支持按 codec 选择和 JSON 报告。
- 只修改测试工具，不改生产路径。

首版 benchmark 顺序采集实时桌面，适合定位单条链路的阶段耗时和回归，不用于宣称不同 codec 的严格画质/码率排名。后续增加同一固定帧集重放，消除画面内容和编码器 flush 策略差异。

### PR 2：默认关闭的全链路诊断

- 新增 `video-diagnostics=Y`，未开启时不改变旧行为。
- 记录 capture/convert/encode/send queue/receive queue/decode/UI prepare。
- 扩展现有质量 HUD，同时支持本地 JSONL 导出。
- 不采集像素、按键内容、剪贴板或文件名。

### PR 3：Android 主控端原生显示

- 使用 `MediaCodec -> Surface/Texture` 呈现视频。
- 消除每帧 RGBA 到 Dart 的大块拷贝和 `ui.Image` 创建。
- 保留原路径作为不支持机型的回退。

### PR 4：Android 被控端 Surface 编码

- 使用 `MediaProjection -> MediaCodec input Surface`。
- 消除常规路径中的 RGBA 整帧搬运和 RGBA-to-YUV 转换。
- 保留能力检测与软编码回退，不盲目开启尚未完成的实验 VP9 分支。

### PR 5：队列和弱网控制

- 在现有 RTT/FPS 调节之上纳入发送队列延迟、抖动、丢帧和丢包。
- 防止码率超过链路时形成越来越大的排队延迟。
- 将移动鼠标和可丢视频帧与点击/键盘等可靠控制事件区分处理。

## 回归原则

每个性能改造都必须有能力检测或显式开关。关闭时继续执行上游原路径，不为了共用新抽象而重写旧路径。
