<#
.SYNOPSIS
    StellaSora 本地服「跟随客户端大版本」更新脚本（Windows PowerShell 5.1+ / PowerShell 7）

.DESCRIPTION
    解决症状：游戏客户端自动更新后，登录能过、但一进主界面就弹
        Network Error -> "Network connection error."（Quit / Retry）
    服务端日志里能同时看到：
        [WARN] Unhandled request: <报文号>

    原理：客户端(协议)升级了，本地服务端 jar 太旧 → 客户端发的新报文服务端不认识
    → 客户端回落官方备用域名(bak-nova...)解析失败 → 断网弹窗。

    本脚本按上游公开资源做三件事（全部可回滚）：
      1) 服务端程序：Nebula 官方 nightly（Melledy/Nebula 的 GitHub Actions 产物）
      2) 服务端数据：Hiro420/StellaSoraData 对应区服的 bin / language（+ bubble / dirty_words）
      3) 版本号对齐：把服务端两份 config.json 的 customDataVersion 改成客户端的数据版本

    本脚本不包含、也不分发任何游戏文件或游戏数据，运行时从上述公开仓库下载。

.PARAMETER ServerDir
    本地服「包根目录」（里面应有 Server\lib\Nebula.jar）。不填会自动在脚本目录/当前目录附近找。

.PARAMETER ClientDir
    游戏客户端目录（里面有 Persistent_Store\prefs.dat）。不填会从包根目录的 config.json 里读 game_path。

.PARAMETER Region
    GLOBAL / CN / JP / KR / TW。不填则读服务端 config.json 的 region（一般就是 GLOBAL）。

.PARAMETER SkipJar
    只换数据、不换 jar。

.PARAMETER SkipData
    只换 jar、不换数据。

.PARAMETER SkipDatabaseBackup
    不备份存档（存档较大时用；但强烈建议备份）。

.PARAMETER DryRun
    只检测并打印将要做什么，不写任何文件。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\fix-client-update.ps1 -ServerDir "D:\Stella Sora"

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\fix-client-update.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$ServerDir,
    [string]$ClientDir,
    [string]$Region,
    [switch]$SkipJar,
    [switch]$SkipData,
    [switch]$SkipDatabaseBackup,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Info($m)  { Write-Host "[信息] $m" -ForegroundColor Cyan }
function Ok($m)    { Write-Host "[完成] $m" -ForegroundColor Green }
function Warn($m)  { Write-Host "[注意] $m" -ForegroundColor Yellow }
function Fail($m)  { Write-Host "[失败] $m" -ForegroundColor Red; throw $m }

