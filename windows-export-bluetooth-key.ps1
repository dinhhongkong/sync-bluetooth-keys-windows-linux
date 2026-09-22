Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator

    if (-not $principal.IsInRole($adminRole)) {
        throw 'Open PowerShell with "Run as administrator", then run this script again.'
    }
}

function Assert-NativeCommandSucceeded {
    param([string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

Assert-Administrator

$outputDirectory = Join-Path $env:ProgramData 'BTKeyExport'
$registryPath = 'HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys'
$outputFile = Join-Path $outputDirectory 'keys.reg'
$taskName = 'BTKeyExport-{0}' -f ([Guid]::NewGuid().ToString('N'))
$taskCreated = $false

Write-Host 'Creating the protected export directory...'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

& icacls.exe $outputDirectory /grant:r `
    '*S-1-5-18:(OI)(CI)F' `
    '*S-1-5-32-544:(OI)(CI)F' | Out-Null
Assert-NativeCommandSucceeded 'Granting access to SYSTEM and Administrators'

& icacls.exe $outputDirectory /inheritance:r | Out-Null
Assert-NativeCommandSucceeded 'Disabling inherited permissions'

$regArguments = 'export "{0}" "{1}" /y' -f $registryPath, $outputFile
$action = New-ScheduledTaskAction `
    -Execute "$env:SystemRoot\System32\reg.exe" `
    -Argument $regArguments
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1)
$systemPrincipal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

try {
    Write-Host 'Creating a temporary task that runs as SYSTEM...'
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $systemPrincipal | Out-Null
    $taskCreated = $true

    $startedAt = Get-Date
    Start-ScheduledTask -TaskName $taskName

    Write-Host 'Exporting Bluetooth pairing keys...'
    $deadline = (Get-Date).AddSeconds(30)

    while ($true) {
        Start-Sleep -Milliseconds 250
        $task = Get-ScheduledTask -TaskName $taskName
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        $hasRun = $taskInfo.LastRunTime -ge $startedAt.AddSeconds(-2)

        if ($hasRun -and $task.State -ne 'Running') {
            break
        }

        if ((Get-Date) -ge $deadline) {
            throw 'Timed out while waiting for the SYSTEM export task.'
        }
    }

    if ($taskInfo.LastTaskResult -ne 0) {
        throw "Registry export failed. Scheduled-task result: $($taskInfo.LastTaskResult)."
    }

    if (-not (Test-Path -LiteralPath $outputFile -PathType Leaf)) {
        throw "The task completed but did not create $outputFile."
    }

    $exportedFile = Get-Item -LiteralPath $outputFile
    if ($exportedFile.Length -eq 0) {
        throw "The exported file is empty: $outputFile"
    }

    Write-Host ''
    Write-Host 'Bluetooth keys exported successfully.' -ForegroundColor Green
    Write-Host "File: $outputFile"
    Write-Host 'Keep this file private: it contains Bluetooth authentication secrets.'
}
finally {
    if ($taskCreated) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false `
            -ErrorAction SilentlyContinue
        Write-Host 'Temporary scheduled task removed.'
    }
}
