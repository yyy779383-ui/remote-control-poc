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
