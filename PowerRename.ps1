#Requires -Version 5.1
<#
.SYNOPSIS
    PowerRename - Advanced file renaming tool for Windows Explorer.

.DESCRIPTION
    Interactive batch file renaming tool with:
      - Path switching and browsing
      - Prepend / Append / Replace numbering
      - Naming convention transforms (camelCase, snake_case, PascalCase, etc.)
      - Find & Replace with case-sensitivity, wildcard, and special-symbol support
      - Live preview before any rename
      - Full undo history

.NOTES
    Run from PowerShell:  .\PowerRename.ps1
    Or with a starting path: .\PowerRename.ps1 -StartPath "C:\Photos"
#>

[CmdletBinding()]
param(
    [string]$StartPath
)

# ── Strict mode & encoding ───────────────────────────────────────────────────
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ══════════════════════════════════════════════════════════════════════════════
#  GLOBALS
# ══════════════════════════════════════════════════════════════════════════════
$Script:CurrentPath    = if ($StartPath -and (Test-Path $StartPath)) { (Resolve-Path $StartPath).Path } else { (Get-Location).Path }
$Script:FileFilter     = '*'
$Script:IncludeFolders = $false
$Script:UndoStack      = [System.Collections.Generic.List[hashtable]]::new()

# The wildcard placeholder: uses the pipe character (|) which is invalid in
# Windows filenames, so it can never collide with real filename text.
$Script:WildcardChar = '|'

# ══════════════════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

function Write-Header {
    param([string]$Title)
    $rule = '─' * 60
    Write-Host ""
    Write-Host "  $rule" -ForegroundColor DarkCyan
    Write-Host "   $Title" -ForegroundColor Cyan
    Write-Host "  $rule" -ForegroundColor DarkCyan
}

function Write-Status {
    param([string]$Msg, [string]$Color = 'DarkGray')
    Write-Host "  $Msg" -ForegroundColor $Color
}

function Write-Prompt {
    param([string]$Msg)
    Write-Host ""
    Write-Host "  $Msg" -ForegroundColor Yellow -NoNewline
    Write-Host " " -NoNewline
}

function Get-TargetFiles {
    <# Returns the files (and optionally folders) in $Script:CurrentPath. #>
    $items = Get-ChildItem -Path $Script:CurrentPath -Filter $Script:FileFilter -File
    if ($Script:IncludeFolders) {
        $items = @(Get-ChildItem -Path $Script:CurrentPath -Filter $Script:FileFilter -File) +
                 @(Get-ChildItem -Path $Script:CurrentPath -Filter $Script:FileFilter -Directory)
    }
    return @($items | Sort-Object Name)
}

function Show-FileList {
    param([array]$Files)
    Write-Host ""
    if ($Files.Count -eq 0) {
        Write-Status "  (no matching files)" 'DarkYellow'
        return
    }
    $pad = ($Files.Count).ToString().Length
    for ($i = 0; $i -lt $Files.Count; $i++) {
        $idx   = ($i + 1).ToString().PadLeft($pad)
        $icon  = if ($Files[$i].PSIsContainer) { '[DIR] ' } else { '      ' }
        $name  = $Files[$i].Name
        Write-Host "   $idx. $icon$name" -ForegroundColor Gray
    }
}

function Show-Preview {
    <#
    .SYNOPSIS  Shows a side-by-side preview of old → new names.
    .OUTPUTS   Returns the rename map (array of hashtables) or $null if nothing to do.
    #>
    param([array]$Files, [scriptblock]$RenameLogic)

    $map = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($f in $Files) {
        $newName = & $RenameLogic $f
        if ($newName -and $newName -ne $f.Name) {
            $map.Add(@{ File = $f; OldName = $f.Name; NewName = $newName })
        }
    }

    if ($map.Count -eq 0) {
        Write-Status "No files would be changed." 'DarkYellow'
        return $null
    }

    Write-Host ""
    Write-Host "   PREVIEW" -ForegroundColor Green
    Write-Host "   ───────" -ForegroundColor Green
    $pad = ($map.Count).ToString().Length
    for ($i = 0; $i -lt $map.Count; $i++) {
        $idx = ($i + 1).ToString().PadLeft($pad)
        Write-Host "   $idx. " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($map[$i].OldName)" -NoNewline -ForegroundColor Red
        Write-Host "  →  " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($map[$i].NewName)" -ForegroundColor Green
    }
    Write-Host ""
    return ,$map
}