function Test-PrefsFile($dir) {
    if (-not $dir) { return $false }
    if (Test-Path (Join-Path $dir 'prefs.dat')) { return $true }
    if (Test-Path (Join-Path $dir 'Persistent_Store\prefs.dat')) { return $true }
    return $false
}
function Get-PrefsFile($dir) {
    $a = Join-Path $dir 'prefs.dat'
    if (Test-Path $a) { return $a }
    return (Join-Path $dir 'Persistent_Store\prefs.dat')
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Tmp = Join-Path $env:TEMP ("stella_update_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
$RepoMap = @{ 'GLOBAL' = 'EN'; 'CN' = 'CN'; 'JP' = 'JP'; 'KR' = 'KR'; 'TW' = 'TW' }

# ---------------------------------------------------------------- 1. 定位目录
function Test-ServerRoot($p) {
    if (-not $p) { return $false }
    if (Test-Path (Join-Path $p 'Server\lib\Nebula.jar')) { return $true }
    return $false
}

if ($ServerDir -and -not (Test-ServerRoot $ServerDir)) {
    # 也允许直接传 Server 目录
    if (Test-Path (Join-Path $ServerDir 'lib\Nebula.jar')) { $ServerDir = Split-Path -Parent $ServerDir }
    else { Fail "在 '$ServerDir' 下没找到 Server\lib\Nebula.jar，请用 -ServerDir 指向本地服包根目录。" }
}

if (-not $ServerDir) {
    function Test-PrefsFile($dir) {
    if (-not $dir) { return $false }
    if (Test-Path (Join-Path $dir 'prefs.dat')) { return $true }
    if (Test-Path (Join-Path $dir 'Persistent_Store\prefs.dat')) { return $true }
    return $false
}
function Get-PrefsFile($dir) {
    $a = Join-Path $dir 'prefs.dat'
    if (Test-Path $a) { return $a }
    return (Join-Path $dir 'Persistent_Store\prefs.dat')
}

$cands = @($ScriptRoot, (Split-Path -Parent $ScriptRoot), (Get-Location).Path)
    foreach ($c in $cands) { if (Test-ServerRoot $c) { $ServerDir = $c; break } }
}
if (-not $ServerDir) {
    $typed = Read-Host "请输入本地服包根目录（例如 D:\Stella Sora）"
    if (-not (Test-ServerRoot $typed)) { Fail "路径无效：$typed" }
    $ServerDir = $typed
}
$ServerDir = (Resolve-Path $ServerDir).Path
$ServerSub = Join-Path $ServerDir 'Server'
Info "本地服包根目录：$ServerDir"

# ---------------------------------------------------------------- 2. 定位客户端 & 读版本
$pkgConfig = Join-Path $ServerDir 'config.json'
if (-not $ClientDir -and (Test-Path $pkgConfig)) {
    try {
        $j = Get-Content $pkgConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.game_path) { $ClientDir = $j.game_path }
    } catch { }
}
if ($ClientDir -and -not (Test-PrefsFile $ClientDir)) {
    Warn "在 '$ClientDir' 下没看到 Persistent_Store\prefs.dat，改为自动探测。"
    $ClientDir = $null
}
if (-not $ClientDir) {
    $typed = Read-Host "请输入游戏客户端目录（例如 D:\YostarGames\StellaSora_EN；留空则跳到手动指定版本）"
    if ($typed -and (Test-Path (Join-Path $typed 'Persistent_Store\prefs.dat'))) { $ClientDir = (Resolve-Path $typed).Path }
}

$ClientDataVersion = $null
$ClientGameVersion = $null
if ($ClientDir) {
    $prefs = Get-PrefsFile $ClientDir
    $txt = Get-Content $prefs -Raw -Encoding UTF8
    $m1 = [regex]::Match($txt, 'LOCAL_SERVER_RESOURCE_VERSION\s*:\s*(\d+)')
    $m2 = [regex]::Match($txt, 'LOCAL_GAME_VERSION\s*:\s*([0-9\.]+)')
    if ($m1.Success) { $ClientDataVersion = [int]$m1.Groups[1].Value }
    if ($m2.Success) { $ClientGameVersion = $m2.Groups[1].Value }
    $mani = Join-Path $ClientDir 'Persistent_Store\ss_win.mani'
    if (-not $ClientGameVersion -and (Test-Path $mani)) {
        $fs = [IO.File]::OpenRead($mani)
        $buf = New-Object byte[] 160
        $null = $fs.Read($buf, 0, 160)
        $fs.Close()
        $head = [Text.Encoding]::ASCII.GetString($buf)
        $m3 = [regex]::Match($head, '\$GAME_VER:([0-9\.]+)')
        if ($m3.Success) { $ClientGameVersion = $m3.Groups[1].Value }
    }
    if ($ClientDataVersion) {
        Info ("客户端：{0}  → 数据版本 {1}" -f ($(if ($ClientGameVersion) { $ClientGameVersion } else { '(未知)' })), $ClientDataVersion)
    }
}
if (-not $ClientDataVersion) {
    $typed = Read-Host "没能自动读到客户端数据版本，请手动输入（游戏登录界面左上角版本号最后一段，例如 2.0.0.143 → 143）"
    if ($typed -match '^\d+$') { $ClientDataVersion = [int]$typed } else { Fail "版本号无效：$typed" }
}

# ---------------------------------------------------------------- 3. 区服
$serverCfg = Join-Path $ServerSub 'config.json'
$serverDataCfg = Join-Path $ServerSub 'data\config.json'
$curRegion = 'GLOBAL'
$curVersion = $null
if (Test-Path $serverCfg) {
    $sc = Get-Content $serverCfg -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($sc.region) { $curRegion = $sc.region }
    if ($sc.customDataVersion) { $curVersion = $sc.customDataVersion }
}
if (-not $Region) { $Region = $curRegion }
$repoRegion = $RepoMap[$Region.ToUpper()]
if (-not $repoRegion) { Fail "区服 '$Region' 不支持（可用：GLOBAL/CN/JP/KR/TW）" }
Info ("区服：{0}（数据仓库目录 {1}）；服务端当前自定义数据版本：{2}" -f $Region, $repoRegion, $curVersion)

if ($DryRun) { Info "=== DryRun：只检测，不写文件 ===" }

New-Item -ItemType Directory -Path $Tmp -Force | Out-Null

# ---------------------------------------------------------------- 4. 下载数据
function Download($url, $out) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) { & curl.exe -sSL --max-time 900 --retry 3 --retry-all-errors -o $out $url; return (Test-Path $out) }
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 900
    return (Test-Path $out)
}

