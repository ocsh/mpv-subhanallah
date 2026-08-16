$ErrorActionPreference = "Stop"
$release = Get-Date -Format "yyyy.MM.dd"
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$distDir = Join-Path $projectRoot "dist"
$scriptPath = Join-Path $projectRoot "scripts\mpv-subhanallah.lua"
$programPath = Join-Path $projectRoot "installer\Program.cs"
$installerPath = Join-Path $distDir "mpv-subhanallah-installer-v$release.exe"
$zipPath = Join-Path $distDir "mpv-subhanallah-v$release.zip"

$compilerCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (!$compiler) {
    throw "The .NET Framework C# compiler was not found."
}

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
Remove-Item -LiteralPath $installerPath, $zipPath -Force -ErrorAction SilentlyContinue

$compilerArgs = @(
    "/nologo",
    "/target:exe",
    "/optimize+",
    "/platform:anycpu",
    "/out:$installerPath",
    "/resource:$scriptPath,mpv-subhanallah.lua",
    $programPath
)
& $compiler @compilerArgs
if ($LASTEXITCODE -ne 0) {
    throw "Installer compilation failed."
}

Push-Location $projectRoot
try {
    Compress-Archive -Path "scripts", "script-opts", "README.md", "LICENSE" `
        -DestinationPath $zipPath -CompressionLevel Optimal
}
finally {
    Pop-Location
}

Get-Item -LiteralPath $installerPath, $zipPath | Select-Object Name, Length
