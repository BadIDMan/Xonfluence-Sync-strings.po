param (
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Yes", "No", IgnoreCase = $true)]
    [string]$Backup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Xonfluence strings.po synchronization script
#
# Usage:
#
#   .\xonfluence_sync_strings.po.ps1 `
#       -Path "C:\Users\username\AppData\Roaming\Kodi\addons\skin.xonfluence\language" `
#       -Backup "Yes"
#
#   or
#
#   .\xonfluence_sync_strings.po.ps1 `
#       -Path "C:\Users\username\AppData\Roaming\Kodi\addons\skin.xonfluence\language" `
#       -Backup "No"
#
#
# Source of truth:
#   resource.language.en_gb\strings.po
#
# For all other language files:
#
#   - preserve their own PO header
#   - use IDs, msgids and order from en_GB
#   - preserve existing msgstr translations
#   - add missing IDs with empty msgstr
#   - remove IDs no longer present in en_GB
#   - copy the footer from en_GB
#
# en_GB itself is never modified.
#
# If -Backup Yes is specified:
#
#   strings.po -> strings-backup.po
#
# The backup is an exact copy of the original file made immediately
# before synchronization.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Helper: parse PO entries
# The first normal entry is identified by:
#   msgctxt "#<number>"
# Everything before that is treated as the PO header.
# Each entry ends after its msgstr block. Any following footer content
# therefore remains outside the PO entries.
# ---------------------------------------------------------------------------

function Parse-PoEntries {
    param (
        [string[]]$Lines,
        [int]$StartIndex
    )

    $entries = @()
    $i = $StartIndex

    while ($i -lt $Lines.Count) {

        while (
            $i -lt $Lines.Count -and
            (
                [string]::IsNullOrWhiteSpace($Lines[$i]) -or
                $Lines[$i] -match '^\s*#'
            )
        ) {
            $i++
        }

        if ($i -ge $Lines.Count) {
            break
        }

        if ($Lines[$i] -notmatch '^msgctxt\s+"#\d+"\s*$') {
            break
        }

        $entryLines = New-Object System.Collections.Generic.List[string]
        $entryStart = $i
        $foundMsgStr = $false

        while ($i -lt $Lines.Count) {

            # A new PO entry starts here.
            if (
                $i -gt $entryStart -and
                $Lines[$i] -match '^msgctxt\s+"#\d+"\s*$'
            ) {
                break
            }

            # Once msgstr has been found, only its continuation lines
            # belong to the entry. The first non-quoted line ends it.
            if ($foundMsgStr) {
                if ($Lines[$i] -match '^"') {
                    $entryLines.Add($Lines[$i])
                    $i++
                    continue
                }

                break
            }

            $entryLines.Add($Lines[$i])

            if ($Lines[$i] -match '^msgstr\s+') {
                $foundMsgStr = $true
            }

            $i++
        }

        if (-not $foundMsgStr) {
            throw "No msgstr found in PO entry beginning at line $($entryStart + 1)."
        }

        $msgctxt = $null
        foreach ($line in $entryLines) {
            if ($line -match '^msgctxt\s+"#(\d+)"\s*$') {
                $msgctxt = $Matches[1]
                break
            }
        }

        if ($null -eq $msgctxt) {
            throw "Could not determine msgctxt for PO entry beginning at line $($entryStart + 1)."
        }

        $msgidLines = New-Object System.Collections.Generic.List[string]
        $insideMsgId = $false
        foreach ($line in $entryLines) {
            if ($line -match '^msgid\s+') {
                $insideMsgId = $true
                $msgidLines.Add($line)
                continue
            }
            if ($insideMsgId) {
                if ($line -match '^msgstr\s+') {
                    break
                }
                if ($line -match '^"') {
                    $msgidLines.Add($line)
                }
            }
        }
        $msgid = $msgidLines -join "`n"

        $msgstrLines = New-Object System.Collections.Generic.List[string]
        $insideMsgStr = $false
        foreach ($line in $entryLines) {
            if ($line -match '^msgstr\s+') {
                $insideMsgStr = $true
                $msgstrLines.Add($line)
                continue
            }
            if ($insideMsgStr -and $line -match '^"') {
                $msgstrLines.Add($line)
            }
        }
        $msgstr = $msgstrLines -join "`n"

        $entries += [PSCustomObject]@{
            Id     = $msgctxt
            MsgId  = $msgid
            MsgStr = $msgstr
            Lines  = @($entryLines)
        }
    }

    return ,$entries
}

# ---------------------------------------------------------------------------
# Helper: get footer
#
# The footer is everything after the last PO entry.
#
# The last PO entry ends after its msgstr block.
# Everything after that belongs to the footer.
# ---------------------------------------------------------------------------
function Get-PoFooter {
    param (
        [string[]]$Lines
    )

    $lastEntryStart = -1

    # Find the last msgctxt "#number"
    for ($i = 0; $i -lt $Lines.Count; $i++) {

        if ($Lines[$i] -match '^msgctxt\s+"#\d+"\s*$') {
            $lastEntryStart = $i
        }
    }

    if ($lastEntryStart -lt 0) {
        throw "Could not find the last PO entry."
    }

    # Find the msgstr of the last entry
    $msgStrStart = -1
    $msgStrEnd = -1

    for ($i = $lastEntryStart; $i -lt $Lines.Count; $i++) {

        if ($Lines[$i] -match '^msgstr\s+') {

            $msgStrStart = $i
            $msgStrEnd = $i

            # Include following multiline msgstr lines
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {

                if ($Lines[$j] -match '^"') {
                    $msgStrEnd = $j
                }
                else {
                    break
                }
            }

            break
        }
    }

    if ($msgStrStart -lt 0) {
        throw "Could not find msgstr in the last PO entry."
    }

    # Footer starts immediately after the last msgstr block.
    $footerStart = $msgStrEnd + 1

    # Remove blank separator lines between the last entry and the footer.
    while (
        $footerStart -lt $Lines.Count -and
        [string]::IsNullOrWhiteSpace($Lines[$footerStart])
    ) {
        $footerStart++
    }

    if ($footerStart -ge $Lines.Count) {
        return @()
    }

    return @($Lines[$footerStart..($Lines.Count - 1)])
}

# ---------------------------------------------------------------------------
# Helper: replace msgstr in an entry
# ---------------------------------------------------------------------------
function Replace-PoMsgStr {
    param (
        [string[]]$SourceEntryLines,
        [string]$TargetMsgStr
    )

    $result = New-Object System.Collections.Generic.List[string]

    $msgStrStart = -1
    $msgStrEnd = -1

    # Find msgstr
    for ($i = 0; $i -lt $SourceEntryLines.Count; $i++) {

        if ($SourceEntryLines[$i] -match '^msgstr\s+') {

            $msgStrStart = $i
            $msgStrEnd = $i

            # Include following multiline strings
            for ($j = $i + 1; $j -lt $SourceEntryLines.Count; $j++) {

                if ($SourceEntryLines[$j] -match '^"') {
                    $msgStrEnd = $j
                }
                else {
                    break
                }
            }

            break
        }
    }

    if ($msgStrStart -lt 0) {
        throw "No msgstr found in PO entry."
    }

    # Lines before msgstr
    if ($msgStrStart -gt 0) {

        for ($i = 0; $i -lt $msgStrStart; $i++) {
            $result.Add($SourceEntryLines[$i])
        }
    }

    # Target msgstr
    foreach ($line in ($TargetMsgStr -split "`n")) {
        $result.Add($line)
    }

    # Lines after old msgstr
    if ($msgStrEnd + 1 -lt $SourceEntryLines.Count) {

        for ($i = $msgStrEnd + 1; $i -lt $SourceEntryLines.Count; $i++) {
            $result.Add($SourceEntryLines[$i])
        }
    }

    return ,$result
}

# ---------------------------------------------------------------------------
# Validate language root
# ---------------------------------------------------------------------------
$languageRoot = [System.IO.Path]::GetFullPath($Path)

if (-not (Test-Path -LiteralPath $languageRoot -PathType Container)) {
    throw "Language folder does not exist: $languageRoot"
}

# ---------------------------------------------------------------------------
# Locate source
# ---------------------------------------------------------------------------
$sourceFile = Join-Path $languageRoot "resource.language.en_gb\strings.po"

if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
    throw "Source file not found: $sourceFile"
}

