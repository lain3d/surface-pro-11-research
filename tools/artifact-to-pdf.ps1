<#
.SYNOPSIS
  Render an Artifact HTML fragment to a paginated PDF.

.DESCRIPTION
  Artifact source files are fragments: no <html>, <head> or <body>, because the
  publisher wraps them at deploy time. They also rely on the artifact runtime to
  render <pre class="mermaid"> blocks, which nothing does locally. So a straight
  "open the file and print" produces an unstyled page with raw mermaid source
  where the diagrams should be.

  This wraps the fragment in a real document, bundles mermaid, forces the light
  token set (a PDF has no viewer theme to follow), adds print rules that keep
  tables and figures off page breaks, and drives headless Chrome to paginate it.

  Mermaid renders asynchronously, so the run uses --virtual-time-budget to let
  the diagrams finish before the page is captured. Without it the PDF comes out
  with empty figures.

.PARAMETER Source
  The artifact HTML fragment.

.PARAMETER Out
  Destination PDF. Defaults to the source name with a .pdf extension.

.PARAMETER Mermaid
  Path to mermaid.min.js. If absent it is downloaded next to the source once.

.PARAMETER KeepHtml
  Leave the wrapped, self-contained HTML behind. Useful for checking pagination
  in a real browser before committing to the PDF.

.EXAMPLE
  .\artifact-to-pdf.ps1 -Source .\camera-system.html -Out .\camera-system.pdf
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Out,
    [string]$Mermaid,
    [switch]$KeepHtml
)

$ErrorActionPreference = 'Stop'

$Source = (Resolve-Path $Source).Path
if (-not $Out) { $Out = [IO.Path]::ChangeExtension($Source, '.pdf') }
$dir = Split-Path -Parent $Source

if (-not $Mermaid) { $Mermaid = Join-Path $dir 'mermaid.min.js' }
if (-not (Test-Path $Mermaid)) {
    Write-Output "fetching mermaid -> $Mermaid"
    Invoke-WebRequest -Uri 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js' `
                      -OutFile $Mermaid -UseBasicParsing
}

$browser = @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw "no Chrome or Edge found" }
Write-Output "browser: $browser"

# -Encoding UTF8 is not optional. PowerShell 5.1's Get-Content sniffs for a BOM
# and falls back to the ANSI codepage when there is none, so a BOM-less UTF-8
# source is read as Windows-1252 and every multi-byte character is split into
# separate Latin-1 chars. Written back out as UTF-8 that double-encodes, and the
# PDF comes out with "Â§1" where "§1" should be.
$fragment = Get-Content -LiteralPath $Source -Raw -Encoding UTF8
$mermaidJs = Get-Content -LiteralPath $Mermaid -Raw -Encoding UTF8