function Invoke-Rename {
    <# Executes a rename map and pushes to the undo stack. #>
    param([System.Collections.Generic.List[hashtable]]$Map)

    Write-Prompt "Apply these renames? (Y/n):"
    $confirm = Read-Host
    if ($confirm -and $confirm -notmatch '^[Yy]') {
        Write-Status "Cancelled." 'DarkYellow'
        return
    }

    $undoBatch = [System.Collections.Generic.List[hashtable]]::new()
    $errors    = 0

    foreach ($entry in $Map) {
        $src = $entry.File.FullName
        $dst = Join-Path $Script:CurrentPath $entry.NewName
        try {
            # Guard against name collisions
            if ((Test-Path $dst) -and ($src -ne $dst)) {
                Write-Host "   SKIP (name exists): $($entry.NewName)" -ForegroundColor Yellow
                $errors++
                continue
            }
            Rename-Item -LiteralPath $src -NewName $entry.NewName
            $undoBatch.Add(@{ Path = (Join-Path $Script:CurrentPath $entry.NewName); OldName = $entry.OldName })
        }
        catch {
            Write-Host "   ERROR: $($_.Exception.Message)" -ForegroundColor Red
            $errors++
        }
    }

    $ok = $Map.Count - $errors
    Write-Status "$ok file(s) renamed.  $errors error(s)." 'Green'

    if ($undoBatch.Count -gt 0) {
        $Script:UndoStack.Add(@{ Batch = $undoBatch })
    }
}

function Invoke-Undo {
    if ($Script:UndoStack.Count -eq 0) {
        Write-Status "Nothing to undo." 'DarkYellow'
        return
    }
    $batch = $Script:UndoStack[$Script:UndoStack.Count - 1].Batch
    Write-Host ""
    Write-Host "   UNDO PREVIEW" -ForegroundColor Magenta
    foreach ($entry in $batch) {
        $current = Split-Path $entry.Path -Leaf
        Write-Host "   $current  →  $($entry.OldName)" -ForegroundColor Magenta
    }

    Write-Prompt "Undo this batch? (Y/n):"
    $confirm = Read-Host
    if ($confirm -and $confirm -notmatch '^[Yy]') {
        Write-Status "Cancelled." 'DarkYellow'
        return
    }

    foreach ($entry in $batch) {
        try {
            Rename-Item -LiteralPath $entry.Path -NewName $entry.OldName
        }
        catch {
            Write-Host "   ERROR undoing $($entry.Path): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    $Script:UndoStack.RemoveAt($Script:UndoStack.Count - 1)
    Write-Status "Undo complete." 'Green'
}

# ══════════════════════════════════════════════════════════════════════════════
#  NAMING CONVENTION CONVERTERS
# ══════════════════════════════════════════════════════════════════════════════

function ConvertTo-Tokens {
    <# Splits a filename stem into word tokens. #>
    param([string]$Name)
    # Split on common delimiters and camelCase boundaries
    $s = $Name -replace '[-_.\s]+', ' '
    $s = $s -creplace '([a-z])([A-Z])', '$1 $2'
    $s = $s -creplace '([A-Z]+)([A-Z][a-z])', '$1 $2'
    return @($s.Trim() -split '\s+' | Where-Object { $_ -ne '' })
}

function ConvertTo-CamelCase   { param([string[]]$Tokens); ($Tokens | ForEach-Object -Begin {$i=0} -Process { if ($i -eq 0) { $_.ToLower() } else { $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower() }; $i++ }) -join '' }
function ConvertTo-PascalCase  { param([string[]]$Tokens); ($Tokens | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower() }) -join '' }
function ConvertTo-SnakeCase   { param([string[]]$Tokens); ($Tokens | ForEach-Object { $_.ToLower() }) -join '_' }
function ConvertTo-KebabCase   { param([string[]]$Tokens); ($Tokens | ForEach-Object { $_.ToLower() }) -join '-' }
function ConvertTo-DotCase     { param([string[]]$Tokens); ($Tokens | ForEach-Object { $_.ToLower() }) -join '.' }
function ConvertTo-TitleCase   { param([string[]]$Tokens); ($Tokens | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower() }) -join ' ' }
function ConvertTo-UpperSnake  { param([string[]]$Tokens); ($Tokens | ForEach-Object { $_.ToUpper() }) -join '_' }

