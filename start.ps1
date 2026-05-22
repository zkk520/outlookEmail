#Requires -Version 5.1
param([int]$Port = 5000)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Write-Step  { param($msg) Write-Host "`n==> $msg" -ForegroundColor Yellow }
function Write-Ok    { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Fail  { param($msg) Write-Host "  [错误] $msg" -ForegroundColor Red }

# ── 1. 检查 uv ────────────────────────────────────────────────────────────────
Write-Step "检查 uv"

try {
    $uvVer = uv --version 2>&1
    Write-Ok "找到 $uvVer"
} catch {
    Write-Fail "未找到 uv，请先安装：winget install astral-sh.uv"
    exit 1
}

# ── 2. 创建/激活虚拟环境（Python >= 3.11）────────────────────────────────────
Write-Step "虚拟环境"

$venvActivate = Join-Path $PSScriptRoot "venv\Scripts\Activate.ps1"
if (-not (Test-Path $venvActivate)) {
    Write-Host "  创建虚拟环境（Python 3.11）..." -ForegroundColor Cyan
    uv venv --python 3.11 venv
    Write-Ok "虚拟环境已创建"
} else {
    Write-Ok "虚拟环境已存在"
}

& $venvActivate
Write-Ok "虚拟环境已激活"

# ── 3. 安装依赖（sentinel 避免重复安装）──────────────────────────────────────
Write-Step "检查依赖"

$reqFile      = Join-Path $PSScriptRoot "requirements.txt"
$sentinelFile = Join-Path $PSScriptRoot "venv\.deps_installed"

$needInstall = $true
if (Test-Path $sentinelFile) {
    $reqTime  = (Get-Item $reqFile).LastWriteTime.ToString("o")
    $sentinel = Get-Content $sentinelFile -Raw
    if ($sentinel.Trim() -eq $reqTime) { $needInstall = $false }
}

if ($needInstall) {
    Write-Host "  安装依赖（首次或 requirements.txt 已变更）..." -ForegroundColor Cyan
    uv pip install -r requirements.txt
    (Get-Item $reqFile).LastWriteTime.ToString("o") | Set-Content $sentinelFile
    Write-Ok "依赖安装完成"
} else {
    Write-Ok "依赖已是最新，跳过安装"
}

# ── 4. 初始化 .env ────────────────────────────────────────────────────────────
Write-Step "配置文件 .env"

$envFile     = Join-Path $PSScriptRoot ".env"
$envExample  = Join-Path $PSScriptRoot ".env.example"
$isFirstRun  = $false

if (-not (Test-Path $envFile)) {
    if (Test-Path $envExample) {
        Copy-Item $envExample $envFile
        Write-Ok ".env 已从 .env.example 创建"
    } else {
        Set-Content $envFile "SECRET_KEY=your-secret-key-here`nLOGIN_PASSWORD=admin123`nPORT=5000`nHOST=0.0.0.0`nFLASK_ENV=production"
        Write-Ok ".env 已从默认模板创建"
    }
    $isFirstRun = $true
}

# 检查并替换占位 SECRET_KEY
$envContent = Get-Content $envFile -Raw
if ($envContent -match "SECRET_KEY=\s*(your-secret-key-here)?\s*(\r?\n|$)") {
    $newKey    = & python -c "import secrets; print(secrets.token_hex(32))"
    $envContent = $envContent -replace "SECRET_KEY=.*", "SECRET_KEY=$newKey"
    Set-Content $envFile $envContent -NoNewline
    Write-Ok "已自动生成随机 SECRET_KEY"
} else {
    Write-Ok "SECRET_KEY 已配置"
}

# ── 5. 加载 .env 到当前进程 ───────────────────────────────────────────────────
Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $idx = $line.IndexOf("=")
        if ($idx -gt 0) {
            $key = $line.Substring(0, $idx).Trim()
            $val = $line.Substring($idx + 1).Trim()
            [System.Environment]::SetEnvironmentVariable($key, $val, "Process")
        }
    }
}

# 命令行参数优先
$env:PORT = "$Port"

# ── 6. 打印启动信息 ───────────────────────────────────────────────────────────
$accessUrl = "http://127.0.0.1:$Port"

Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host "  Outlook 邮件 Web 应用" -ForegroundColor Cyan
Write-Host ("=" * 55) -ForegroundColor Cyan
Write-Host "  访问地址：$accessUrl"
if ($isFirstRun) {
    Write-Host "  首次登录密码：admin123" -ForegroundColor Yellow
    Write-Host "  请登录后立即在「设置」页面修改密码！" -ForegroundColor Yellow
}
Write-Host "  按 Ctrl+C 停止服务"
Write-Host ("=" * 55) -ForegroundColor Cyan

# ── 7. 后台轮询，服务就绪后自动打开浏览器 ───────────────────────────────────
$browserJob = Start-Job -ScriptBlock {
    param($url)
    Start-Sleep -Seconds 2
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -lt 500) {
                Start-Process $url
                break
            }
        } catch { }
        Start-Sleep -Seconds 1
    }
} -ArgumentList $accessUrl

# ── 8. 启动应用（阻塞） ───────────────────────────────────────────────────────
try {
    python web_outlook_app.py
} finally {
    Stop-Job $browserJob -ErrorAction SilentlyContinue
    Remove-Job $browserJob -ErrorAction SilentlyContinue
}
