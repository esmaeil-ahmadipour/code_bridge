<#
dw v2 - Diff Direct Writer (PowerShell edition)
Reads diff.txt (next to this script), takes the FIRST LINE as the repo path,
and applies the rest (a unified diff) to that repo, file by file.
Windows PowerShell 5.1+ / PowerShell 7+, requires git.
#>
param(
  [Parameter(Position = 0)][string]$DiffFile,
  [Alias('n')][switch]$DryRun,
  [Alias('y')][switch]$Yes,
  [Alias('s')][switch]$Strict,
  [Alias('a')][switch]$Archive,
  [Alias('u')][switch]$Undo,
  [Alias('r')][string]$Repo,
  [Alias('b')][string]$Branch,
  [Alias('c')][string]$Commit,
  [switch]$Help
)

$ErrorActionPreference = 'Continue'
$Version = '2.0.0'

function Die($m)  { Write-Host "error: $m" -ForegroundColor Red; exit 1 }
function Warn($m) { Write-Host "warn: $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "==> $m" -ForegroundColor Green }
function Tag($t, $color, $msg) {
  Write-Host "[$t] " -ForegroundColor $color -NoNewline
  Write-Host $msg
}

function Show-Usage {
@'
dw v2 - Diff Direct Writer  (PowerShell edition)

HOW IT WORKS
  1. Put your diff in diff.txt, in the same folder as dw.cmd.
  2. Line 1 of diff.txt = path of your repo (any drive / folder), e.g.
         C:\code\portfolio     or     D:\work\site     or     ~/code/portfolio
  3. Paste the diff below line 1.  Run:  dw      (or double-click apply.cmd)

USAGE
  dw [options] [diff-file]

  diff-file   optional. Default: diff.txt next to the script, else .\diff.txt

OPTIONS
  -n, -DryRun     check only, change nothing
  -y, -Yes        do not ask for confirmation
  -s, -Strict     all-or-nothing: if any file cannot be applied, apply none
  -a, -Archive    after a fully successful run, rename diff.txt to
                  diff.applied-<date>.txt
  -b, -Branch N   create and switch to a new branch before applying
  -c, -Commit MSG commit the applied files with message MSG
  -r, -Repo PATH  use PATH instead of line 1 of the diff file
  -u, -Undo       revert the last run (repo from line 1, or -r PATH)
  -Help           this help

Without -Strict, every file is handled on its own: files that apply are
written, the others are reported (so you can ask for a fresh diff for them).
Files that are already applied are skipped, so running twice is safe.
'@ | Write-Host
}

if ($Help) { Show-Usage; exit 0 }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die 'git is not installed (or not in PATH)' }

# ---------- find the diff file ----------
$diffPath = $null
if ($DiffFile) {
  if (-not (Test-Path -LiteralPath $DiffFile -PathType Leaf)) { Die "diff file not found: $DiffFile" }
  $diffPath = (Resolve-Path -LiteralPath $DiffFile).Path
}
else {
  $cwdDiff = Join-Path (Get-Location).Path 'diff.txt'
  $scriptDiff = Join-Path $PSScriptRoot 'diff.txt'
  if (Test-Path -LiteralPath $scriptDiff -PathType Leaf) { $diffPath = $scriptDiff }
  elseif (Test-Path -LiteralPath $cwdDiff -PathType Leaf) { $diffPath = $cwdDiff }
}
if (-not $diffPath -and -not ($Undo -and $Repo)) {
  Die "diff.txt not found. Looked in: $PSScriptRoot  and  $((Get-Location).Path)"
}

# ---------- read diff.txt: line 1 = repo, rest = diff ----------
$firstLine = ''
$restText = ''
if ($diffPath) {
  $txt = [IO.File]::ReadAllText($diffPath)
  $txt = $txt.TrimStart([char]0xFEFF) -replace "`r`n", "`n" -replace "`r", "`n"
  $all = $txt -split "`n"
  $idx = -1
  for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i].Trim() -ne '') { $idx = $i; break } }
  if ($idx -lt 0) { Die "diff file is empty: $diffPath" }
  $firstLine = $all[$idx]
  if ($idx + 1 -lt $all.Count) { $restText = ($all[($idx + 1)..($all.Count - 1)] -join "`n") }
}