# ══════════════════════════════════════════════════════════════════════════════
#  FIND & REPLACE ENGINE
# ══════════════════════════════════════════════════════════════════════════════

function Build-FindPattern {
    <#
    .SYNOPSIS
        Converts the user's search string into a regex.
        Supports:
          - Wildcard character (|) → matches any run of characters (.+)
          - Case-insensitive toggle
          - Literal special-symbol matching (all regex metachars are escaped)
    #>
    param(
        [string]$SearchText,
        [bool]$CaseSensitive,
        [bool]$WholeWord
    )

    # Split on the wildcard placeholder, escape each literal segment, rejoin
    $segments = $SearchText -split [regex]::Escape($Script:WildcardChar)
    $escaped  = $segments | ForEach-Object { [regex]::Escape($_) }
    $pattern  = $escaped -join '.+'  # wildcard = one-or-more of anything

    if ($WholeWord) {
        $pattern = "\b$pattern\b"
    }

    $options = [System.Text.RegularExpressions.RegexOptions]::None
    if (-not $CaseSensitive) {
        $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    }

    return [regex]::new($pattern, $options)
}

function Invoke-FindReplace {
    param(
        [string]$FileName,
        [regex]$Pattern,
        [string]$Replacement
    )
    return $Pattern.Replace($FileName, $Replacement)
}

# ══════════════════════════════════════════════════════════════════════════════
#  MENU ACTIONS
# ══════════════════════════════════════════════════════════════════════════════

function Show-PathBar {
    Write-Host ""
    Write-Host "  PATH: " -NoNewline -ForegroundColor DarkCyan
    Write-Host $Script:CurrentPath -ForegroundColor White
    Write-Host "  Filter: $Script:FileFilter   Folders: $(if ($Script:IncludeFolders) {'ON'} else {'OFF'})   Undo stack: $($Script:UndoStack.Count)" -ForegroundColor DarkGray
}

# ── 1. Change Path ───────────────────────────────────────────────────────────
function Menu-ChangePath {
    Write-Header "Change Working Path"
    Write-Status "Enter a full path, or a relative subfolder name."
    Write-Status "Type '..' to go up, or '~' for your home folder."
    Write-Prompt "New path:"
    $input_ = Read-Host

    if ([string]::IsNullOrWhiteSpace($input_)) { return }
    $target = switch ($input_) {
        '~'  { $env:USERPROFILE; break }
        '..' { Split-Path $Script:CurrentPath -Parent; break }
        default {
            if ([System.IO.Path]::IsPathRooted($input_)) { $input_ }
            else { Join-Path $Script:CurrentPath $input_ }
        }
    }

    if (Test-Path $target -PathType Container) {
        $Script:CurrentPath = (Resolve-Path $target).Path
        Write-Status "Switched to: $Script:CurrentPath" 'Green'
    }
    else {
        Write-Status "Path not found: $target" 'Red'
    }
}

# ── 2. Set Filter ────────────────────────────────────────────────────────────
function Menu-SetFilter {
    Write-Header "File Filter"
    Write-Status "Current filter: $Script:FileFilter"
    Write-Status "Examples:  *   *.jpg   *.txt   report*"
    Write-Prompt "Filter:"
    $f = Read-Host
    if (-not [string]::IsNullOrWhiteSpace($f)) {
        $Script:FileFilter = $f
    }
}