# ---------------------------------------------------------------------------
# Read source en_GB
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Xonfluence strings.po synchronization"
Write-Host "======================================"
Write-Host ""
Write-Host "Source : $sourceFile"
Write-Host "Backup : $Backup"
Write-Host ""

$sourceLines = @(Get-Content -LiteralPath $sourceFile -Encoding UTF8)

# ---------------------------------------------------------------------------
# Find first PO entry
#
# Everything before this line is the header.
# ---------------------------------------------------------------------------
$sourceFirstEntryIndex = -1

for ($i = 0; $i -lt $sourceLines.Count; $i++) {

    if ($sourceLines[$i] -match '^msgctxt\s+"#\d+"\s*$') {
        $sourceFirstEntryIndex = $i
        break
    }
}

if ($sourceFirstEntryIndex -lt 0) {
    throw "No msgctxt '#...' entry found in source en_GB/strings.po."
}

# ---------------------------------------------------------------------------
# Parse source entries
# ---------------------------------------------------------------------------
$sourceEntries = Parse-PoEntries `
    -Lines $sourceLines `
    -StartIndex $sourceFirstEntryIndex

if ($sourceEntries.Count -eq 0) {
    throw "No PO entries found in source en_GB/strings.po."
}

# ---------------------------------------------------------------------------
# Check duplicate IDs in source
# ---------------------------------------------------------------------------
$duplicateSourceIds = @(
    $sourceEntries |
    Group-Object Id |
    Where-Object { $_.Count -gt 1 }
)

