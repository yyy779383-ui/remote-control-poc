#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BenchmarkPath,
    [ValidateSet('vp8', 'vp9', 'av1', 'h264', 'h265')]
    [string]$Codec = 'vp9',
    [ValidateRange(1, 1000000)]
    [int]$Count = 30,
    [ValidateRange(1, 60)]
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
$scriptExitCode = 1
$runDirectory = $null
$process = $null
$stdoutTask = $null
$stderrTask = $null
$run = [ordered]@{
    schemaVersion = 1
    scope = 'local-capture-convert-encode-decode-only'
    codec = $Codec.ToLowerInvariant()
    requestedCount = $Count
    timeoutSeconds = $TimeoutSeconds
    executableSha256 = $null
    status = 'not_started'
    processStarted = $false
    processExitCode = $null
    timedOut = $false
    reportValidated = $false
    guiTested = $false
    networkTested = $false
    endToEndTested = $false
}

try {
    if (-not $IsWindows) { throw '此脚本仅支持 Windows 的 PowerShell 7。' }
    if (-not (Test-Path -LiteralPath $BenchmarkPath -PathType Leaf)) {
        throw '找不到 benchmark.exe。请将 -BenchmarkPath 指向本项目 CI 构建并解压后的基准工具。'
    }
    $benchmarkFullPath = (Resolve-Path -LiteralPath $BenchmarkPath).Path
    if ([System.IO.Path]::GetFileName($benchmarkFullPath) -ine 'benchmark.exe') {
        throw '请选择本项目的 benchmark.exe，不要选择远控客户端或安装器。'
    }
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $pocDirectory = Join-Path $repoRoot 'build\poc'
    $null = New-Item -ItemType Directory -Path $pocDirectory -Force
    $runName = 'benchmark-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N')
    $runDirectory = (New-Item -ItemType Directory -Path (Join-Path $pocDirectory $runName)).FullName
    $reportPath = Join-Path $runDirectory 'report.json'
    $run.executableSha256 = (Get-FileHash -LiteralPath $benchmarkFullPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $benchmarkFullPath
    $startInfo.WorkingDirectory = $runDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add('--codec=' + $run.codec)
    $startInfo.ArgumentList.Add('--count=' + $Count)
    $startInfo.ArgumentList.Add('--json=' + $reportPath)
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $run.status = 'start_failed'
    Write-Host ("开始本机 {0} 基准，提交 {1} 帧，最多运行 {2} 秒。" -f $run.codec, $Count, $TimeoutSeconds)
    if (-not $process.Start()) { throw '无法启动 benchmark.exe，请检查文件完整性与系统提示。' }
    $run.processStarted = $true
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $run.status = 'running'
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $run.timedOut = $true
        $run.status = 'timed_out'
        $scriptExitCode = 124
        $process.Kill($true)
        if ($process.WaitForExit(5000)) { $run.processExitCode = $process.ExitCode }
        throw "本机基准超过 $TimeoutSeconds 秒，已终止此次启动的基准进程及其子进程。"
    }
    $run.processExitCode = $process.ExitCode
    if ($process.ExitCode -ne 0) {
        $run.status = 'process_failed'
        throw ("基准工具异常退出，退出码 {0}。请查看本次目录中的 stderr.log。" -f $process.ExitCode)
    }
    $run.status = 'invalid_report'
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw '工具未生成 report.json，本次不能判定为通过。' }
    $suite = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $results = @($suite.results)
    if ($suite.requested_count -ne $Count -or $results.Count -ne 1) {
        throw '报告的帧数要求或编码器结果数量与本次请求不一致。'
    }
    $result = $results[0]
    if ($result.codec -ine $run.codec -or $result.submitted_frames -ne $Count -or
        -not ($result.encoded_packets -gt 0) -or -not ($result.decoded_frames -gt 0) -or
        -not ($suite.width -gt 0) -or -not ($suite.height -gt 0)) {
        throw '报告校验失败：必须提交全部请求帧，且编码包数、解码输出帧数和采集分辨率均大于零。'
    }
    $run.reportValidated = $true
    $run.status = 'passed'
    $scriptExitCode = 0
    Write-Host ("报告通过：{0}×{1}，输入 {2} 帧，编码 {3} 包，解码 {4} 帧。" -f $suite.width, $suite.height, $result.submitted_frames, $result.encoded_packets, $result.decoded_frames)
    Write-Host ("实现：{0}" -f $result.implementation)
    Write-Host ("阶段平均耗时：采集 {0:N2} ms，转换 {1:N2} ms，编码 {2:N2} ms，解码 {3:N2} ms。" -f $result.capture.avg_ms, $result.convert.avg_ms, $result.encode.avg_ms, $result.decode.avg_ms)
} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
} finally {
    if ($process -and $run.processStarted) {
        try {
            if (-not $process.HasExited) {
                $process.Kill($true)
                $null = $process.WaitForExit(5000)
            }
        } catch {
            Write-Warning '未能确认本次基准进程已经退出，请检查此次运行。'
            $scriptExitCode = 1
        }
    }
    if ($runDirectory) {
        try {
            foreach ($entry in @(@('stdout.log', $stdoutTask), @('stderr.log', $stderrTask))) {
                $logText = ''
                if ($entry[1]) {
                    if ($entry[1].Wait(5000)) {
                        $logText = $entry[1].GetAwaiter().GetResult()
                    } else {
                        $logText = 'Log stream did not finish within five seconds; output is unavailable.'
                    }
                }
                $logText | Set-Content -LiteralPath (Join-Path $runDirectory $entry[0]) -Encoding utf8
            }
            $run | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDirectory 'runner.json') -Encoding utf8
            Write-Host ("本次报告与本地日志：build/poc/{0}/" -f (Split-Path $runDirectory -Leaf))
        } catch {
            Write-Error '保存本次日志或执行状态失败，请检查 build/poc 的写入权限。' -ErrorAction Continue
            $scriptExitCode = 1
        }
    }
    if ($process) { $process.Dispose() }
}

Write-Host '这只是本机采集、转换、编码、解码阶段基准，不代表远程 FPS、操作延迟、画质或端到端表现。'
exit $scriptExitCode
