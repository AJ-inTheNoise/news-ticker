# Get-Headlines.ps1
# Simple: fetch a few RSS feeds and print unique titles

## Inputs with Defaults
param(

    # List of RSS feeds to pull from
    [string[]]$Feeds = @(
        'https://feeds.bbci.co.uk/news/rss.xml',
        'https://feeds.npr.org/1001/rss.xml'
    ),
    
    # Maximum number of headlines to pull and store
    [int]$MaxItems = 80
)

function Strip-Html {
    param([string]$s)
    if(-not $s){ return $null }
    
    #remove tags, collapse spaces, decode entities
    $t = ($s -replace '<[^>]+>', '') -replace '\s+', ' '
    return [System.Net.WebUtility]::HtmlDecode($t).Trim()
}

function Clean-Text {
    param([string]$s, [int]$minLen = 1)
    if(-not $s){ return $null }

    $t = ($s -replace '\s+', ' ').Trim()
    if($t.Length -lt $minLen){ return $null }
    return $t
}

# Get the web content from the given URL and parse out xml "nodes"
function Get-RssItems {
    
    param([string]$Url)

    try {
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36' }
        $resp = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 15
        if (-not $resp.Content){ return @() }

        [xml]$xml = $resp.Content
        $out = New-Object System.Collections.Generic.List[object]

        # RSS: <item><title>,<description>
        $rssItems = $xml.SelectNodes('//channel/item')
        if($rssItems) {
            foreach ($it in $rssItems){
                $title = $it.SelectSingleNode('title').InnerText
                $desc  = $it.SelectSingleNode('description').InnerText
                $out.Add([PSCustomObject]@{
                    Title       = $title
                    Description = $desc
                })
            }
        }

        # Atom: <entry><title>, <summary>
        $atomItems = $xml.SelectNodes('//feed/entry')
        if($atomItems) {
            foreach ($it in $atomItems){
                $title = $it.SelectSingleNode('title').InnerText
                $desc  = $it.SelectSingleNode('summary').InnerText
                if (-not $desc) { $desc = $it.SelectSingleNode('content').InnerText }
                $out.Add([PSCustomObject]@{
                    Title =       $title
                    Description = $desc
                })
            }
        }
    
        return $out
    }
    catch {
        Write-Host "[warn] Failed to fetch ${Url}: $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }

}

# Filter out potential junk headlines.
function Clean-Headline {
    param([string]$s)

    if(-not $s) { return $null}

    # Decode HTML entities, normalize whitespace
    $t = [System.Net.WebUtility]::HtmlDecode($s)
    $t = ($t -replace '\s+', ' ').Trim()

    # Throwaways: numbers-only, very short, or 1–2 words like "Play now"
    if ($t -match '^\d{1,4}$') { return $null }
    if ($t.Length -lt 15) { return $null }
    if (($t -split '\s+').Count -lt 3) { return $null }

    # App/CTA/navigation/promo noise
    $junk = @(
        'app','play now','tap to','install','download','subscribe',
        'watch','video','live','listen','podcast','newsletter',
        'breaking news','top stories','latest updates','home'
    )
    foreach ($j in $junk) {
        if ($t -match ('\b' + [regex]::Escape($j) + '\b'), 'IgnoreCase') { return $null }
    }

    return $t  
}

function Clean-Description {
    param([string]$s)

    if (-not $s) { return $null }

    # Strip HTML and decode entitites
    $t = Strip-Html $s

    # Collapse whitespace
    $t = ($t -replace '\s+', ' ').Trim()

    # Take first sentance if possible
    # $m = [regex]::Match($t, '^[^\.!?]+[\.!?]')
    # if($m.Success){ $t = $m.Value.Trim() }

    return $t

}

# Return a set of meaningful words from a headline (lowercased, no punctuation/stopwords)
function Get-ContentWords {
    param([string]$s)

    if (-not $s) { return @() }
    $t = [System.Net.WebUtility]::HtmlDecode($s.ToLowerInvariant())
    $t = ($t -replace '[^\p{L}\p{N}\s]', ' ') -replace '\s+', ' ' # strip punctuation, normalize spaces

    $stop = @(
        'the','a','an','and','or','but','for','nor','to','of','in','on','at','by','from','with','as',
        'is','are','was','were','be','been','being','this','that','these','those','it','its','their',
        'after','before','over','under','into','about','than','then','so','if','not'
    )

    $words = $t.Trim().Split(' ') | Where-Object {
        $_ -and $_.Length -ge 3 -and ($stop -notcontains $_)
    }
    # unique set
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($w in $words){ [void]$set.Add($w)}
    return $set
}

# Simple Jaccard similarity between two word sets
function Get-Jaccard {
    param([System.Collections.Generic.HashSet[string]]$A,
          [System.Collections.Generic.HashSet[string]]$B)

    if ($A.Count -eq 0 -or $B.Count -eq 0) { return 0.0 }
    $inter = 0
    foreach ($w in $A) { if ($B.Contains($w)) { $inter++ } }
    $union = $A.Count + $B.Count - $inter
    return [double]$inter / [double]$union
}

# Near-duplicate if high word-overlap or one title is mostly contained in the other
function Test-NearDuplicate {
    param([string]$a, [string]$b, [double]$threshold = 0.7)

    $A = Get-ContentWords $a
    $B = Get-ContentWords $b
    $j = Get-Jaccard $A $B
    if ($j -ge $threshold) { return $true }

    # extra cheap check: substring containment after normalization
    $na = (($a -replace '\s+', ' ').ToLower()).Trim()
    $nb = (($b -replace '\s+', ' ').ToLower()).Trim()
    if ($na.Length -gt 0 -and $nb.Length -gt 0) {
        if ($na.Contains($nb) -or $nb.Contains($na)) { return $true }
    }
    return $false
}

# Gather object {Title, Description}
$items = foreach($f in $Feeds){ Get-RssItems -Url $f }

# Clean fields
$items = $items | ForEach-Object {
    $t = Clean-Headline $_.Title
    if (-not $t){ return }
    $d = Clean-Description $_.Description
    [PSCustomObject]@{
        Title = $t
        Description = $d
    }
}

# De-dup near-duplicates by Title
$distinct = @()
foreach($it in $items) {
    $isDup = $false
    foreach ($kept in $distinct) { 
        if (Test-NearDuplicate -a $it.Title -b $kept.Title){
            $isDup = $true
            break
        }
    }
    
    if(-not $isDup){ $distinct += $it }
}

# Cap list
$final = $distinct | Select-Object -First $MaxItems


# Write-Host("[info] kept {0} items after filtering" -f $final.Count) -ForegroundColor DarkCyan
# # Print out the items
# $BOLD  = "$([char]27)[1m"
# $RESET = "$([char]27)[0m"
# Write-Host "Headlines:" -ForegroundColor Cyan
# $i = 1
# foreach ($it in $final){
#     $title = $it.title
#     $desc = $it.Description
#     if(-not $desc){ $desc = "" }

#     $line = "{0,2}. {1}{2}{3}" -f $i, $BOLD, $title, $RESET
#     if ($desc) { $line += " : $desc" }

#     Write-Host $line
#     $i++
# }

function Start-NewsTicker {
    param(
        [Parameter(Mandatory=$true)]
        [object[]]$Items,
        [int]$SpeedMs = 60,               # lower = faster
        [switch]$IncludeDescriptions    # show "Title: description" if present
    )

    # Build flat strings for the ticker (no ANSI formatting to keep widths predictable)
    $lines = foreach ($it in $Items) {
        $title = ($it.Title  -replace '\s+', ' ').Trim()
        $desc  = ($it.Description -replace '\s+', ' ').Trim()
        if ($IncludeDescriptions -and $desc) {
            "$title : $desc"
        } else {
            $title
        }
    }

    if (-not $lines -or $lines.Count -eq 0) { return }

    $sep = '  ///  '
    $scroll = '  ' + ($lines -join $sep) + $sep + '  '

    # Duplicate once so substring wrap is easy
    $scroll2 = $scroll + $scroll
    $pos = 0

    Write-Host ''
    Write-Host '[ticker] Press Ctrl+C to stop.' -ForegroundColor DarkGray

    while ($true) {
        # Handle window resizes on the fly
        $w = [Math]::Max([Console]::WindowWidth, 40)

        # Make sure our source string is long enough to take a slice of width $w
        if ($scroll2.Length -lt ($w + 1)) {
            # if very short, repeat until long enough
            while ($scroll2.Length -lt ($w + 1)) { $scroll2 += $scroll }
        }

        $p = $pos % $scroll.Length   # wrap on original length for smooth loop
        $view = $scroll2.Substring($p, $w)

        # Carriage return + overwrite current line
        Write-Host ("`r" + $view.PadRight($w)) -NoNewline

        Start-Sleep -Milliseconds $SpeedMs
        $pos++
    }
}

function Start-NewsBar {
    param(
        [Parameter(Mandatory=$true)]
        [object[]]$Items,
        [switch]$IncludeDescriptions,
        [int]$Height = 10,          # bar height (px)
        [int]$SpeedPx = 2           # pixels per tick
    )

    # Ensure STA for WinForms
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        # Re-run this script in STA so the form works reliably
        powershell -STA -File $PSCommandPath
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Build ticker text once
    $sep = '  |NEWS|  '
    $lines = foreach ($it in $Items) {
        $t = ($it.Title -replace '\s+', ' ').Trim()
        if ($IncludeDescriptions -and $it.Description) {
            $d = ($it.Description -replace '\s+', ' ').Trim()
            "$t : $d"
        } else {
            $t
        }
    }
    if (-not $lines -or $lines.Count -eq 0) { return }

    $textLocal = '  ' + ($lines -join $sep) + $sep

    # Create form
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.TopMost = $true
    $form.StartPosition = 'Manual'
    $form.Location = [System.Drawing.Point]::new(0, 0)
    $form.Size = [System.Drawing.Size]::new($screen.Width, $Height)
    $form.BackColor = [System.Drawing.Color]::FromArgb(34, 28, 124)
    $form.KeyPreview = $true

    # Double buffering to reduce flicker
    $dob = $form.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags] 'NonPublic, Instance')
    $dob.SetValue($form, $true, $null)

    # Shared drawing state (put EVERYTHING you use in Paint into script: scope)
    $script:font = New-Object System.Drawing.Font('Aptos', [float]10, [System.Drawing.FontStyle]::Regular)
    $script:fore = [System.Drawing.Brushes]::White
    $script:text = $textLocal
    # Measure with TextRenderer (doesn't need a Graphics context)
    $script:textWidth = [System.Windows.Forms.TextRenderer]::MeasureText($script:text, $script:font).Width
    if ($script:textWidth -lt 1) { $script:textWidth = 1 }
    $script:xOffset = 0

    # Drag to reposition
    $script:mouseDown = $false
    $script:start = [System.Drawing.Point]::Empty
    $form.Add_MouseDown({ $script:mouseDown = $true; $script:start = $_.Location })
    $form.Add_MouseUp({   $script:mouseDown = $false })
    $form.Add_MouseMove({
        if ($script:mouseDown) {
            $p = [System.Windows.Forms.Control]::MousePosition
            $form.Location = [System.Drawing.Point]::new($p.X - $script:start.X, $p.Y - $script:start.Y)
        }
    })
    
    # ESC closes
    $form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })
    ## Double click to close
    $form.Add_DoubleClick({ $form.Close() })

    # Paint event (use only script: vars; guard against nulls)
    $form.Add_Paint({
        param($sender, $e)

        if (-not $script:font -or -not $script:fore -or -not $script:text) { return }
        if ($script:textWidth -lt 1) { return }

        $g = $e.Graphics
        $g.Clear($sender.BackColor)
        $g.TextRenderingHint = 'ClearTypeGridFit'


        $y = [int](($sender.ClientSize.Height - $script:font.Height) / 2) + $script:font.Height - 6
        $x = - ($script:xOffset % $script:textWidth)
        $g.DrawString($script:text, $script:font, $script:fore, $x, $y)
        $g.DrawString($script:text, $script:font, $script:fore, $x + $script:textWidth, $y)
    })

    $script:paused = $false
    $form.Add_Click({ $script:paused = -not $script:paused })

    # Smooth scroll timer (~60 FPS)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 16
    $timer.Add_Tick({
        if(-not $script:paused){
            $script:xOffset += $SpeedPx
            $form.Invalidate()
        }
    })
    $timer.Start()

    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::Run($form)

    # Cleanup (only when form closes)
    $timer.Dispose()
    if ($script:font) { $script:font.Dispose() }
}

Start-NewsBar -Items $final -IncludeDescriptions
    