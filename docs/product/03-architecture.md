# 技术架构

## 代码基线

- 上游：`https://github.com/rustdesk/rustdesk.git`
- 上游分支：`master`
- 初始提交：`9a1c8da14382e0a5205eabd397fbaf21be320566`
- 开发分支：`codex/quality-poc`
- 许可证：AGPL-3.0；发布前必须提供对应版本源码及必要构建材料。

## 系统边界

### AGPL 远控核心

- Windows/Android 客户端。
- 屏幕捕获、音视频编解码、输入控制和文件传输。
- 连接协议、NAT 穿透、中继和会话加密。
- 与上述程序紧密组合的改动。

### 后续独立业务服务

- 官网、产品文档和客服工单。
- 支付、套餐、发票和通用账号服务。
- 节点商业运营与内部运维工具。

业务服务只有在未复制、未链接 AGPL 代码且与远控核心真正独立时，才可以考虑闭源。在正式商用前对最终代码边界做专项许可证复核。

## 目标媒体热路径

```text
Capture -> Frame metadata -> Encode -> Packetize -> Transport
                                                     |
Present <- Render <- Decode <- Jitter/Recovery <-----+
```

目标状态下，视频热路径不通过 Flutter 处理像素。Flutter 只负责交互和状态展示，捕获、编解码和呈现使用原生/GPU 路径。当前 Android 路径与该目标之间的差距和改造顺序见《媒体热路径与改造顺序》。

### Windows 被控端

```text
DXGI Desktop Duplication
  -> D3D11 texture
  -> dirty/move region analysis
  -> hardware H.264/H.265 encoder
  -> encrypted media transport
```

能够保持 GPU 纹理时避免回读 CPU；不支持的 GPU/驱动才使用软编码兜底。光标优先在主控端本地绘制，减少鼠标手感延迟。

### Android 被控端

```text
MediaProjection Surface
  -> MediaCodec capability check
  -> hardware H.264 encoder
  -> encrypted media transport
```

根据设备报告的分辨率/帧率能力和实测热降频结果开放档位，不仅依赖型号白名单。输入控制使用用户明确开启的 AccessibilityService。

## 网络路径

1. 并行测试可用直连候选，优先 UDP P2P。
2. P2P 失败时，按双端实测总 RTT 选择中继，不只按 GeoIP。
3. 中继只转发端到端密文，不解码和二次编码。
4. UDP 被阻断时使用 TCP/TLS 443 兜底。
5. 控制事件、视频、音频、文件和剪贴板使用分级队列，文件传输不得阻塞鼠标键盘。

## 区域规划

| 区域 | POC | Beta |
|---|---|---|
| 中国大陆 | 华东 1 个信令/中继节点 | 华东、华南，控制面高可用 |
| 亚洲 | 新加坡 1 个中继 | 新加坡高可用 |
| 美国 | 美国西部 1 个中继 | 根据用户分布增加东部 |
| 欧洲 | 法兰克福 1 个中继 | 法兰克福高可用 |

POC 只在有实际跨境测试需求时开机，不提前长期租用全部节点。
