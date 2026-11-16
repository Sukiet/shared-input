param(
    [switch]$BuildWindows,
    [string]$FlutterPath = 'flutter'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$flutterCommand = (Get-Command $FlutterPath -ErrorAction Stop).Source
$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
if ($cmakeCommand) {
    $cmakePath = $cmakeCommand.Source
} else {
    $vswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswherePath)) {
        throw 'CMake was not found. Install the Visual Studio C++ CMake tools or add CMake to PATH.'
    }
    $cmakeMatches = @(& $vswherePath -latest -products '*' -find 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe')
    if (-not $cmakeMatches.Count) { throw 'Visual Studio CMake tools were not found.' }
    $cmakePath = $cmakeMatches[0]
}
$ctestPath = Join-Path (Split-Path -Parent $cmakePath) 'ctest.exe'

function Invoke-Checked {
    param([string]$Command, [string[]]$CommandArguments)
    & $Command @CommandArguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Command $CommandArguments" }
}

Push-Location -LiteralPath $repoRoot
try {
    Invoke-Checked $flutterCommand @('pub', 'get')
    Invoke-Checked $flutterCommand @('analyze', '--no-pub')
    Invoke-Checked $flutterCommand @('test', '--no-pub')
    Invoke-Checked $cmakePath @('-S', 'test/native', '-B', 'build/safety_tests')
    Invoke-Checked $cmakePath @('--build', 'build/safety_tests', '--config', 'Debug')
    Invoke-Checked $ctestPath @('--test-dir', 'build/safety_tests', '-C', 'Debug', '--output-on-failure')
    if ($BuildWindows) {
        Invoke-Checked $flutterCommand @('build', 'windows', '--debug', '--no-pub')
    }
} finally {
    Pop-Location
}