# ── 3. Toggle Folders ────────────────────────────────────────────────────────
function Menu-ToggleFolders {
    $Script:IncludeFolders = -not $Script:IncludeFolders
    Write-Status "Include folders: $(if ($Script:IncludeFolders) {'ON'} else {'OFF'})" 'Cyan'
}

# ── 4. List Files ────────────────────────────────────────────────────────────
function Menu-ListFiles {
    Write-Header "Files in Current Path"
    $files = Get-TargetFiles
    Show-FileList $files
    Write-Status "$($files.Count) item(s) match the current filter."
}

# ── 5. Numbering ─────────────────────────────────────────────────────────────
function Menu-Numbering {
    Write-Header "Numbering"
    Write-Host @"

   Modes
   ─────
   [1] Prepend number to existing name    001_photo.jpg
   [2] Append number to existing name     photo_001.jpg
   [3] Replace name with number + text    Vacation_001.jpg
   [0] Cancel

"@ -ForegroundColor Gray

    Write-Prompt "Mode:"
    $mode = Read-Host
    if ($mode -notin '1','2','3') { return }

    Write-Prompt "Start number (default 1):"
    $startStr = Read-Host
    $start = if ($startStr -match '^\d+$') { [int]$startStr } else { 1 }

    Write-Prompt "Step (default 1):"
    $stepStr = Read-Host
    $step = if ($stepStr -match '^\d+$') { [int]$stepStr } else { 1 }

    Write-Prompt "Zero-pad width (default 3, e.g. 001):"
    $padStr = Read-Host
    $padW = if ($padStr -match '^\d+$') { [int]$padStr } else { 3 }

    Write-Prompt "Separator between number and name (default '_'):"
    $sep = Read-Host
    if ([string]::IsNullOrEmpty($sep)) { $sep = '_' }

    $prefix = ''
    if ($mode -eq '3') {
        Write-Prompt "Base name (e.g. 'Vacation'):"
        $prefix = Read-Host
        if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = 'File' }
    }

    $files  = Get-TargetFiles
    $counter = $start

    $logic = {
        param($f)
        $num = $counter.ToString().PadLeft($padW, '0')
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $ext  = $f.Extension   # includes the dot

        switch ($mode) {
            '1' { "${num}${sep}${stem}${ext}" }
            '2' { "${stem}${sep}${num}${ext}" }
            '3' { "${prefix}${sep}${num}${ext}" }
        }
    }.GetNewClosure()

    # Build map manually so counter increments
    $map = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($f in $files) {
        $num  = $counter.ToString().PadLeft($padW, '0')
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $ext  = $f.Extension
        $newName = switch ($mode) {
            '1' { "${num}${sep}${stem}${ext}" }
            '2' { "${stem}${sep}${num}${ext}" }
            '3' { "${prefix}${sep}${num}${ext}" }
        }
        if ($newName -ne $f.Name) {
            $map.Add(@{ File = $f; OldName = $f.Name; NewName = $newName })
        }
        $counter += $step
    }

    if ($map.Count -eq 0) {
        Write-Status "No files would be changed." 'DarkYellow'
        return
    }

    # Show preview
    Write-Host ""
    Write-Host "   PREVIEW" -ForegroundColor Green
    Write-Host "   ───────" -ForegroundColor Green
    $pad = ($map.Count).ToString().Length
    for ($i = 0; $i -lt $map.Count; $i++) {
        $idx = ($i + 1).ToString().PadLeft($pad)
        Write-Host "   $idx. " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($map[$i].OldName)" -NoNewline -ForegroundColor Red
        Write-Host "  →  " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($map[$i].NewName)" -ForegroundColor Green
    }
    Write-Host ""

    Invoke-Rename $map
}

