<#
  pet 윈도우 원라이너 설치 스크립트 (install.sh 의 윈도우판).

    # 최신(latest) 설치
    irm https://raw.githubusercontent.com/pet-egg/pet/main/install.ps1 | iex
    # 안정화(stable) — 직전 마이너 라인의 최고 패치
    $env:PET_CHANNEL='stable'; irm https://raw.githubusercontent.com/pet-egg/pet/main/install.ps1 | iex

  하는 일: 릴리스의 pet.exe 를 받아 %LOCALAPPDATA%\pet 에 설치 → MOTW(Mark of the Web)
  제거(Unblock-File = 맥의 xattr -d com.apple.quarantine) → 시작 메뉴 바로가기 → 실행.
  이미 있으면 실행 중인 pet 을 종료한 뒤 통째로 교체한다(업데이트 겸용).

  왜 경고가 안 뜨나: 브라우저가 아니라 이 스크립트가 Invoke-WebRequest 로 받으므로
  파일에 MOTW 가 안 붙고(→ SmartScreen 미발동), Unblock-File 로 한 번 더 벗긴다.
  유저 폴더에 설치해 관리자 권한(UAC)도 필요 없다. (미서명이라 백신 오탐은 별개 이슈.)

  채널:
    latest(기본) — releases/latest = 가장 최근 태그.
    stable       — "직전 마이너 라인의 최고 패치"(예: 최신 v1.6.0 → stable v1.5.4).
                   $env:PET_CHANNEL='stable' 로 지정.
#>
$ErrorActionPreference = 'Stop'
# 구형 PowerShell(5.1)에서 TLS1.2 강제 — GitHub 다운로드가 실패하지 않게.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Repo = 'pet-egg/pet'
$Channel = if ($env:PET_CHANNEL) { $env:PET_CHANNEL } else { 'latest' }

function Say($m)  { Write-Host "▸ $m" -ForegroundColor Cyan }
function Die($m)  { Write-Host "✗ $m" -ForegroundColor Red; exit 1 }

# 안정화 태그 계산: 릴리스 목록에서 vX.Y.Z 안정 태그만 골라 내림차순 정렬한 뒤,
# 최신과 major.minor 가 다른 첫 버전(=직전 마이너 라인의 최고 패치)을 고른다.
function Resolve-StableTag {
  $api = "https://api.github.com/repos/$Repo/releases?per_page=100"
  $rels = Invoke-RestMethod -Uri $api -Headers @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'pet-installer' }
  $stable = $rels |
    Where-Object { -not $_.prerelease -and -not $_.draft -and $_.tag_name -match '^v\d+\.\d+\.\d+$' } |
    ForEach-Object { [pscustomobject]@{ tag = $_.tag_name; ver = [version]($_.tag_name.TrimStart('v')) } } |
    Sort-Object ver -Descending
  if (-not $stable) { return $null }
  $newest = $stable[0].ver
  foreach ($s in $stable) {
    if ($s.ver.Major -ne $newest.Major -or $s.ver.Minor -ne $newest.Minor) { return $s.tag }
  }
  return $stable[0].tag   # 직전 마이너 없음 → 최신으로 폴백
}

if ($Channel -eq 'stable') {
  Say '안정화(stable) 버전 확인 중…'
  $tag = Resolve-StableTag
  if (-not $tag) { Die '릴리스 목록을 읽지 못했습니다 (네트워크/GitHub API 확인).' }
  $url = "https://github.com/$Repo/releases/download/$tag/pet.exe"
  Say "안정화 버전: $tag"
} else {
  $url = "https://github.com/$Repo/releases/latest/download/pet.exe"
}

$dir = Join-Path $env:LOCALAPPDATA 'pet'
$exe = Join-Path $dir 'pet.exe'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# 실행 중이면 종료(파일 잠금으로 교체 실패 방지) — install.sh 의 pkill 대응.
Get-Process -Name pet -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400

Say "pet.exe 다운로드 중… ($Channel)"
$tmp = Join-Path $env:TEMP ("pet-" + [guid]::NewGuid().ToString('N') + '.exe')
try {
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
} catch {
  Die "다운로드 실패: $url"
}

# MOTW 제거 (맥의 xattr -d com.apple.quarantine 대응). 스크립트 다운로드라 대개 안
# 붙지만, 벨트+멜빵으로 벗긴다.
Unblock-File -Path $tmp -ErrorAction SilentlyContinue

Say "$dir 로 설치 중…"
Move-Item -Force -Path $tmp -Destination $exe
Unblock-File -Path $exe -ErrorAction SilentlyContinue

# 시작 메뉴 바로가기(맥의 /Applications 등록 대응).
try {
  $programs = [Environment]::GetFolderPath('Programs')
  $lnk = Join-Path $programs 'pet.lnk'
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($lnk)
  $sc.TargetPath = $exe
  $sc.WorkingDirectory = $dir
  $sc.Description = 'pet — 데스크톱 펫'
  $sc.Save()
} catch { }

Say '실행합니다…'
Start-Process -FilePath $exe

Write-Host "✔ 설치 완료 — 시스템 트레이에서 pet 을 확인하세요." -ForegroundColor Green
Write-Host "  설치 위치: $exe"