if ($duplicateSourceIds.Count -gt 0) {

    Write-Host ""
    Write-Host "ERROR: Duplicate IDs found in en_GB/strings.po:" -ForegroundColor Red
    Write-Host ""

    foreach ($group in $duplicateSourceIds) {
        Write-Host "  #$($group.Name) - $($group.Count) occurrences" -ForegroundColor Red
    }

    Write-Host ""

    throw "Source file contains duplicate label IDs. Synchronization aborted."
}

# ---------------------------------------------------------------------------
# Create source lookup table
# ---------------------------------------------------------------------------
$sourceById = @{}

foreach ($entry in $sourceEntries) {
    $sourceById[$entry.Id] = $entry
}

# ---------------------------------------------------------------------------
# Get source footer
# ---------------------------------------------------------------------------
$sourceFooter = @(Get-PoFooter -Lines $sourceLines)
Write-Host "Source entries : $($sourceEntries.Count)"
Write-Host "Source footer  : $($sourceFooter.Count) lines"
Write-Host ""


# ---------------------------------------------------------------------------
# Find language folders
# ---------------------------------------------------------------------------
$languageFolders = @(
    Get-ChildItem `
        -LiteralPath $languageRoot `
        -Directory |
    Where-Object {
        $_.Name -ne "resource.language.en_gb"
    } |
    Sort-Object Name
)


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------
$totalProcessed = 0
$totalSkipped = 0
$totalAdded = 0
$totalRemoved = 0
$totalChangedMsgId = 0
$totalKept = 0


