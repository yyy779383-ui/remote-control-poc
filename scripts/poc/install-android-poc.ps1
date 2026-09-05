#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,
    [string]$DeviceId
)

$ErrorActionPreference = 'Stop'
$expectedPackage = 'com.carriez.flutter_hbb.poc'

function Invoke-AndroidTool {
    param([string]$Path, [string[]]$Arguments, [int]$TimeoutSeconds = 15)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw '无法启动 Android 工具。' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            throw "Android 工具在 $TimeoutSeconds 秒内没有响应，请检查 USB 连接后重试。"
        }
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdout.GetAwaiter().GetResult()
            stderr = $stderr.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

try {
    $adbCommand = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $adbPath = if ($adbCommand) { $adbCommand.Source } else { $null }
    $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
    if ($env:LOCALAPPDATA) { $sdkRoots += Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    if (-not $adbPath) {
        foreach ($sdkRoot in $sdkRoots) {
            if ($sdkRoot -and (Test-Path -LiteralPath (Join-Path $sdkRoot 'platform-tools\adb.exe'))) {
                $adbPath = Join-Path $sdkRoot 'platform-tools\adb.exe'
                break
            }
        }
    }
    if (-not $adbPath) { throw '未找到 adb。请安装 Android SDK Platform-Tools，或设置 ANDROID_SDK_ROOT 后重试。' }
    $sdkRoots += Split-Path (Split-Path $adbPath -Parent) -Parent

    $deviceResult = Invoke-AndroidTool -Path $adbPath -Arguments @('devices')
    if ($deviceResult.exitCode -ne 0) { throw 'adb 无法读取设备列表，请检查 Android SDK 和 USB 驱动。' }
    $devices = @(
        foreach ($line in ($deviceResult.stdout -split '\r?\n')) {
            if ($line -match '^([^\s]+)\s+(device|unauthorized|offline|recovery|sideload|bootloader)\b') {
                [pscustomobject]@{ id = $Matches[1]; state = $Matches[2] }
            }
        }
    )
    if ($devices.Count -eq 0) {
        throw '没有检测到 Android 设备。请用可传数据的 USB 线连接手机，开启 USB 调试，并在手机上点“允许 USB 调试”，然后重新运行。'
    }
    if ($DeviceId) {
        $selected = @($devices | Where-Object { $_.id -ceq $DeviceId })
        if ($selected.Count -ne 1) { throw '指定的设备不在 adb 列表中。请检查 USB 连接，并用 adb devices 核对 -DeviceId。' }
        $device = $selected[0]
    } elseif ($devices.Count -gt 1) {
        throw '检测到多台 Android 设备，尚未安装。请只保留要测试的手机，或运行 adb devices 后使用 -DeviceId 指定一台。'
    } else {
        $device = $devices[0]
    }
    if ($device.state -eq 'unauthorized') {
        throw '手机尚未授权 USB 调试。请解锁手机，在手机弹窗中点“允许”，然后重新运行。脚本不会代替你授权。'
    }
    if ($device.state -ne 'device') { throw '手机当前不在线或不在正常 Android 模式。请开机、解锁并重新连接 USB 后重试。' }

    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) { throw '找不到 APK 文件。请把 -ApkPath 改为已下载测试包的完整路径。' }
    $apkFullPath = (Resolve-Path -LiteralPath $ApkPath).Path
    if ([System.IO.Path]::GetExtension($apkFullPath) -ine '.apk') { throw '请选择 .apk 格式的 Android 测试安装包。' }

    $aaptPath = $null
    foreach ($toolName in @('aapt2.exe', 'aapt.exe')) {
        $toolCommand = Get-Command $toolName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($toolCommand) { $aaptPath = $toolCommand.Source; break }
    }
    if (-not $aaptPath) {
        foreach ($sdkRoot in ($sdkRoots | Where-Object { $_ } | Select-Object -Unique)) {
            $buildToolsPath = Join-Path $sdkRoot 'build-tools'
            if (-not (Test-Path -LiteralPath $buildToolsPath -PathType Container)) { continue }
            foreach ($versionDirectory in (Get-ChildItem -LiteralPath $buildToolsPath -Directory | Sort-Object Name -Descending)) {
                foreach ($toolName in @('aapt2.exe', 'aapt.exe')) {
                    $candidate = Join-Path $versionDirectory.FullName $toolName
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $aaptPath = $candidate; break }
                }
                if ($aaptPath) { break }
            }
            if ($aaptPath) { break }
        }
    }
    if (-not $aaptPath) { throw '未找到 Android SDK Build-Tools 中的 aapt2/aapt，无法核验 APK 身份。请先安装 Build-Tools，再运行此脚本。' }
    $packageResult = Invoke-AndroidTool -Path $aaptPath -Arguments @('dump', 'badging', $apkFullPath) -TimeoutSeconds 30
    if ($packageResult.exitCode -ne 0 -or $packageResult.stdout -notmatch "(?m)^package: name='([^']+)'") {
        throw '无法解析 APK 的应用 ID，请重新下载本项目的 Android POC 测试包。'
    }
    if ($Matches[1] -cne $expectedPackage) {
        throw "此 APK 不是本项目的独立 POC 应用（要求 $expectedPackage），已停止安装。请下载 POC 构建产物。"
    }

    Write-Host '已核验 POC 应用身份，正在安装。手机若询问是否允许通过 USB 安装，请自行确认。'
    $installResult = Invoke-AndroidTool -Path $adbPath -Arguments @('-s', $device.id, 'install', '-r', $apkFullPath) -TimeoutSeconds 180
    if ($installResult.exitCode -ne 0 -or $installResult.stdout -notmatch '(?m)^Success\s*$') {
        $failureCode = ''
        if (($installResult.stdout + $installResult.stderr) -match '\bINSTALL_(?:FAILED|PARSE_FAILED)_[A-Z_]+\b') {
            $failureCode = "（$($Matches[0])）"
        }
        throw "安装未成功$failureCode。请确认手机允许 USB 安装、空间充足、测试包签名一致。脚本没有卸载任何应用；请将此提示交给开发者检查。"
    }
    Write-Host 'POC 测试包安装成功。'
    try {
        $launchResult = Invoke-AndroidTool -Path $adbPath -Arguments @(
            '-s', $device.id, 'shell', 'am', 'start', '-n',
            'com.carriez.flutter_hbb.poc/com.carriez.flutter_hbb.MainActivity',
            '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER'
        )
        if ($launchResult.exitCode -ne 0 -or ($launchResult.stdout + $launchResult.stderr) -match '(?im)^Error(?:\s+type\s+\d+|:)') {
            throw 'Android 无法打开测试应用。'
        }
    } catch {
        Write-Warning '已安装，但未能自动打开。请在手机上手动打开 POC 测试应用。'
        exit 2
    }
    Write-Host '已打开 POC 测试应用。录屏和无障碍权限需你在手机上手动确认。'
    exit 0
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
