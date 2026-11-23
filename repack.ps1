$ErrorActionPreference = 'Stop'
$pwd = $MyInvocation.MyCommand.Path | Split-Path
Set-Location $pwd

# Verify syntax
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile("$pwd\IPToolsPlus.ps1", [ref]$null, [ref]$errs)
if ($errs.Count -gt 0) { Write-Host "SYNTAX ERROR: $($errs[0].Message)"; exit 1 }
Write-Host "Syntax: OK"

# Read script, strip BOM, encode to base64
$script = [System.IO.File]::ReadAllText("$pwd\IPToolsPlus.ps1", [System.Text.Encoding]::UTF8)
$script = $script.TrimStart([char]0xFEFF)
$b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))

# Split into chunks for C# string literals
$chunkSize = 30000
$chunks = @()
for ($i = 0; $i -lt $b64.Length; $i += $chunkSize) {
    $end = [Math]::Min($i + $chunkSize, $b64.Length)
    $chunks += $b64.Substring($i, $end - $i)
}
$encodedExpr = ($chunks | ForEach-Object { "`"$_`"" }) -join ' + '

# Build Program.cs
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('using System;')
[void]$sb.AppendLine('using System.Diagnostics;')
[void]$sb.AppendLine('using System.IO;')
[void]$sb.AppendLine('using System.Text;')
[void]$sb.AppendLine('using System.Windows.Forms;')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('class Program {')
[void]$sb.AppendLine("    static string encoded = $encodedExpr;")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('    static void Main() {')
[void]$sb.AppendLine('        try {')
[void]$sb.AppendLine('            byte[] bytes = Convert.FromBase64String(encoded);')
[void]$sb.AppendLine('            string script = Encoding.Unicode.GetString(bytes);')
[void]$sb.AppendLine('            string tempPath = Path.Combine(Path.GetTempPath(), "IPToolsPlus_runtime.ps1");')
[void]$sb.AppendLine('            File.WriteAllText(tempPath, script, new UTF8Encoding(true));')
[void]$sb.AppendLine('            var psi = new ProcessStartInfo();')
[void]$sb.AppendLine('            psi.FileName = "powershell.exe";')
[void]$sb.AppendLine('            // 启动器自身带 requireAdministrator 清单，已提权，子进程直接继承，无需 runas')
[void]$sb.AppendLine('            psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + tempPath + "\"";')
[void]$sb.AppendLine('            psi.UseShellExecute = false;')
[void]$sb.AppendLine('            psi.CreateNoWindow = true;   // 不分配控制台窗口')
[void]$sb.AppendLine('            Process.Start(psi);')
[void]$sb.AppendLine('        } catch (Exception ex) {')
[void]$sb.AppendLine('            MessageBox.Show(ex.Message);')
[void]$sb.AppendLine('        }')
[void]$sb.AppendLine('    }')
[void]$sb.AppendLine('}')

[System.IO.File]::WriteAllText("$pwd\Program.cs", $sb.ToString(), [System.Text.Encoding]::UTF8)
Write-Host "Program.cs written"

# Compile
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$compileArgs = @("/out:`"$pwd\IPToolsPlus.exe`"", "/nologo", "/optimize", "/target:winexe")
if (Test-Path "$pwd\app.ico") { $compileArgs += "/win32icon:`"$pwd\app.ico`"" }
if (Test-Path "$pwd\app.manifest") { $compileArgs += "/win32manifest:`"$pwd\app.manifest`"" }
$compileArgs += "/reference:System.Windows.Forms.dll"
$compileArgs += "`"$pwd\Program.cs`""

Write-Host "Compiling..."
& $csc $compileArgs
Write-Host "Exit: $LASTEXITCODE"
if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $LASTEXITCODE" }

if (Test-Path "$pwd\IPToolsPlus.exe") {
    $size = (Get-Item "$pwd\IPToolsPlus.exe").Length
    Write-Host "Done: $size bytes"

    # Verify embedded script matches source
    $csText = [System.IO.File]::ReadAllText("$pwd\Program.cs", [System.Text.Encoding]::UTF8)
    $ms = [regex]::Matches($csText, '"([A-Za-z0-9+/]{100,}={0,2})"')
    $fullB64 = ($ms | ForEach-Object { $_.Groups[1].Value }) -join ''
    $decoded = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($fullB64))
    Write-Host "Embedded matches source: $($decoded -eq $script)"
}
