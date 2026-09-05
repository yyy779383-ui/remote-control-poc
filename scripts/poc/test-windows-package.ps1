#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 15,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\..\build\poc\windows-package-smoke.json')
)

$ErrorActionPreference = 'Stop'
$scriptExitCode = 1
$report = [ordered]@{
    schemaVersion = 1
    scope = 'windows-x64-bundle-and-version-only'
    status = 'not_started'
    missingFiles = @()
    executable = [ordered]@{ name = 'rustdesk.exe'; sha256 = $null; fileVersion = $null; reportedVersion = $null }
    process = [ordered]@{ started = $false; timedOut = $false; exitCode = $null; nativeErrorCode = $null; stderrPresent = $false }
    guiTested = $false
    endToEndTested = $false
}

function Test-X64Executable {
    param([string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { return $false }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt $stream.Length - 24) { return $false }
        $stream.Position = $peOffset
        return $reader.ReadUInt32() -eq 0x00004550 -and $reader.ReadUInt16() -eq 0x8664
    } finally {
        $reader.Dispose()
    }
}

try {
    if (-not $IsWindows) { throw '此脚本仅支持 Windows，请在 Windows 的 PowerShell 7 中运行。' }
    if (-not (Test-Path -LiteralPath $BundlePath -PathType Container)) {
        $report.status = 'bundle_not_found'
        throw '找不到解压后的文件夹。请先完整解压 Windows 测试包，再将 -BundlePath 指向包含 rustdesk.exe 的目录。'
    }
    $bundleFullPath = (Resolve-Path -LiteralPath $BundlePath).Path
    foreach ($relativeFile in @(
        'rustdesk.exe', 'librustdesk.dll', 'flutter_windows.dll',
        'dylib_virtual_display.dll', 'data\icudtl.dat', 'data\app.so'
    )) {
        $candidate = Join-Path $bundleFullPath $relativeFile
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or (Get-Item -LiteralPath $candidate).Length -eq 0) {
            $report.missingFiles += $relativeFile
        }
    }
    $assetPath = Join-Path $bundleFullPath 'data\flutter_assets'
    if (-not (Test-Path -LiteralPath $assetPath -PathType Container) -or
        -not (Get-ChildItem -LiteralPath $assetPath -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        $report.missingFiles += 'data\flutter_assets (non-empty directory)'
    }
    if ($report.missingFiles.Count -gt 0) {
        $report.status = 'incomplete_bundle'
        throw ('测试包缺少文件或文件为空：' + ($report.missingFiles -join '、') + '。请完整解压整个构建产物，不能只复制 EXE。')
    }

    $exePath = Join-Path $bundleFullPath 'rustdesk.exe'
    $report.executable.sha256 = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not (Test-X64Executable -Path $exePath)) {
        $report.status = 'invalid_executable'
        throw 'rustdesk.exe 不是可识别的 Windows x64 可执行文件，未启动任何测试进程。请重新下载本项目测试包。'
    }
    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
    if ($versionInfo.OriginalFilename -ine 'rustdesk.exe') {
        $report.status = 'unexpected_executable'
        throw '可执行文件的原始文件名与 RustDesk 不符，已停止。请使用本项目 CI 生成的完整 Windows 测试包。'
    }
    if ($versionInfo.FileVersion -match '^\d+(?:\.\d+){1,3}(?:[+-][0-9A-Za-z.-]+)?$') {
        $report.executable.fileVersion = $versionInfo.FileVersion
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $exePath
    $startInfo.WorkingDirectory = $bundleFullPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # core_main returns before service startup; the Flutter runner then exits before creating a window.
    $startInfo.ArgumentList.Add('--version')
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $report.status = 'start_failed'
        if (-not $process.Start()) { throw '未能启动版本检查。请检查测试包是否完整，以及 Windows 是否阻止运行。' }
        $report.process.started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $report.process.timedOut = $true
            $report.status = 'timed_out'
            $process.Kill($true)
            if ($process.WaitForExit(5000)) { $report.process.exitCode = $process.ExitCode }
            throw "版本检查超过 $TimeoutSeconds 秒，已终止本脚本启动的测试进程。"
        }
        $report.process.exitCode = $process.ExitCode
        $versionOutput = $stdout.GetAwaiter().GetResult().Trim()
        $report.process.stderrPresent = -not [string]::IsNullOrWhiteSpace($stderr.GetAwaiter().GetResult())
        if ($process.ExitCode -ne 0) {
            $report.status = 'process_failed'
            throw ("版本检查异常退出，退出码：{0}。" -f $process.ExitCode)
        }
        if ($versionOutput -match '^\d+\.\d+\.\d+(?:[0-9A-Za-z.+-]*)$') {
            $report.executable.reportedVersion = $versionOutput
            $report.status = 'passed'
            $scriptExitCode = 0
            Write-Host ("版本检查通过：{0}，退出码 0。" -f $versionOutput)
        } else {
            $report.status = 'version_output_unavailable'
            $scriptExitCode = 2
            Write-Warning '进程正常退出，但未读取到预期版本号；本次结果尚不能判为通过。'
        }
    } catch [System.ComponentModel.Win32Exception] {
        $report.process.nativeErrorCode = $_.Exception.NativeErrorCode
        throw 'Windows 未能启动版本检查。请检查文件完整性与系统提示；脚本不会提权、解锁文件或绕过系统安全设置。'
    } finally {
        $process.Dispose()
    }
} catch {
    if ($report.status -eq 'not_started') { $report.status = 'check_failed' }
    Write-Error $_.Exception.Message -ErrorAction Continue
}

try {
    $outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
    $null = New-Item -ItemType Directory -Path (Split-Path $outputFullPath -Parent) -Force
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outputFullPath -Encoding utf8
    Write-Host '已写入检查报告；默认位置为项目 build/poc/windows-package-smoke.json。报告不包含用户名、绝对文件路径或原始进程输出。'
} catch {
    Write-Error '无法写入检查报告，请检查 -OutputPath 所在目录的写入权限。' -ErrorAction Continue
    $scriptExitCode = 1
}
Write-Host '本检查仅验证基础文件和 --version 启动，不代表图形界面、远程连接、画质或流畅度已经验证。'
exit $scriptExitCode