# ---------------------------------------------------------------------------
# Process language files
# ---------------------------------------------------------------------------
foreach ($languageFolder in $languageFolders) {

    $targetFile = Join-Path $languageFolder.FullName "strings.po"

    if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) {

        Write-Host "SKIP $($languageFolder.Name) - strings.po not found" -ForegroundColor Yellow

        $totalSkipped++
        continue
    }

    Write-Host "Processing $($languageFolder.Name)..." -ForegroundColor Cyan

    # ---------------------------------------------------------------
    # Read target file
    # ---------------------------------------------------------------
    $targetLines = @(
        Get-Content `
            -LiteralPath $targetFile `
            -Encoding UTF8
    )

    # ---------------------------------------------------------------
    # Find first target PO entry
    #
    # Everything before it is preserved as the target's own header.
    # ---------------------------------------------------------------
    $targetFirstEntryIndex = -1

    for ($i = 0; $i -lt $targetLines.Count; $i++) {

        if ($targetLines[$i] -match '^msgctxt\s+"#\d+"\s*$') {

            $targetFirstEntryIndex = $i
            break
        }
    }

    if ($targetFirstEntryIndex -lt 0) {

        Write-Host "  ERROR: No msgctxt '#...' found - skipped" -ForegroundColor Red

        $totalSkipped++
        continue
    }

    # ---------------------------------------------------------------
    # Preserve target header exactly
    # ---------------------------------------------------------------
    $targetHeader = @()

    if ($targetFirstEntryIndex -gt 0) {

        $targetHeader = @(
            $targetLines[0..($targetFirstEntryIndex - 1)]
        )
    }

    # ---------------------------------------------------------------
    # Parse target entries
    # ---------------------------------------------------------------
    $targetEntries = Parse-PoEntries `
        -Lines $targetLines `
        -StartIndex $targetFirstEntryIndex

    # ---------------------------------------------------------------
    # Create target lookup table
    # ---------------------------------------------------------------
    $targetById = @{}

    foreach ($entry in $targetEntries) {

        if ($targetById.ContainsKey($entry.Id)) {

            Write-Host `
                "  WARNING: duplicate #$($entry.Id) - keeping last occurrence" `
                -ForegroundColor Yellow
        }

        $targetById[$entry.Id] = $entry
    }

    # ---------------------------------------------------------------
    # Per-file statistics
    # ---------------------------------------------------------------
    $added = 0
    $removed = 0
    $kept = 0
    $changedMsgId = 0

    # ---------------------------------------------------------------
    # Build synchronized entries
    #
    # The source determines:
    #   ID
    #   msgid
    #   order
    #   entry structure
    #
    # The target determines:
    #   msgstr
    # ---------------------------------------------------------------
    $outputEntries =
        New-Object System.Collections.Generic.List[object]

    foreach ($sourceEntry in $sourceEntries) {
        $id = $sourceEntry.Id

        # -----------------------------------------------------------
        # Existing translation
        # -----------------------------------------------------------
        if ($targetById.ContainsKey($id)) {

           $targetEntry = $targetById[$id]

            # Source is the structural template.
            $newLines = [string[]]$sourceEntry.Lines

            # Replace source msgstr with target msgstr.
            $newLines = Replace-PoMsgStr `
                -SourceEntryLines $newLines `
                -TargetMsgStr $targetEntry.MsgStr

            # Detect msgid changes
            if ($targetEntry.MsgId -ne $sourceEntry.MsgId) {
                $changedMsgId++
            }

            $outputEntries.Add(
                [PSCustomObject]@{
                    Id    = $id
                    Lines = [string[]]$newLines
                }
            )

            $kept++
        }

        # -----------------------------------------------------------
        # New ID
        # -----------------------------------------------------------
        else {
            # Source entry is used as template.
            # Keep the entry lines as individual strings.
            $newLines = [string[]]$sourceEntry.Lines

            # Replace source msgstr with empty translation.
            $emptyMsgStr = 'msgstr ""'

            $newLines = Replace-PoMsgStr `
                -SourceEntryLines $newLines `
                -TargetMsgStr $emptyMsgStr

            $outputEntries.Add(
                [PSCustomObject]@{
                    Id    = $id
                    Lines = [string[]]$newLines
                }
            )

            $added++
        }
    }

    # ---------------------------------------------------------------
    # IDs that exist in target but no longer exist in source
    # ---------------------------------------------------------------
    foreach ($targetEntry in $targetEntries) {

        if (-not $sourceById.ContainsKey($targetEntry.Id)) {
            $removed++
        }
    }

    # ---------------------------------------------------------------
    # Build complete output file
    # ---------------------------------------------------------------
    $output =
        New-Object System.Collections.Generic.List[string]

    # ---------------------------------------------------------------
    # 1. Target-specific header
    # ---------------------------------------------------------------
    foreach ($line in $targetHeader) {
        $output.Add([string]$line)
    }

    # Separator between header and entries
    if (
        $output.Count -gt 0 -and
        $output[$output.Count - 1] -ne ""
    ) {
        $output.Add("")
    }

    # ---------------------------------------------------------------
    # 2. Synchronized entries
    # ---------------------------------------------------------------
    for (
        $index = 0;
        $index -lt $outputEntries.Count;
        $index++
    ) {

        # Add exactly one blank line before every entry except the first one.
        if ($index -gt 0) {
            $output.Add([string]::Empty)
        }

        $entryLines = [string[]]$outputEntries[$index].Lines

        foreach ($line in $entryLines) {
            $output.Add([string]$line)
        }
    }

    # ---------------------------------------------------------------
    # 3. Footer from en_GB
    # ---------------------------------------------------------------
    if ($sourceFooter.Count -gt 0) {

        if (
            $output.Count -gt 0 -and
            $output[$output.Count - 1] -ne ""
        ) {
            $output.Add("")
        }

        foreach ($line in $sourceFooter) {
            $output.Add($line)
        }
    }

    # ---------------------------------------------------------------
    # Backup original file if requested
    # ---------------------------------------------------------------
    if ($Backup -ieq "Yes") {

        $backupFile =
            Join-Path `
                $languageFolder.FullName `
                "strings-backup.po"


        Copy-Item `
            -LiteralPath $targetFile `
            -Destination $backupFile `
            -Force


        Write-Host "  Backup  : $backupFile"
    }

    # ---------------------------------------------------------------
    # Write synchronized file
    # ---------------------------------------------------------------
    Set-Content `
        -LiteralPath $targetFile `
        -Value $output.ToArray()`
        -Encoding UTF8

    # ---------------------------------------------------------------
    # Display statistics
    # ---------------------------------------------------------------
    Write-Host "  Entries : $($targetEntries.Count) -> $($sourceEntries.Count)"
    Write-Host "  Kept    : $kept"
    Write-Host "  Added   : $added"
    Write-Host "  Removed : $removed"
    Write-Host "  msgid changed: $changedMsgId"

    # ---------------------------------------------------------------
    # Global statistics
    # ---------------------------------------------------------------
    $totalProcessed++
    $totalKept += $kept
    $totalAdded += $added
    $totalRemoved += $removed
    $totalChangedMsgId += $changedMsgId
}

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "======================================"
Write-Host "Synchronization complete."
Write-Host "======================================"
Write-Host ""
Write-Host "Language files processed : $totalProcessed"
Write-Host "Language files skipped   : $totalSkipped"
Write-Host "Entries kept             : $totalKept"
Write-Host "Entries added            : $totalAdded"
Write-Host "Entries removed          : $totalRemoved"
Write-Host "msgids changed           : $totalChangedMsgId"
Write-Host "Backups                  : $Backup"
Write-Host ""