$newBin = $null
$newLang = $null
$newBubble = $null
$newDirty = $null
$dataZip = Join-Path $Tmp 'data.zip'

if (-not $SkipData) {
    $urls = @(
        'https://gh-proxy.com/https://github.com/Hiro420/StellaSoraData/archive/refs/heads/main.zip',
        'https://codeload.github.com/Hiro420/StellaSoraData/zip/refs/heads/main'
    )
    $got = $false
    foreach ($u in $urls) {
        Info "下载数据仓库：$u"
        try {
            if ((Download $u $dataZip) -and ((Get-Item $dataZip).Length -gt 5MB)) { $got = $true; break }
        } catch { Warn "下载失败：$($_.Exception.Message)" }
    }
    if (-not $got) { Fail "数据仓库下载失败，请检查网络/代理后重试。" }

    $x = Join-Path $Tmp 'data'
    if (Test-Path $x) { Remove-Item $x -Recurse -Force }
    Expand-Archive -LiteralPath $dataZip -DestinationPath $x -Force
    $root = (Get-ChildItem $x -Directory | Select-Object -First 1).FullName
    $base = Join-Path $root $repoRegion
    if (-not (Test-Path (Join-Path $base 'bin'))) { Fail "数据包里没找到 $repoRegion\bin，可能上游目录结构变了。" }
    $newBin = Join-Path $base 'bin'
    $newLang = Join-Path $base 'language'
    if (Test-Path (Join-Path $base 'bubble')) { $newBubble = Join-Path $base 'bubble' }
    if (Test-Path (Join-Path $base 'dirty_words')) { $newDirty = Join-Path $base 'dirty_words' }

    $gNew = Join-Path $newBin 'Gacha.json'
    if (Test-Path $gNew) {
        $cntNew = (Get-Content $gNew -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties.Name.Count
        $gOld = Join-Path $ServerSub 'Resources\bin\Gacha.json'
        $cntOld = '?'
        if (Test-Path $gOld) { $cntOld = (Get-Content $gOld -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties.Name.Count }
        Info ("新数据：bin {0} 个文件 / 卡池 {1} 条（当前 {2} 条）" -f (Get-ChildItem $newBin -File).Count, $cntNew, $cntOld)
    }
}

# ---------------------------------------------------------------- 5. 下载 nightly jar
$newJar = $null
if (-not $SkipJar) {
    $nightly = 'https://nightly.link/Melledy/Nebula/workflows/gradle/main/Nebula-Nightly.zip'
    $zip = Join-Path $Tmp 'Nebula-Nightly.zip'
    Info "解析 nightly 签名直链..."
    $signed = $null
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $hdr = & curl.exe -s -D - -o NUL --max-time 40 -r 0-1000 $nightly
        $loc = ($hdr | Select-String -Pattern '^Location:' | Select-Object -First 1).Line
        if ($loc) { $signed = ($loc -replace '^Location:\s*', '').Trim() }
    }
    if (-not $signed) { Warn "取签名直链失败，直接尝试 nightly.link（可能很慢）。"; $signed = $nightly }
    Info "下载服务端 jar ..."
    if (-not (Download $signed $zip)) { Fail "nightly 下载失败；可改用 -SkipJar 只换数据，或稍后重试。" }
    $size = (Get-Item $zip).Length
    Info ("nightly 包大小：{0:N1} MB" -f ($size / 1MB))
    $ex = Join-Path $Tmp 'jar'
    if (Test-Path $ex) { Remove-Item $ex -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
    $jar = Join-Path $ex 'Nebula.jar'
    if (-not (Test-Path $jar)) { Fail "nightly 包里没有 Nebula.jar（上游产物结构可能变了）。" }
    $newJar = Join-Path $Tmp 'Nebula.new.jar'
    Copy-Item $jar $newJar -Force
    Info ("新 jar：{0:N1} MB，产物时间 {1}" -f ((Get-Item $newJar).Length / 1MB), (Get-Item $newJar).LastWriteTime)
}

if ($DryRun) {
    Ok "DryRun 结束：检测通过，未修改任何文件。"
    Info "（去掉 -DryRun 即会开始备份并替换。）"
    return
}

# ---------------------------------------------------------------- 6. 备份
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$bak = Join-Path $ServerDir ("_update_bak_" + $stamp)
New-Item -ItemType Directory -Path $bak -Force | Out-Null
Info "备份到：$bak"

Copy-Item (Join-Path $ServerSub 'lib\Nebula.jar') (Join-Path $bak 'Nebula.jar') -Force
if (Test-Path $serverCfg)     { Copy-Item $serverCfg     (Join-Path $bak 'Server_config.json')      -Force }
if (Test-Path $serverDataCfg) { Copy-Item $serverDataCfg (Join-Path $bak 'Server_data_config.json') -Force }
if (Test-Path (Join-Path $ServerSub 'Resources\bin'))      { Compress-Archive -Path (Join-Path $ServerSub 'Resources\bin')      -DestinationPath (Join-Path $bak 'Resources_bin.zip')      -Force }
if (Test-Path (Join-Path $ServerSub 'Resources\language')) { Compress-Archive -Path (Join-Path $ServerSub 'Resources\language') -DestinationPath (Join-Path $bak 'Resources_language.zip') -Force }
if (-not $SkipDatabaseBackup) {
    $db = Join-Path $ServerDir '存档\Database'
    if (Test-Path $db) {
        Info "备份存档（可能较慢）..."
        Compress-Archive -Path (Join-Path $db '*') -DestinationPath (Join-Path $bak 'Database.zip') -Force
    }
}
Ok "备份完成。"

# ---------------------------------------------------------------- 7. 应用
$res = Join-Path $ServerSub 'Resources'

if (-not $SkipData) {
    foreach ($pair in @(@('bin', $newBin), @('language', $newLang), @('bubble', $newBubble), @('dirty_words', $newDirty))) {
        $name = $pair[0]; $src = $pair[1]
        if (-not $src) { continue }
        $dst = Join-Path $res $name
        if (Test-Path $dst) { Move-Item $dst ("{0}_old_{1}" -f $dst, $stamp) -Force }
        Copy-Item $src $dst -Recurse -Force
        Ok ("Resources\{0} 已替换（{1} 个文件）" -f $name, (Get-ChildItem $dst -Recurse -File | Measure-Object).Count)
    }
}

if (-not $SkipJar) {
    Copy-Item $newJar (Join-Path $ServerSub 'lib\Nebula.jar') -Force
    Ok ("服务端 jar 已替换（{0:N1} MB）" -f ((Get-Item (Join-Path $ServerSub 'lib\Nebula.jar')).Length / 1MB))
}

foreach ($cfg in @($serverCfg, $serverDataCfg)) {
    if (-not (Test-Path $cfg)) { continue }
    $t = Get-Content $cfg -Raw -Encoding UTF8
    $t2 = [regex]::Replace($t, '("customDataVersion"\s*:\s*)\d+', ('${1}' + $ClientDataVersion))
    [IO.File]::WriteAllText($cfg, $t2, (New-Object Text.UTF8Encoding($false)))
    Ok ("{0} → customDataVersion = {1}" -f (Split-Path $cfg -Leaf), $ClientDataVersion)
}

# ---------------------------------------------------------------- 8. 收尾提示
Write-Host ""
Ok "全部完成。接下来："
Write-Host "  1) 用启动器重新启动游戏（先确保上次的进程都退干净了）"
Write-Host "  2) 看服务端日志 Server\logs\latest.log，应该出现："
Write-Host "       Game version: <客户端版本>.<自定义数据版本> (GLOBAL)" -ForegroundColor DarkGray
Write-Host "       Loaded N GachaDefs." -ForegroundColor DarkGray
Write-Host "     并且不再反复出现 [WARN] Unhandled request: xxx" -ForegroundColor DarkGray
Write-Host "  3) 回滚：把备份目录里的 Nebula.jar / 两份 config 复制回去，" -ForegroundColor DarkGray
Write-Host "     资源解压覆盖 Resources\bin 与 Resources\language 即可（或把 *_old_<时间戳> 目录改回原名）" -ForegroundColor DarkGray
Write-Host ""
Info "备份目录：$bak"
if ($newBin) {
    $gNew = Join-Path $newBin 'Gacha.json'
    if (Test-Path $gNew) {
        $cnt = (Get-Content $gNew -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties.Name.Count
        if ($ClientDataVersion -and $Region -eq 'GLOBAL') { Warn "数据仓库有时会比客户端落后 1~2 个版本；当前客户端数据版本 $ClientDataVersion，本次数据卡池 $cnt 条，若个别新内容缺失，等仓库更新后重跑本脚本即可。" }
    }
}
