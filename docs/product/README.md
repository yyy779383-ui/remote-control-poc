# 远程控制产品计划

本目录记录基于 RustDesk 1.5.0 的产品化决策、质量门槛和交付计划。产品名暂未确定，文档中统称为“本产品”。

## 已确定决策

- 首批用户：个人用户和 IT 技术支持人员。
- 首发平台：Windows 和 Android。
- 首发控制方向：Windows ↔ Windows、Windows ↔ Android、Android ↔ Android。
- 首发地区：中国大陆、新加坡、美国西部、德国法兰克福。
- 技术路线：RustDesk AGPL 远控内核深度改造，业务后台保持清晰边界。
- 产品原则：稳定 1080p30 先于不稳定的 4K/144FPS；输入响应优先于视频队列完整性。

## 当前阶段

当前只做“质量 POC”，证明四向控制可以达到可验收的清晰度、帧节奏和操作延迟。账号、支付、会员、企业后台和品牌换肤不进入本阶段。

## 文档索引

- [范围与路线图](01-scope-and-roadmap.md)
- [质量验收标准](02-quality-gates.md)
- [技术架构](03-architecture.md)
- [需要产品所有者准备的事项](04-owner-checklist.md)
- [设备与网络测试矩阵](05-test-matrix.md)
- [可重复构建计划](06-build-plan.md)
- [媒体热路径与改造顺序](07-performance-work.md)
