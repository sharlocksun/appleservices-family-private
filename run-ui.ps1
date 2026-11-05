param(
    [ValidateRange(1024, 65535)][int]$Port = 18741,
    [switch]$NoOpen,
    [switch]$Stop,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
if ($env:APPLESERVICES_NO_OPEN -eq '1') { $NoOpen = $true }
$root = $PSScriptRoot
$stateRoot = Join-Path $root 'state'
$binRoot = Join-Path $root 'bin'
$dashboard = Join-Path $binRoot 'dashboard.exe'
$worker = Join-Path $binRoot 'trusted-device-gui.exe'
$adiLibrary = Join-Path $root '.cache\openbubbles-store\rust_lib_bluebubbles.dll'
$macPushSetup = Join-Path $root 'tools\mac-push-check.py'
$pidFile = Join-Path $stateRoot 'dashboard.pid.json'
$url = "http://127.0.0.1:$Port"

function Get-DashboardResponse {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri ($url + '/') -TimeoutSec 2
        if ($response.Headers['X-AppleServices-UI'] -eq '1') { return $response }
    } catch {}
    return $null
}

function Get-VerifiedProcess([int]$ProcessId, [string[]]$AllowedPaths) {
    if ($ProcessId -le 0) { return $null }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    try { $actual = [IO.Path]::GetFullPath($process.Path) } catch { return $null }
    foreach ($allowed in $AllowedPaths) {
        if ($actual -ieq [IO.Path]::GetFullPath($allowed)) { return $process }
    }
    return $null
}

function Get-DashboardProcess {
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $record = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
            $process = Get-VerifiedProcess ([int]$record.pid) @($dashboard)
            if ($process) { return $process }
        } catch {}
    }
    foreach ($line in (& netstat -ano -p tcp 2>$null)) {
        if ($line -match ('^\s*TCP\s+127\.0\.0\.1:' + $Port + '\s+\S+\s+LISTENING\s+(\d+)\s*$')) {
            $process = Get-VerifiedProcess ([int]$Matches[1]) @($dashboard)
            if ($process) { return $process }
        }
    }
    return $null
}

function Stop-SavedWorker([string]$Directory) {
    $runtimePath = Join-Path $Directory 'runtime.json'
    if (-not (Test-Path -LiteralPath $runtimePath)) { return }
    try { $runtime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json } catch { return }
    if (-not $runtime.running -or -not $runtime.pid) { return }
    $allowed = @($worker, (Join-Path $binRoot 'trusted-device.exe'))
    $process = Get-VerifiedProcess ([int]$runtime.pid) $allowed
    if (-not $process) { return }
    $stopPath = Join-Path $Directory 'stop-request.json'
    [IO.File]::WriteAllText($stopPath, (@{ pid = $process.Id } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    if (-not $process.WaitForExit(20000)) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit(5000) | Out-Null
    }
}

function Stop-AllWorkers {
    $response = Get-DashboardResponse
    if ($response) {
        $match = [regex]::Match($response.Content, '<meta\s+name="app-token"\s+content="([^"]+)"')
        if ($match.Success) {
            $headers = @{ 'X-App-Token' = $match.Groups[1].Value }
            try {
                $view = Invoke-RestMethod -Uri ($url + '/api/view') -Headers $headers -TimeoutSec 4
                foreach ($account in @($view.accounts)) {
                    if ([string]::IsNullOrWhiteSpace([string]$account.id)) { continue }
                    $body = @{ account = [string]$account.id } | ConvertTo-Json -Compress
                    try {
                        Invoke-RestMethod -Method Post -Uri ($url + '/api/stop') -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 25 | Out-Null
                    } catch {}
                }
            } catch {}
        }
    }

    Stop-SavedWorker $stateRoot
    $accountsRoot = Join-Path $stateRoot 'accounts'
    if (Test-Path -LiteralPath $accountsRoot) {
        foreach ($directory in Get-ChildItem -LiteralPath $accountsRoot -Directory -ErrorAction SilentlyContinue) {
            Stop-SavedWorker $directory.FullName
        }
    }
}

function Build-Executable([string]$Output, [string]$Package) {
    if ((Test-Path -LiteralPath $Output) -and -not $Rebuild) { return }
    $go = Get-Command go -ErrorAction SilentlyContinue
    if (-not $go) { throw "缺少 $Output，且未找到 Go。请先安装 Go 后重试。" }
    Push-Location $root
    try {
        & $go.Source build -o $Output $Package
        if ($LASTEXITCODE -ne 0) { throw "构建 $Package 失败。" }
    } finally { Pop-Location }
}

function Quote-NativeArgument([string]$Value) {
    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

try {
    New-Item -ItemType Directory -Force -Path $stateRoot, $binRoot | Out-Null

    if ($Stop) {
        Stop-AllWorkers
        $dashboardProcess = Get-DashboardProcess
        if ($dashboardProcess) {
            Stop-Process -Id $dashboardProcess.Id
            if (-not $dashboardProcess.WaitForExit(10000)) {
                Stop-Process -Id $dashboardProcess.Id -Force
            }
        }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        Write-Host '已停止面板和全部账号后台；账号状态与设备身份已保留。' -ForegroundColor Green
        exit 0
    }

    $existing = Get-DashboardResponse
    if ($existing) {
        Write-Host "服务已经运行：$url" -ForegroundColor Green
        if (-not $NoOpen) { Start-Process $url }
        exit 0
    }

    Build-Executable $dashboard './cmd/dashboard'
    Build-Executable $worker './cmd/trusted-device'
    Build-Executable (Join-Path $binRoot 'accountsetupcheck.exe') './tools/accountsetupcheck'
    Build-Executable (Join-Path $binRoot 'familyinspect.exe') './tools/familyinspect'
    Build-Executable (Join-Path $binRoot 'icloudpurchase.exe') './tools/icloudpurchase'

    foreach ($required in @($adiLibrary, $macPushSetup)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "缺少运行依赖：$required" }
    }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw '未找到64位Python。' }

    $arguments = @(
        '-dir', $stateRoot,
        '-worker', $worker,
        '-adi-dll', $adiLibrary,
        '-python', $python.Source,
        '-mac-push-setup', $macPushSetup,
        '-port', [string]$Port
    )
    $argumentText = (@($arguments | ForEach-Object { Quote-NativeArgument ([string]$_) }) -join ' ')
    $process = Start-Process -FilePath $dashboard -ArgumentList $argumentText -WorkingDirectory $root `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $stateRoot 'dashboard.out.log') `
        -RedirectStandardError (Join-Path $stateRoot 'dashboard.err.log')
    [IO.File]::WriteAllText($pidFile, (@{ pid = $process.Id; port = $Port; started_at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $ready = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) { throw "面板启动后立即退出，退出码 $($process.ExitCode)。" }
        $ready = Get-DashboardResponse
        if ($ready) { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $ready) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw '面板在15秒内没有开始监听。'
    }

    Write-Host "启动成功：$url" -ForegroundColor Green
    if (-not $NoOpen) { Start-Process $url }
    exit 0
} catch {
    Write-Host ("操作失败：" + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
