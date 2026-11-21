<#
.SYNOPSIS
    Builds the files to publish on GitHub Pages: the nar, the network update files and the files they list.
.DESCRIPTION
    Reads the files tracked by git (submodules included), then:
      - the nar          = tracked files that .narignore does not exclude
      - the update files = tracked files that .updateignore does not exclude
                           (.updateignore starts from .narignore with "include:" and may re-include files)
    and writes this layout under -OutDir, which is what "homeurl" points to:
      shiories.nar            the archive (name from "directory" in install.txt)
      updates2.dau            network update list  (path, MD5, size, date)
      updates.txt             the same list in the older text format
      delete.txt, ghost/..., shell/ ...  the files in the list, at the same relative paths
      <balloon>/updates2.dau, updates.txt and the balloon files
                              for each balloon bundled by install.txt (balloon.directory); the balloon is not
                              in the update files of the ghost, and its descript.txt has its own "homeurl"
      .ukagaka/               the metainfo folder (metainfo-standard): the tracked files of .ukagaka/, copied as they
                              are. It is not in the nar or the update files (.narignore), and not in the list
                              above; "metainfo" in the ghost descript.txt points here
      index.html, .nojekyll
    The introduction page of the ghost (the folder -IntroDir, "site" by default) is copied over the output, so its
    index.html replaces the plain one above. It is not part of the nar or the update files (.narignore).
    The rule syntax is the one of SSP: gitignore syntax ("!", "*", "?", "[]", "**", leading and trailing "/")
    plus the line "include:<file>" (nested up to 3 levels). Matching is case-insensitive. Git metadata and
    profile folders are always excluded.
    The script needs nothing but git and PowerShell (Windows PowerShell 5.1 or PowerShell 7).
    Only ASCII characters are used in this file, so that Windows PowerShell 5.1 reads it correctly.
.EXAMPLE
    pwsh ./.github/scripts/build-site.ps1 -OutDir build/site
.EXAMPLE
    pwsh ./.github/scripts/build-site.ps1 -ListOnly
#>
[CmdletBinding()]
param(
    # Ghost root: the folder that holds ghost/, shell/ and install.txt (default: two levels above this script).
    [string]$Root,
    # Output folder (created; must not be inside the files being listed). "site" is the introduction page, so not that.
    [string]$OutDir = 'build/site',
    # Introduction page: this folder (relative to -Root) is copied over the output when it exists.
    [string]$IntroDir = 'site',
    # Name of the nar (default: <directory in install.txt>.nar).
    [string]$NarName,
    # Print the included and excluded files of each list and write nothing.
    [switch]$ListOnly
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not $Root) {
    # $PSScriptRoot is empty in a param() default in Windows PowerShell 5.1, so it is resolved here
    $Root = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '../..'
}
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
$utf8 = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------- ignore rules (same semantics as SSP)
$MaxIncludeDepth = 3

function ConvertFrom-IgnoreGlob([string]$Glob) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $Glob.Length) {
        $c = $Glob[$i]
        if ($c -eq '*' -and $i + 1 -lt $Glob.Length -and $Glob[$i + 1] -eq '*') {
            $atSegmentStart = ($i -eq 0) -or ($Glob[$i - 1] -eq '/')
            $next = $null
            if ($i + 2 -lt $Glob.Length) { $next = $Glob[$i + 2] }
            if ($atSegmentStart -and $next -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 3; continue }
            if ($atSegmentStart -and $null -eq $next) { [void]$sb.Append('.*'); $i += 2; continue }
            [void]$sb.Append('[^/]*'); $i += 2; continue
        }
        if ($c -eq '*') {
            [void]$sb.Append('[^/]*')
        } elseif ($c -eq '?') {
            [void]$sb.Append('[^/]')
        } elseif ($c -eq '[' -and $i + 2 -lt $Glob.Length -and $Glob.IndexOf(']', $i + 2) -gt 0) {
            $end = $Glob.IndexOf(']', $i + 2)
            $body = $Glob.Substring($i + 1, $end - $i - 1)
            if ($body.StartsWith('!')) { $body = '^' + $body.Substring(1) }
            [void]$sb.Append('[' + $body + ']')
            $i = $end
        } elseif ($c -eq '\' -and $i + 1 -lt $Glob.Length) {
            $i++
            [void]$sb.Append([regex]::Escape([string]$Glob[$i]))
        } else {
            [void]$sb.Append([regex]::Escape([string]$c))
        }
        $i++
    }
    return $sb.ToString()
}