# ── 6. Find & Replace ────────────────────────────────────────────────────────
function Menu-FindReplace {
    Write-Header "Find & Replace"
    Write-Host ""
    Write-Status "Wildcard character:  $Script:WildcardChar  (pipe)"
    Write-Status "Use $($Script:WildcardChar) in your search to match any characters."
    Write-Status "Example:  'IMG${Script:WildcardChar}2024'  matches  IMG_0042_2024, IMG-Shot-2024, etc."
    Write-Host ""

    Write-Prompt "Search for:"
    $search = Read-Host
    if ([string]::IsNullOrWhiteSpace($search)) { return }

    Write-Prompt "Replace with:"
    $replace = Read-Host

    Write-Prompt "Case-sensitive? (y/N):"
    $cs = Read-Host
    $caseSensitive = $cs -match '^[Yy]'

    Write-Prompt "Whole-word match? (y/N):"
    $ww = Read-Host
    $wholeWord = $ww -match '^[Yy]'

    Write-Prompt "Apply to extensions too? (y/N):"
    $ae = Read-Host
    $applyToExt = $ae -match '^[Yy]'

    try {
        $regex = Build-FindPattern -SearchText $search -CaseSensitive $caseSensitive -WholeWord $wholeWord
    }
    catch {
        Write-Status "Invalid pattern: $($_.Exception.Message)" 'Red'
        return
    }

    $files = Get-TargetFiles

    $renameLogic = {
        param($f)
        if ($applyToExt) {
            return Invoke-FindReplace -FileName $f.Name -Pattern $regex -Replacement $replace
        }
        else {
            $stem    = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            $ext     = $f.Extension
            $newStem = Invoke-FindReplace -FileName $stem -Pattern $regex -Replacement $replace
            return "${newStem}${ext}"
        }
    }.GetNewClosure()

    $map = Show-Preview $files $renameLogic
    if ($null -ne $map) {
        Invoke-Rename $map
    }
}

# ── 7. Naming Conventions ────────────────────────────────────────────────────
function Menu-Convention {
    Write-Header "Naming Convention Transform"
    Write-Host @"

   Styles
   ──────
   [1] camelCase              myFileName
   [2] PascalCase             MyFileName
   [3] snake_case             my_file_name
   [4] kebab-case             my-file-name
   [5] dot.case               my.file.name
   [6] Title Case             My File Name
   [7] UPPER_SNAKE_CASE       MY_FILE_NAME
   [8] lowercase              myfilename
   [9] UPPERCASE              MYFILENAME
   [0] Cancel

"@ -ForegroundColor Gray

    Write-Prompt "Style:"
    $style = Read-Host
    if ($style -notin '1','2','3','4','5','6','7','8','9') { return }

    $files = Get-TargetFiles

    $renameLogic = {
        param($f)
        $stem   = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $ext    = $f.Extension
        $tokens = ConvertTo-Tokens $stem
        if ($tokens.Count -eq 0) { return $f.Name }

        $newStem = switch ($style) {
            '1' { ConvertTo-CamelCase $tokens }
            '2' { ConvertTo-PascalCase $tokens }
            '3' { ConvertTo-SnakeCase $tokens }
            '4' { ConvertTo-KebabCase $tokens }
            '5' { ConvertTo-DotCase $tokens }
            '6' { ConvertTo-TitleCase $tokens }
            '7' { ConvertTo-UpperSnake $tokens }
            '8' { ($tokens | ForEach-Object { $_.ToLower() }) -join '' }
            '9' { ($tokens | ForEach-Object { $_.ToUpper() }) -join '' }
        }
        return "${newStem}${ext}"
    }.GetNewClosure()

    $map = Show-Preview $files $renameLogic
    if ($null -ne $map) {
        Invoke-Rename $map
    }
}

# ── 8. Change Extension ──────────────────────────────────────────────────────
function Menu-ChangeExtension {
    Write-Header "Change File Extension"
    Write-Prompt "New extension (e.g. .txt, .bak):"
    $newExt = Read-Host
    if ([string]::IsNullOrWhiteSpace($newExt)) { return }
    if (-not $newExt.StartsWith('.')) { $newExt = ".$newExt" }

    $files = Get-TargetFiles

    $renameLogic = {
        param($f)
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        return "${stem}${newExt}"
    }.GetNewClosure()

    $map = Show-Preview $files $renameLogic
    if ($null -ne $map) {
        Invoke-Rename $map
    }
}

