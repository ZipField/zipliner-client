param([string]$VendorPath = '')
$ErrorActionPreference = 'Stop'
$helperRoot = $PSScriptRoot
$buildArguments = @('-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--contents-directory', '_internal', '--noconsole', '--uac-admin',
    '--name', 'ZiplinerNetworkHelper', '--collect-binaries', 'pydivert', '--collect-data', 'pydivert',
    '--exclude-module', 'pydivert.tests', '--exclude-module', 'psutil.tests',
    '--distpath', (Join-Path $helperRoot 'dist'), '--workpath', (Join-Path $helperRoot 'build'),
    '--specpath', (Join-Path $helperRoot 'build'))
if ($VendorPath) { $buildArguments += @('--paths', $VendorPath) }
$buildArguments += (Join-Path $helperRoot 'helper.py')
$previousPythonPath = $env:PYTHONPATH
try {
    if ($VendorPath) { $env:PYTHONPATH = $VendorPath + [IO.Path]::PathSeparator + $previousPythonPath }
    & python @buildArguments
    if ($LASTEXITCODE -ne 0) { throw 'Network helper build failed' }
    & python (Join-Path $helperRoot 'write_licenses.py')
    if ($LASTEXITCODE -ne 0) { throw 'Network helper license collection failed' }
} finally {
    $env:PYTHONPATH = $previousPythonPath
}
Write-Output (Join-Path $helperRoot 'dist\ZiplinerNetworkHelper\ZiplinerNetworkHelper.exe')