function Add-IgnoreFileRules($Rules, [string]$Path, [int]$Depth) {
    if ($Depth -gt $MaxIncludeDepth) {
        Write-Warning "include: is nested more than $MaxIncludeDepth levels; not read: $Path"
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "ignore file not found: $Path"
    }
    $folder = Split-Path $Path -Parent
    foreach ($rawLine in [IO.File]::ReadAllLines($Path, $utf8)) {
        $line = $rawLine.TrimStart([char]0xFEFF)
        if ($line.StartsWith('include:')) {
            $includePath = $line.Substring(8).Trim().Replace('\', '/')
            if ($includePath) { Add-IgnoreFileRules $Rules (Join-Path $folder $includePath) ($Depth + 1) }
            continue
        }
        $line = [regex]::Replace($line, '(?<!\\)[ \t]+$', '')
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $negate = $false
        if ($line.StartsWith('!')) {
            $negate = $true
            $line = $line.Substring(1)
        } elseif ($line.StartsWith('\!') -or $line.StartsWith('\#')) {
            $line = $line.Substring(1)
        }
        $directoryOnly = $line.EndsWith('/')
        $line = $line.TrimEnd('/')
        if ($line -eq '') { continue }
        # A "/" at the beginning or in the middle anchors the pattern to the root.
        $anchored = $line.Contains('/')
        $body = ConvertFrom-IgnoreGlob $line.TrimStart('/')
        if ($anchored) { $pattern = '^' + $body + '$' } else { $pattern = '(?:^|/)' + $body + '$' }
        $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
        $Rules.Add([pscustomobject]@{
                Regex         = New-Object System.Text.RegularExpressions.Regex($pattern, $options)
                Negate        = $negate
                DirectoryOnly = $directoryOnly
            })
    }
}

function New-IgnoreMatcher([string]$FileName) {
    $rules = New-Object System.Collections.Generic.List[object]
    Add-IgnoreFileRules $rules (Join-Path $Root $FileName) 0
    return [pscustomobject]@{ Rules = $rules; DirectoryCache = @{} }
}

# The last matching rule wins.
function Test-IgnoreRule($Rules, [string]$Path, [bool]$IsDirectory) {
    $ignored = $false
    foreach ($rule in $Rules) {
        if ($rule.DirectoryOnly -and -not $IsDirectory) { continue }
        if ($rule.Regex.IsMatch($Path)) { $ignored = -not $rule.Negate }
    }
    return $ignored
}

# Tests a root-relative file path ("a/b/c.txt"). As in git, a file inside an ignored directory cannot be
# re-included by a negated pattern.
function Test-Ignored($Matcher, [string]$RelativePath) {
    $segments = $RelativePath.Split('/')
    # Always excluded, as SSP does: git metadata and profile folders.
    if ($segments -contains '.git') { return $true }
    if ($segments.Count -ge 2 -and ($segments[0..($segments.Count - 2)] -contains 'profile')) { return $true }
    $directory = ''
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        if ($i -eq 0) { $directory = $segments[0] } else { $directory = $directory + '/' + $segments[$i] }
        if (-not $Matcher.DirectoryCache.ContainsKey($directory)) {
            $Matcher.DirectoryCache[$directory] = Test-IgnoreRule $Matcher.Rules $directory $true
        }
        if ($Matcher.DirectoryCache[$directory]) { return $true }
    }
    return (Test-IgnoreRule $Matcher.Rules $RelativePath $false)
}

# ---------------------------------------------------------------- tracked files
$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $git) { throw 'git was not found' }
if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { throw "not a git working copy: $Root" }

$listed = & $git.Source -C $Root ls-files -z --recurse-submodules
if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed' }
$files = New-Object System.Collections.Generic.List[string]
foreach ($path in ([string]::Join('', $listed)).Split([char]0)) {
    if ($path -and (Test-Path -LiteralPath (Join-Path $Root $path) -PathType Leaf)) { $files.Add($path) }
}
$files = @($files | Sort-Object -Unique)
if ($files.Count -eq 0) { throw 'no tracked files' }

$narMatcher = New-IgnoreMatcher '.narignore'
$updMatcher = New-IgnoreMatcher '.updateignore'
# No rules: only the always-excluded paths (git metadata, profile folders) are ignored
$noRules = [pscustomobject]@{ Rules = (New-Object System.Collections.Generic.List[object]); DirectoryCache = @{} }
$narFiles = @($files | Where-Object { -not (Test-Ignored $narMatcher $_) })
$updFiles = @($files | Where-Object { -not (Test-Ignored $updMatcher $_) })