# ── 9. Trim / Pad ────────────────────────────────────────────────────────────
function Menu-TrimPad {
    Write-Header "Trim / Insert Characters"
    Write-Host @"

   Options
   ───────
   [1] Remove first N characters
   [2] Remove last N characters
   [3] Insert text at position
   [4] Trim whitespace / clean up names
   [0] Cancel

"@ -ForegroundColor Gray

    Write-Prompt "Option:"
    $opt = Read-Host

    $files = Get-TargetFiles

    switch ($opt) {
        '1' {
            Write-Prompt "Remove how many characters from the start?"
            $n = [int](Read-Host)
            $logic = { param($f)
                $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                $ext  = $f.Extension
                if ($stem.Length -le $n) { return $f.Name }
                return $stem.Substring($n) + $ext
            }.GetNewClosure()
        }
        '2' {
            Write-Prompt "Remove how many characters from the end?"
            $n = [int](Read-Host)
            $logic = { param($f)
                $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                $ext  = $f.Extension
                if ($stem.Length -le $n) { return $f.Name }
                return $stem.Substring(0, $stem.Length - $n) + $ext
            }.GetNewClosure()
        }
        '3' {
            Write-Prompt "Text to insert:"
            $txt = Read-Host
            Write-Prompt "Position (0 = start):"
            $pos = [int](Read-Host)
            $logic = { param($f)
                $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                $ext  = $f.Extension
                $p = [Math]::Min($pos, $stem.Length)
                return $stem.Insert($p, $txt) + $ext
            }.GetNewClosure()
        }
        '4' {
            $logic = { param($f)
                $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                $ext  = $f.Extension
                # Collapse multiple spaces/underscores, trim edges
                $clean = ($stem -replace '[\s_]+', ' ').Trim()
                return "${clean}${ext}"
            }.GetNewClosure()
        }
        default { return }
    }

    $map = Show-Preview $files $logic
    if ($null -ne $map) {
        Invoke-Rename $map
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN MENU LOOP
# ══════════════════════════════════════════════════════════════════════════════

function Show-MainMenu {
    Clear-Host
    Write-Host ""
    Write-Host "   ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "   ║         P O W E R   R E N A M E         ║" -ForegroundColor Cyan
    Write-Host "   ╚══════════════════════════════════════════╝" -ForegroundColor Cyan

    Show-PathBar

    Write-Host @"

   ── Navigation ──────────────────────────
   [1]  Change working path
   [2]  Set file filter            ($Script:FileFilter)
   [3]  Toggle include folders     ($(if ($Script:IncludeFolders) {'ON'} else {'OFF'}))
   [4]  List matching files

   ── Rename Operations ───────────────────
   [5]  Numbering  (prepend / append / replace)
   [6]  Find & Replace  (wildcards, case, symbols)
   [7]  Naming conventions  (camelCase, snake_case …)
   [8]  Change extension
   [9]  Trim / Insert characters

   ── Other ───────────────────────────────
   [U]  Undo last rename
   [Q]  Quit

"@ -ForegroundColor Gray

    Write-Prompt "Choice:"
}

# ── Entry point ──────────────────────────────────────────────────────────────
$running = $true
while ($running) {
    Show-MainMenu
    $choice = Read-Host

    switch ($choice.ToUpper()) {
        '1' { Menu-ChangePath }
        '2' { Menu-SetFilter }
        '3' { Menu-ToggleFolders }
        '4' { Menu-ListFiles }
        '5' { Menu-Numbering }
        '6' { Menu-FindReplace }
        '7' { Menu-Convention }
        '8' { Menu-ChangeExtension }
        '9' { Menu-TrimPad }
        'U' { Invoke-Undo }
        'Q' { $running = $false }
        default { Write-Status "Invalid choice." 'Red' }
    }

    if ($running) {
        Write-Host ""
        Write-Host "  Press Enter to continue…" -ForegroundColor DarkGray -NoNewline
        Read-Host
    }
}

Write-Host ""
Write-Host "  Goodbye." -ForegroundColor Cyan
Write-Host ""