function Resolve-RepoPath([string]$s) {
  $p = $s.Trim()
  if ($p -match '^(?:repo|path|project)\s*[:=]\s*(.+)$') { $p = $Matches[1].Trim() }
  $p = $p.Trim('"').Trim("'")
  $p = [Environment]::ExpandEnvironmentVariables($p)
  if ($p -match '^~([\\/].*)?$') { $p = $HOME + $Matches[1] }
  if ($p -match '^/([A-Za-z])/(.*)$') { $p = $Matches[1].ToUpper() + ':\' + ($Matches[2] -replace '/', '\') }
  return $p
}

if ($Repo) { $repoRaw = $Repo }
else {
  if ($firstLine -match '^(diff --git |--- |\+\+\+ |@@ |`{3})') {
    Die "line 1 of $diffPath must be the repo path, but it looks like diff content"
  }
  $repoRaw = $firstLine
}
$repoPath = Resolve-RepoPath $repoRaw
if (-not (Test-Path -LiteralPath $repoPath -PathType Container)) { Die "repo folder not found: $repoPath   (from: $repoRaw)" }

$rootOut = & git -C $repoPath rev-parse --show-toplevel 2>&1
if ($LASTEXITCODE -ne 0) { Die "not a git repository: $repoPath" }
$script:Root = ("$rootOut").Trim()
$gitDirOut = & git -C $script:Root rev-parse --absolute-git-dir 2>&1
if ($LASTEXITCODE -ne 0) { Die 'cannot locate .git directory' }
$GitDir = ("$gitDirOut").Trim()
$LastPatch = Join-Path $GitDir 'dw-last.patch'
$LastP = Join-Path $GitDir 'dw-last.p'

# Run git inside the repo; returns @{Ok; Out}
function G {
  $o = & git -C $script:Root @args 2>&1 | ForEach-Object { "$_" }
  $ok = ($LASTEXITCODE -eq 0)
  [pscustomobject]@{ Ok = $ok; Out = ($o -join "`n") }
}

# ---------- undo ----------
if ($Undo) {
  if (-not (Test-Path -LiteralPath $LastPatch)) { Die "nothing to undo in $($script:Root) (no previous dw run)" }
  $pl = 1
  if (Test-Path -LiteralPath $LastP) { $pl = [int]((Get-Content -LiteralPath $LastP -Raw).Trim()) }
  $r = G apply -R "-p$pl" '--whitespace=nowarn' $LastPatch
  if (-not $r.Ok) {
    $r = G apply -R "-p$pl" '--ignore-whitespace' '--whitespace=nowarn' $LastPatch
    if (-not $r.Ok) { Write-Host $r.Out; Die 'could not reverse the last run (files changed since?)' }
  }
  Remove-Item -LiteralPath $LastPatch, $LastP -Force -ErrorAction SilentlyContinue
  Info "last run reverted in $($script:Root)"
  Write-Host (G status --short).Out
  exit 0
}

# ---------- extract the diff ----------
$patch = ''
if ($restText -match '(?m)^`{3,}') {
  $ms = [regex]::Matches($restText, '(?ms)^`{3,}(?:diff|patch)[^\n]*\n(.*?)^`{3,}[ \t]*$')
  if ($ms.Count -gt 0) { $patch = (@($ms | ForEach-Object { $_.Groups[1].Value }) -join "`n") }
}
if ([string]::IsNullOrWhiteSpace($patch)) {
  $rl = $restText -split "`n"
  $start = -1
  for ($i = 0; $i -lt $rl.Count; $i++) { if ($rl[$i] -match '^(diff --git |--- )') { $start = $i; break } }
  if ($start -ge 0) {
    $patch = ((@($rl[$start..($rl.Count - 1)]) | Where-Object { $_ -notmatch '^`{3,}' }) -join "`n")
  }
}
if ([string]::IsNullOrWhiteSpace($patch)) { Die "no unified diff found below line 1 of $diffPath" }
if ($patch -notmatch '(?m)^(diff --git |--- |\+\+\+ |@@ )') { Die 'the text below line 1 does not look like a unified diff' }

$P = 0
if ($patch -match '(?m)^(diff --git a/|--- a/|\+\+\+ b/)') { $P = 1 }

# ---------- split per file ----------
$plines = $patch -split "`n"
$hasGit = $patch -match '(?m)^diff --git '
$chunkLines = New-Object System.Collections.Generic.List[object]
$cur = $null
for ($i = 0; $i -lt $plines.Count; $i++) {
  $l = $plines[$i]
  $startNew = $false
  if ($hasGit) { if ($l -match '^diff --git ') { $startNew = $true } }
  else { if ($l -match '^--- ' -and ($i + 1) -lt $plines.Count -and $plines[$i + 1] -match '^\+\+\+ ') { $startNew = $true } }
  if ($startNew) {
    $cur = New-Object System.Collections.Generic.List[string]
    $chunkLines.Add($cur)
  }
  if ($null -ne $cur) { $cur.Add($l) }
}
if ($chunkLines.Count -eq 0) { Die 'could not find any per-file diff' }

function Get-First([string]$t, [string[]]$patterns) {
  foreach ($re in $patterns) {
    $m = [regex]::Match($t, $re)
    if ($m.Success) { return $m.Groups[1].Value }
  }
  return $null
}

$items = @()
$n = 0
foreach ($cl in $chunkLines) {
  while ($cl.Count -gt 0 -and $cl[$cl.Count - 1] -eq '') { $cl.RemoveAt($cl.Count - 1) }
  $t = ($cl -join "`n") + "`n"
  $name = Get-First $t @('(?m)^\+\+\+ b/(.+?)[ \t]*$', '(?m)^--- a/(.+?)[ \t]*$', '(?m)^diff --git a/(.+?) b/', '(?m)^\+\+\+ (?!/dev/null)(\S.*?)[ \t]*$')
  if (-not $name) { $name = '(unknown)' }
  $kind = 'MOD'
  if ($t -match '(?m)^new file mode' -or $t -match '(?m)^--- /dev/null') { $kind = 'NEW' }
  elseif ($t -match '(?m)^deleted file mode' -or $t -match '(?m)^\+\+\+ /dev/null') { $kind = 'DEL' }
  elseif ($t -match '(?m)^rename from') { $kind = 'REN' }
  $paths = @()
  foreach ($re in @('(?m)^--- a/(.+?)[ \t]*$', '(?m)^\+\+\+ b/(.+?)[ \t]*$', '(?m)^rename from (.+?)[ \t]*$', '(?m)^rename to (.+?)[ \t]*$')) {
    foreach ($m in [regex]::Matches($t, $re)) { $paths += $m.Groups[1].Value }
  }
  if ($paths.Count -eq 0) { $paths = @($name) }
  $paths = @($paths | Select-Object -Unique)
  $n++
  $items += [pscustomobject]@{ Index = $n; Text = $t; Name = $name; Kind = $kind; Paths = $paths; File = $null }
}

$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('dw-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

try {
  foreach ($it in $items) {
    $it.File = Join-Path $tmpDir ('{0:D4}.diff' -f $it.Index)
    [IO.File]::WriteAllText($it.File, $it.Text, $utf8)
  }

  function Test-Chunk([string]$file, [string[]]$extra) {
    $a = @('apply', '--check', "-p$P", '--whitespace=nowarn') + $extra + @($file)
    G @a
  }
  # returns $null if not applicable, else array of extra flags (possibly empty)
  function Get-Mode([string]$file) {
    $r = Test-Chunk $file @()
    if ($r.Ok) { return ,@() }
    $r2 = Test-Chunk $file @('--ignore-whitespace')
    if ($r2.Ok) { return ,@('--ignore-whitespace') }
    return $null
  }
  function Test-Already([string]$file) { (Test-Chunk $file @('-R')).Ok }

  # ---------- show the plan ----------
  Write-Host "Diff file: $diffPath"
  Write-Host "Repo     : $($script:Root)"
  Write-Host "Files    : $($items.Count)"
  foreach ($it in $items) { Write-Host "  [$($it.Kind)] $($it.Name)" }
  if (-not [string]::IsNullOrWhiteSpace((G status --porcelain).Out)) {
    Warn 'the repo has uncommitted changes (they are left untouched)'
  }
  Write-Host ''

  if (-not $DryRun -and -not $Yes) {
    $ans = Read-Host 'Apply these changes to this repo? [Y/n]'
    if ($ans -ne '' -and $ans -notmatch '^(y|yes)$') { Write-Host 'Cancelled. Nothing was changed.'; exit 0 }
  }

  # ---------- strict pre-check ----------
  if ($Strict) {
    $bad = 0
    foreach ($it in $items) {
      $m = Get-Mode $it.File
      if ($null -eq $m -and -not (Test-Already $it.File)) {
        $bad++
        Tag 'FAIL' 'Red' $it.Name
        Write-Host ((Test-Chunk $it.File @()).Out -replace '(?m)^', '        ')
      }
    }
    if ($bad -gt 0) { Write-Host ''; Die "strict mode: $bad file(s) cannot be applied; nothing was changed" }
  }

  # ---------- branch ----------
  if ($Branch -and -not $DryRun) {
    $rb = G checkout -b $Branch
    if (-not $rb.Ok) { Die "could not create branch '$Branch' (already exists?)" }
    Info "switched to new branch $Branch"
  }

  # ---------- apply file by file ----------
  $applied = 0; $skipped = 0; $failed = 0
  $appliedText = New-Object System.Text.StringBuilder
  $appliedPaths = New-Object System.Collections.Generic.List[string]

  foreach ($it in $items) {
    $mode = Get-Mode $it.File
    if ($null -ne $mode) {
      $note = ''
      if ($mode.Count -gt 0) { $note = ' (whitespace-tolerant)' }
      if ($DryRun) {
        Tag ' OK ' 'Green' "would apply $($it.Kind) $($it.Name)$note"
        $applied++
        continue
      }
      $a = @('apply', "-p$P", '--whitespace=nowarn') + $mode + @($it.File)
      $ra = G @a
      if ($ra.Ok) {
        [void]$appliedText.Append($it.Text)
        foreach ($pp in $it.Paths) { $appliedPaths.Add($pp) }
        Tag ' OK ' 'Green' "$($it.Kind) $($it.Name)$note"
        $applied++
      }
      else {
        Tag 'FAIL' 'Red' $it.Name
        Write-Host ($ra.Out -replace '(?m)^', '        ')
        $failed++
      }
    }
    elseif (Test-Already $it.File) {
      Tag 'SKIP' 'Yellow' "$($it.Name) (already applied)"
      $skipped++
    }
    else {
      Tag 'FAIL' 'Red' $it.Name
      Write-Host ((Test-Chunk $it.File @()).Out -replace '(?m)^', '        ')
      $failed++
    }
  }

  if (-not $DryRun -and $appliedText.Length -gt 0) {
    [IO.File]::WriteAllText($LastPatch, $appliedText.ToString(), $utf8)
    Set-Content -LiteralPath $LastP -Value $P
  }

  if ($Commit -and -not $DryRun -and $applied -gt 0) {
    foreach ($pp in ($appliedPaths | Select-Object -Unique)) {
      $a = @('add', '-A', '--', $pp)
      $null = G @a
    }
    $rc = G commit -q -m $Commit
    if ($rc.Ok) { Info "committed: $Commit" } else { Warn 'nothing was committed' }
  }

  Write-Host ''
  if ($DryRun) {
    Write-Host "Dry run: $applied would apply, $skipped already applied, $failed cannot apply (nothing was changed)"
  }
  else {
    Write-Host "Done: $applied applied, $skipped skipped, $failed failed"
    if ($applied -gt 0) { Write-Host "Undo with: dw -u   (or: dw -u -r `"$($script:Root)`")" }
  }
  if ($failed -gt 0) { Write-Host 'For the failed files, send Claude their current content to get a fresh diff.' }

  if ($Archive -and -not $DryRun -and $failed -eq 0) {
    $newName = Join-Path (Split-Path -Parent $diffPath) ('diff.applied-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $diffPath -Destination $newName
    Info "diff file archived as $(Split-Path -Leaf $newName)"
  }

  if ($failed -gt 0) { exit 2 }
}
finally {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