# Print rules. The artifact's own tokens stay as they are; these only pin the
# theme (a PDF has no viewer to ask), flatten the scroll containers so wide
# tables paginate instead of clipping, and stop figures splitting across pages.
$printCss = @'
<style>
  :root { color-scheme: light; }
  @page { size: A4; margin: 16mm 14mm 18mm; }
  html, body { background: #FFFFFF !important; }
  body { padding: 0 !important; font-size: 10.5pt; }
  .wrap { max-width: none !important; }
  .masthead { padding-top: 0 !important; }

  /* Scrollers cannot scroll on paper. Let them size to content and shrink the
     type instead, so wide register tables stay readable rather than clipped. */
  .scroller { overflow: visible !important; }
  .scroller table { font-size: 8.6pt; }

  /* Mermaid sizes its SVG to the viewport it rendered in, which on paper leaves
     the diagram small and centred in a wide box. Let it fill the text column. */
  pre.mermaid { overflow: visible !important; padding: 0.6rem !important; }
  pre.mermaid svg {
    width: 100% !important;
    max-width: 100% !important;
    height: auto !important;
  }
  pre.code { overflow-x: visible !important; white-space: pre-wrap; font-size: 8.4pt; }

  h1 { font-size: 22pt; }
  h2 { font-size: 14pt; }
  h3 { font-size: 11.5pt; }

  section { margin-bottom: 1.6rem !important; }
  h2 { break-before: page; break-after: avoid; }
  .masthead + .legend + section h2,
  section:first-of-type h2 { break-before: auto; }
  h3, h4 { break-after: avoid; }
  figure, .note, .legend { break-inside: avoid; }
  tr, .spec dt, .spec dd { break-inside: avoid; }
  thead { display: table-header-group; }

  a { color: inherit; text-decoration: none; }
</style>
'@

$init = @'
<script>
  mermaid.initialize({
    startOnLoad: true,
    securityLevel: "loose",
    theme: "base",
    themeVariables: {
      background: "#F1F4F7",
      primaryColor: "#FFFFFF",
      primaryTextColor: "#101820",
      primaryBorderColor: "#0F6E7E",
      lineColor: "#5A6674",
      secondaryColor: "#E2F0F2",
      tertiaryColor: "#F1F4F7",
      fontFamily: "ui-sans-serif, system-ui, Segoe UI, sans-serif",
      fontSize: "13px"
    }
  });
</script>
'@

$html = @"
<!doctype html>
<html lang="en" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
$fragment
$printCss
<script>$mermaidJs</script>
$init
</head>
<body>
</body>
</html>
"@

# The fragment carries its own <title> and <style> plus the body content. Rather
# than parse it, put it in <head> and move everything that is not metadata into
# <body> once the document has loaded -- browsers relocate stray flow content
# out of <head> automatically, so this is just making that explicit.
$html = $html -replace '<body>\s*</body>', '<body></body>'

$wrapped = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($Source) + '.print.html')
Set-Content -LiteralPath $wrapped -Value $html -Encoding utf8
Write-Output "wrapped -> $wrapped  ($([math]::Round((Get-Item $wrapped).Length / 1MB, 2)) MB)"

# Do NOT name these $args or $profile. Both are PowerShell automatic variables:
# the splat of $args silently expands to nothing and Chrome runs with no
# arguments at all, printing no error and producing no file.
$userDir = Join-Path $env:TEMP ("chrome-pdf-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$chromeArgs = @(
    "--headless=new",
    "--disable-gpu",
    "--no-sandbox",
    "--no-pdf-header-footer",
    "--user-data-dir=$userDir",
    "--virtual-time-budget=20000",
    "--run-all-compositor-stages-before-draw",
    "--print-to-pdf=$Out",
    "file:///$($wrapped -replace '\\','/')"
)
# Delete any previous output first. Chrome exits 0 whether or not it managed to
# write the PDF, so a run that silently failed would leave the old file in place
# and the existence check below would report success on a stale artifact.
if (Test-Path $Out) { Remove-Item -LiteralPath $Out -Force }

# Launch through Start-Process, not the call operator. `& $browser @chromeArgs`
# returns instantly with an unset $LASTEXITCODE and never starts the browser --
# Chrome detaches in a way this shell does not wait on, so the script races
# ahead and finds no output. Start-Process -Wait -PassThru gives a real exit
# code and a real completion.
Write-Output "rendering..."
$outLog = Join-Path $dir 'browser-stdout.log'
$errLog = Join-Path $dir 'browser-stderr.log'
$proc = Start-Process -FilePath $browser -ArgumentList $chromeArgs `
                      -Wait -PassThru -NoNewWindow `
                      -RedirectStandardOutput $outLog -RedirectStandardError $errLog
Write-Output "  browser exit $($proc.ExitCode)"
foreach ($l in @($outLog, $errLog)) {
    if ((Test-Path $l) -and (Get-Item $l).Length -gt 0) {
        Get-Content $l | Where-Object { $_ -notmatch 'DevTools|Fontconfig|bluetooth|GPU|voice|Attempting' } |
            Select-Object -First 8 | ForEach-Object { Write-Output "  $_" }
    }
    Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue
}

if (Test-Path $userDir) { Remove-Item -LiteralPath $userDir -Recurse -Force -ErrorAction SilentlyContinue }
if (-not $KeepHtml) { Remove-Item -LiteralPath $wrapped -Force -ErrorAction SilentlyContinue }

if (-not (Test-Path $Out)) { throw "no PDF produced - Chrome exited without writing $Out" }
$item = Get-Item $Out
if ($item.Length -lt 10KB) { throw "PDF is only $($item.Length) bytes - render almost certainly failed" }
Write-Output "wrote $Out  ($([math]::Round($item.Length / 1KB)) KB, $($item.LastWriteTime.ToString('HH:mm:ss')))"