if ($narFiles -notcontains 'install.txt') { throw 'install.txt is not in the nar' }
if ($updFiles -notcontains 'delete.txt') { Write-Warning 'delete.txt is not in the update files' }

# Balloons that come with the nar: "balloon.directory,NAME" in install.txt is the name after installation, and
# "balloon.source.directory,DIR" (default: NAME) is the folder in the archive. Each gets its own update files,
# published in the folder NAME of the site, so that the balloon descript.txt can point its "homeurl" there.
# The ghost update files must not contain them (see .updateignore).
$balloons = @()
$installLines = [IO.File]::ReadAllLines((Join-Path $Root 'install.txt'), $utf8)
foreach ($line in $installLines) {
    if ($line -match '^\s*(balloon\d*)\.directory\s*,\s*(.+?)\s*$') {
        $key = $Matches[1]
        $name = $Matches[2]
        $source = $name
        foreach ($other in $installLines) {
            if ($other -match ('^\s*' + [regex]::Escape($key) + '\.source\.directory\s*,\s*(.+?)\s*$')) { $source = $Matches[1] }
        }
        $source = $source.Replace('\', '/').Trim('/')
        # The update files kept in the balloon folder for the old homeurl are not part of the balloon: they are written below.
        $balloonFiles = @($files | Where-Object {
                $_.StartsWith($source + '/', [StringComparison]::OrdinalIgnoreCase) -and
                (@('updates2.dau', 'updates.txt') -notcontains $_.Substring($source.Length + 1)) -and
                -not (Test-Ignored $noRules $_)
            })
        if ($balloonFiles.Count -eq 0) { Write-Warning "balloon folder has no tracked files: $source"; continue }
        $inGhostList = @($updFiles | Where-Object { $_.StartsWith($source + '/', [StringComparison]::OrdinalIgnoreCase) })
        if ($inGhostList.Count -gt 0) { throw "the ghost update files contain the balloon folder $source (add it to .updateignore)" }
        $balloons += [pscustomobject]@{ Name = $name; Source = $source; Files = $balloonFiles }
    }
}

Write-Host ("tracked files   : {0}" -f $files.Count)
Write-Host ("nar             : {0} included, {1} excluded (.narignore)" -f $narFiles.Count, ($files.Count - $narFiles.Count))
Write-Host ("update files    : {0} included, {1} excluded (.updateignore)" -f $updFiles.Count, ($files.Count - $updFiles.Count))
foreach ($b in $balloons) {
    Write-Host ("balloon {0}: {1} files (own update files)" -f $b.Name, $b.Files.Count)
}

if ($ListOnly) {
    foreach ($b in $balloons) {
        Write-Host ("== balloon {0} ==" -f $b.Name)
        $b.Files | ForEach-Object { '  ' + $_.Substring($b.Source.Length + 1) }
    }
    Write-Host '== nar =='
    $narFiles | ForEach-Object { '  ' + $_ }
    Write-Host '== update files =='
    $updFiles | ForEach-Object { '  ' + $_ }
    Write-Host '== only in nar =='
    $narFiles | Where-Object { $updFiles -notcontains $_ } | ForEach-Object { '  ' + $_ }
    Write-Host '== only in update files =='
    $updFiles | Where-Object { $narFiles -notcontains $_ } | ForEach-Object { '  ' + $_ }
    exit 0
}

# ---------------------------------------------------------------- output
if (-not $NarName) {
    $directory = $null
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $Root 'install.txt'), $utf8)) {
        if ($line -match '^\s*directory\s*,\s*(.+?)\s*$') { $directory = $Matches[1]; break }
    }
    if (-not $directory) { $directory = 'ghost' }
    $NarName = $directory + '.nar'
}
if (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path (Get-Location).Path $OutDir }
$OutDir = [IO.Path]::GetFullPath($OutDir)
if ($OutDir.StartsWith($Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    $rel = $OutDir.Substring($Root.Length + 1).Replace('\', '/')
    if (-not (Test-Ignored $narMatcher ($rel + '/x')) -or -not (Test-Ignored $updMatcher ($rel + '/x'))) {
        Write-Warning "OutDir is inside the ghost folder and is not excluded by .narignore/.updateignore: $rel"
    }
}
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir | Out-Null

# nar: entry names use "/", paths are relative to the ghost root
$narPath = Join-Path $OutDir $NarName
$zip = [IO.Compression.ZipFile]::Open($narPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in $narFiles) {
        $source = Join-Path $Root $relative
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $source, $relative, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $zip.Dispose()
}
Write-Host ("wrote {0} ({1} KB)" -f $narPath, [math]::Round((Get-Item -LiteralPath $narPath).Length / 1KB))

# update files: copy each file into $DestDir at the path it has in the list, and describe it
# (path, MD5, size, date). As SSP does, the first record also says the charset of the list itself.
# $Items: objects with Source (path relative to the ghost root) and Name (path in the list)
$sep = [string][char]1
function Write-UpdateSet([string]$DestDir, $Items) {
    $dau = New-Object System.Text.StringBuilder
    $txt = New-Object System.Text.StringBuilder
    [void]$txt.Append("charset,UTF-8`r`n")
    $first = $true
    foreach ($item in $Items) {
        $source = Join-Path $Root $item.Source
        $target = Join-Path $DestDir $item.Name
        $targetDir = Split-Path $target -Parent
        if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        Copy-Item -LiteralPath $source -Destination $target -Force
        $info = Get-Item -LiteralPath $source
        $md5 = (Get-FileHash -LiteralPath $source -Algorithm MD5).Hash.ToLowerInvariant()
        $date = $info.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss')
        $record = $item.Name + $sep + $md5 + $sep + 'size=' + $info.Length + $sep + 'date=' + $date + $sep
        if ($first) { $record += 'charset=UTF-8' + $sep; $first = $false }
        $record += "`r`n"
        [void]$dau.Append($record)
        [void]$txt.Append('file,' + $record)
    }
    [IO.File]::WriteAllText((Join-Path $DestDir 'updates2.dau'), $dau.ToString(), $utf8)
    [IO.File]::WriteAllText((Join-Path $DestDir 'updates.txt'), $txt.ToString(), $utf8)
}

Write-UpdateSet $OutDir @($updFiles | ForEach-Object { [pscustomobject]@{ Source = $_; Name = $_ } })
Write-Host ("wrote updates2.dau and updates.txt ({0} files)" -f $updFiles.Count)
foreach ($b in $balloons) {
    $dest = Join-Path $OutDir $b.Name
    $prefixLength = $b.Source.Length + 1
    Write-UpdateSet $dest @($b.Files | ForEach-Object { [pscustomobject]@{ Source = $_; Name = $_.Substring($prefixLength) } })
    Write-Host ("wrote {0}/updates2.dau and updates.txt ({1} files)" -f $b.Name, $b.Files.Count)
}

# GitHub Pages: do not run Jekyll (it would hide files and folders whose names start with "_" or ".")
[IO.File]::WriteAllText((Join-Path $OutDir '.nojekyll'), '', $utf8)
$balloonLinks = ''
foreach ($b in $balloons) {
    $balloonLinks += "<p>Balloon $($b.Name), files for network update: <a href=""$($b.Name)/updates2.dau"">$($b.Name)/updates2.dau</a></p>`n"
}
$index = @"
<!doctype html>
<meta charset="utf-8">
<title>$NarName</title>
<p><a href="$NarName">$NarName</a></p>
<p>Files for network update: <a href="updates2.dau">updates2.dau</a></p>
$balloonLinks
"@
[IO.File]::WriteAllText((Join-Path $OutDir 'index.html'), $index, $utf8)

# Metainfo folder: published as it is, next to (not inside) the update files. The folder name starts with "."
# (hence .nojekyll above, and actions/upload-pages-artifact must be v3: v4 leaves out hidden files).
$metainfoFiles = @($files | Where-Object { $_.StartsWith('.ukagaka/', [StringComparison]::Ordinal) })
foreach ($relative in $metainfoFiles) {
    $target = Join-Path $OutDir $relative
    $targetDir = Split-Path $target -Parent
    if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $Root $relative) -Destination $target -Force
}
if ($metainfoFiles.Count -gt 0) { Write-Host ("copied the metainfo folder: .ukagaka ({0} files)" -f $metainfoFiles.Count) }
else { Write-Warning '.ukagaka/ has no tracked files: the metainfo folder is not published' }

# Introduction page: replaces the plain index.html above and adds its images
$intro = Join-Path $Root $IntroDir
if (Test-Path -LiteralPath $intro -PathType Container) {
    Copy-Item -Path (Join-Path $intro '*') -Destination $OutDir -Recurse -Force
    Write-Host "copied the introduction page: $IntroDir"
}
Write-Host "done: $OutDir"
