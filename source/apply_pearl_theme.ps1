param(
    [string]$ExpectedScheme = '',
    [string]$RestoreBackup = ''
)

$ErrorActionPreference = 'Stop'
$taskBase = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'GraphitePearl'))
$taskBackupRoot = Join-Path $taskBase 'Backups'
$taskScheme = 'Graphite Pearl'
$taskRoleNames = @('Arrow','Help','AppStarting','Wait','Crosshair','IBeam','NWPen','No','SizeNS','SizeWE','SizeNWSE','SizeNESW','SizeAll','UpArrow','Hand','Pin','Person')
$taskFiles = @('arrow.cur','help.cur','working.ani','busy.ani','precision.cur','text.cur','handwriting.cur','unavailable.cur','vertical.cur','horizontal.cur','diagonal_nwse.cur','diagonal_nesw.cur','move.cur','alternate.cur','link.cur','location.cur','person.cur')

if (-not ('GraphitePearlNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GraphitePearlNative {
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SystemParametersInfoW(uint action, uint parameter, IntPtr value, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadImageW(IntPtr instance, string path, uint type, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetSystemCursor(IntPtr cursor, uint id);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyCursor(IntPtr cursor);
}
'@
}

function Read-RegistryRecord($Key, [string]$Name) {
    $taskExists = $Key.GetValueNames() -contains $Name
    [pscustomobject]@{
        Name = $Name
        Exists = $taskExists
        Kind = if ($taskExists) { $Key.GetValueKind($Name).ToString() } else { '' }
        Value = if ($taskExists) { $Key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
    }
}

function Restore-RegistryRecord($Key, $Record) {
    if ($Record.Exists) {
        $taskKind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$Record.Kind)
        $Key.SetValue([string]$Record.Name,$Record.Value,$taskKind)
    } else {
        $Key.DeleteValue([string]$Record.Name,$false)
    }
}

function Read-ThemeDocument([string]$Path) {
    $taskBytes = [IO.File]::ReadAllBytes($Path)
    $taskStream = [IO.MemoryStream]::new($taskBytes,$false)
    $taskReader = [IO.StreamReader]::new($taskStream,[Text.UTF8Encoding]::new($false,$true),$true)
    try {
        $taskText = $taskReader.ReadToEnd()
        $taskEncoding = $taskReader.CurrentEncoding
    } catch {
        if ($_.Exception.GetBaseException() -isnot [Text.DecoderFallbackException]) { throw }
        # 旧编码按字节保留，仅替换 ASCII 键值。
        $taskEncoding = [Text.Encoding]::GetEncoding(28591,[Text.EncoderFallback]::ExceptionFallback,[Text.DecoderFallback]::ExceptionFallback)
        $taskText = $taskEncoding.GetString($taskBytes)
    } finally {
        $taskReader.Dispose()
        $taskStream.Dispose()
    }
    $taskPreamble = $taskEncoding.GetPreamble()
    $taskEncoded = [byte[]]($taskPreamble + $taskEncoding.GetBytes($taskText))
    if ([Convert]::ToBase64String($taskEncoded) -ne [Convert]::ToBase64String($taskBytes)) {
        throw '主题文件编码无法无损保存，停止修改'
    }
    [pscustomobject]@{ Path=$Path; Bytes=$taskBytes; Text=$taskText; Encoding=$taskEncoding }
}

function Find-CursorSection([string]$Text) {
    $taskPattern = '(?ims)^[\t ]*\[Control Panel\\Cursors\][\t ]*(?:\r?\n|$).*?(?=^[\t ]*\[|\z)'
    $taskSections = [regex]::Matches($Text,$taskPattern)
    if ($taskSections.Count -gt 1) { throw '主题文件包含重复光标段，停止修改' }
    if ($taskSections.Count) { return $taskSections[0] }
    return $null
}

function Update-ThemeCursors([string]$Text, $Values, [bool]$PreserveLegacyBytes = $false) {
    # 只修改光标键，保留其他主题内容及换行。
    if ($PreserveLegacyBytes) {
        foreach ($taskValue in $Values.Values) {
            if ([string]$taskValue -match '[^\x00-\x7F]') { throw '旧编码主题需要 ASCII 光标路径，停止修改' }
        }
    }
    $taskSection = Find-CursorSection $Text
    $taskNewline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $taskBlock = if ($null -ne $taskSection) { $taskSection.Value } else { '[Control Panel\Cursors]' + $taskNewline }
    foreach ($taskName in $Values.Keys) {
        $taskPattern = '(?im)^([\t ]*' + [regex]::Escape($taskName) + '[\t ]*=)[^\r\n]*'
        $taskMatches = [regex]::Matches($taskBlock,$taskPattern)
        if ($taskMatches.Count -gt 1) { throw "主题光标键重复：$taskName" }
        if ($taskMatches.Count) {
            $taskMatch = $taskMatches[0]
            $taskReplacement = $taskMatch.Groups[1].Value + [string]$Values[$taskName]
            $taskBlock = $taskBlock.Remove($taskMatch.Index,$taskMatch.Length).Insert($taskMatch.Index,$taskReplacement)
        } else {
            if (-not $taskBlock.EndsWith("`n")) { $taskBlock += $taskNewline }
            $taskBlock += $taskName + '=' + [string]$Values[$taskName] + $taskNewline
        }
    }
    if ($null -ne $taskSection) {
        return $Text.Remove($taskSection.Index,$taskSection.Length).Insert($taskSection.Index,$taskBlock)
    }
    $taskPrefix = if ($Text.Length -and -not $Text.EndsWith("`n")) { $taskNewline } else { '' }
    return $Text + $taskPrefix + $taskBlock
}

function Write-ThemeBytes([string]$Path, [byte[]]$Expected, [byte[]]$Bytes) {
    # 同目录原子替换，避免写入中断损坏主题。
    $taskTemporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllBytes($taskTemporary,$Bytes)
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) -ne [Convert]::ToBase64String($Expected)) {
            throw '主题文件已发生外部变更，停止替换'
        }
        [IO.File]::Replace($taskTemporary,$Path,[NullString]::Value)
    } finally {
        if ([IO.File]::Exists($taskTemporary)) { [IO.File]::Delete($taskTemporary) }
    }
}

function Write-ThemeDocument($Document, [string]$Text) {
    $taskBefore = [Convert]::ToBase64String($Document.Bytes)
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Document.Path)) -ne $taskBefore) {
        throw '主题文件已发生外部变更，停止写入'
    }
    $taskBytes = [byte[]]($Document.Encoding.GetPreamble() + $Document.Encoding.GetBytes($Text))
    if ([Convert]::ToBase64String($taskBytes) -eq $taskBefore) { return '' }
    $taskFolder = Join-Path ([IO.Path]::GetDirectoryName($Document.Path)) '_备份'
    [IO.Directory]::CreateDirectory($taskFolder) | Out-Null
    $taskStem = [IO.Path]::GetFileNameWithoutExtension($Document.Path)
    $taskExtension = [IO.Path]::GetExtension($Document.Path)
    $taskSaved = Join-Path $taskFolder ($taskStem + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + $taskExtension)
    if ([IO.File]::Exists($taskSaved)) { throw '主题备份目标已存在' }
    [IO.File]::Copy($Document.Path,$taskSaved,$false)
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($taskSaved)) -ne $taskBefore) { throw '主题备份校验失败' }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Document.Path)) -ne $taskBefore) { throw '备份期间主题已发生外部变更' }
    Write-ThemeBytes $Document.Path $Document.Bytes $taskBytes
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($Document.Path)) -ne [Convert]::ToBase64String($taskBytes)) {
        throw '主题文件写入校验失败'
    }
    return $taskSaved
}

function Prepare-ThemeRestore($Change) {
    # 只还原光标段，保留后续修改的壁纸等内容。
    $taskDocument = Read-ThemeDocument $Change.Path
    $taskSection = Find-CursorSection $taskDocument.Text
    $taskBlock = if ($null -ne $taskSection) { $taskSection.Value } else { '' }
    if ($taskBlock -ceq $Change.OriginalSection) {
        return [pscustomobject]@{ Document=$taskDocument; Text=$taskDocument.Text }
    }
    if ($taskBlock -cne $Change.AppliedSection) { throw '主题光标段已被外部修改，停止恢复' }
    $taskText = $taskDocument.Text.Remove($taskSection.Index,$taskSection.Length).Insert($taskSection.Index,[string]$Change.OriginalSection)
    if ($Change.AddedLeadingNewline -and $taskText.EndsWith([string]$Change.AddedLeadingNewline)) {
        $taskText = $taskText.Substring(0,$taskText.Length-$Change.AddedLeadingNewline.Length)
    }
    [pscustomobject]@{ Document=$taskDocument; Text=$taskText }
}

function Reload-Cursors {
    # 通知设置变更，避免其他组件沿用旧状态。
    if (-not [GraphitePearlNative]::SystemParametersInfoW(0x57,0,[IntPtr]::Zero,2)) {
        throw "系统光标刷新失败：$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    # 单独刷新人员选择，避免系统沿用旧图像。
    $taskPersonPath = [string](Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Cursors').Person
    $taskPerson = [GraphitePearlNative]::LoadImageW([IntPtr]::Zero,$taskPersonPath,2,0,0,0x50)
    if ($taskPerson -eq [IntPtr]::Zero) { throw '人员选择光标加载失败' }
    if (-not [GraphitePearlNative]::SetSystemCursor($taskPerson,32672)) {
        [GraphitePearlNative]::DestroyCursor($taskPerson) | Out-Null
        throw '人员选择光标刷新失败'
    }
}

$taskKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Control Panel\Cursors',$true)
if ($null -eq $taskKey) { throw '无法打开当前用户的指针设置' }
$taskSchemes = $taskKey.CreateSubKey('Schemes')
$taskThemes = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Themes',$true)
try {
    if ($null -eq $taskThemes) { throw '无法打开当前用户的主题设置' }
    if ($RestoreBackup) {
        $taskRestorePath = (Resolve-Path -LiteralPath $RestoreBackup).Path
        if (-not $taskRestorePath.StartsWith($taskBackupRoot + '\',[StringComparison]::OrdinalIgnoreCase)) {
            throw '还原文件不在本主题备份目录内'
        }
        $taskSaved = Import-Clixml -LiteralPath $taskRestorePath
        if ($taskSaved.ThemeFile) {
            $taskCurrentTheme = Read-RegistryRecord $taskThemes 'CurrentTheme'
            if (($taskCurrentTheme | ConvertTo-Json -Compress) -ne ($taskSaved.CurrentThemeRecord | ConvertTo-Json -Compress)) {
                throw '当前桌面主题已更换，停止恢复'
            }
            $taskRestore = Prepare-ThemeRestore $taskSaved.ThemeFile
            Write-ThemeDocument $taskRestore.Document $taskRestore.Text | Out-Null
            Restore-RegistryRecord $taskThemes $taskSaved.ThemeMouseRecord
        }
        foreach ($taskRecord in $taskSaved.Records) {
            Restore-RegistryRecord $taskKey $taskRecord
        }
        Restore-RegistryRecord $taskSchemes $taskSaved.SchemeRecord
        Reload-Cursors
        Write-Output '已恢复更换前的鼠标方案。'
        return
    }

    $taskCurrentScheme = [string]$taskKey.GetValue('')
    if ($ExpectedScheme -and $taskCurrentScheme -ne $ExpectedScheme) {
        throw '当前方案已发生外部变更，停止应用'
    }
    $taskPackage = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'cursors')) {
        $PSScriptRoot
    } else {
        [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../package/GraphitePearl'))
    }
    $taskManifest = Get-Content -LiteralPath (Join-Path $taskPackage 'manifest.json') -Raw | ConvertFrom-Json
    if ($taskManifest.roles.Count -ne 17) { throw '光标角色数量不完整' }
    foreach ($taskName in $taskFiles) {
        $taskSource = Join-Path $taskPackage ('cursors/' + $taskName)
        $taskEntry = @($taskManifest.roles | Where-Object file -eq ('cursors/' + $taskName))
        if ($taskEntry.Count -ne 1 -or (Get-FileHash -LiteralPath $taskSource).Hash -ne $taskEntry[0].sha256) {
            throw "光标校验失败：$taskName"
        }
    }

    $taskStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $taskBackup = Join-Path $taskBackupRoot ('Before-Pearl-' + $taskStamp)
    $taskDestination = Join-Path $taskBase ('Cursors/' + $taskStamp)
    if ((Test-Path -LiteralPath $taskBackup) -or (Test-Path -LiteralPath $taskDestination)) { throw '安装或备份目标已存在' }
    $taskRecords = @(@('','Scheme Source') + $taskRoleNames | ForEach-Object { Read-RegistryRecord $taskKey $_ })
    $taskCurrentThemeRecord = Read-RegistryRecord $taskThemes 'CurrentTheme'
    $taskThemePath = [Environment]::ExpandEnvironmentVariables([string]$taskThemes.GetValue('CurrentTheme'))
    if (-not $taskThemePath -or -not [IO.Path]::IsPathRooted($taskThemePath)) { throw '当前主题路径无效' }
    $taskThemeDocument = Read-ThemeDocument $taskThemePath
    $taskThemeValues = [ordered]@{ DefaultValue=$taskScheme }
    for ($taskIndex=0; $taskIndex -lt 17; $taskIndex++) {
        $taskThemeValues[$taskRoleNames[$taskIndex]] = Join-Path $taskDestination $taskFiles[$taskIndex]
    }
    $taskThemeText = Update-ThemeCursors $taskThemeDocument.Text $taskThemeValues ($taskThemeDocument.Encoding.CodePage -eq 28591)
    $taskOriginalSection = Find-CursorSection $taskThemeDocument.Text
    $taskAddedNewline = if ($null -eq $taskOriginalSection -and $taskThemeDocument.Text.Length -and -not $taskThemeDocument.Text.EndsWith("`n")) {
        if ($taskThemeDocument.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    } else { '' }
    $taskSnapshot = [pscustomobject]@{
        Records = $taskRecords
        SchemeRecord = Read-RegistryRecord $taskSchemes $taskScheme
        CursorBaseSize = $taskKey.GetValue('CursorBaseSize')
        CurrentThemeRecord = $taskCurrentThemeRecord
        ThemeMouseRecord = Read-RegistryRecord $taskThemes 'ThemeChangesMousePointers'
        ThemeFile = [pscustomobject]@{
            Path = $taskThemePath
            OriginalSection = if ($null -ne $taskOriginalSection) { $taskOriginalSection.Value } else { '' }
            AppliedSection = (Find-CursorSection $taskThemeText).Value
            AddedLeadingNewline = $taskAddedNewline
        }
    }
    New-Item -ItemType Directory -Path (Join-Path $taskBackup 'cursors') -Force | Out-Null
    $taskBackupFile = Join-Path $taskBackup 'registry.clixml'
    $taskSnapshot | Export-Clixml -LiteralPath $taskBackupFile
    foreach ($taskName in $taskRoleNames) {
        $taskOldPath = [Environment]::ExpandEnvironmentVariables([string]$taskKey.GetValue($taskName))
        if ($taskOldPath -and (Test-Path -LiteralPath $taskOldPath -PathType Leaf)) {
            $taskCopy = Join-Path $taskBackup ('cursors/' + $taskName + [IO.Path]::GetExtension($taskOldPath))
            Copy-Item -LiteralPath $taskOldPath -Destination $taskCopy
            if ((Get-FileHash -LiteralPath $taskOldPath).Hash -ne (Get-FileHash -LiteralPath $taskCopy).Hash) { throw '原光标备份校验失败' }
        }
    }
    New-Item -ItemType Directory -Path $taskDestination -Force | Out-Null
    foreach ($taskName in $taskFiles) {
        $taskSource = Join-Path $taskPackage ('cursors/' + $taskName)
        $taskInstalled = Join-Path $taskDestination $taskName
        Copy-Item -LiteralPath $taskSource -Destination $taskInstalled
        if ((Get-FileHash -LiteralPath $taskSource).Hash -ne (Get-FileHash -LiteralPath $taskInstalled).Hash) { throw '安装文件校验失败' }
    }

    $taskRegistryChanged = $false
    $taskThemeChanged = $false
    $taskThemeBackup = ''
    try {
        # 写入前复核配置，避免覆盖外部变更。
        foreach ($taskRecord in $taskRecords) {
            $taskNow = Read-RegistryRecord $taskKey $taskRecord.Name
            if (($taskNow | ConvertTo-Json -Compress) -ne ($taskRecord | ConvertTo-Json -Compress)) { throw '指针设置已发生外部变更' }
        }
        foreach ($taskRecord in @($taskSnapshot.CurrentThemeRecord,$taskSnapshot.ThemeMouseRecord)) {
            $taskNow = Read-RegistryRecord $taskThemes $taskRecord.Name
            if (($taskNow | ConvertTo-Json -Compress) -ne ($taskRecord | ConvertTo-Json -Compress)) { throw '主题设置已发生外部变更' }
        }
        $taskThemeBackup = Write-ThemeDocument $taskThemeDocument $taskThemeText
        $taskThemeChanged = $true
        $taskRegistryChanged = $true
        $taskThemes.SetValue('ThemeChangesMousePointers',0,[Microsoft.Win32.RegistryValueKind]::DWord)
        for ($taskIndex=0; $taskIndex -lt 17; $taskIndex++) {
            $taskKey.SetValue($taskRoleNames[$taskIndex],(Join-Path $taskDestination $taskFiles[$taskIndex]),[Microsoft.Win32.RegistryValueKind]::String)
        }
        $taskSchemes.SetValue($taskScheme,(($taskFiles | ForEach-Object { Join-Path $taskDestination $_ }) -join ','),[Microsoft.Win32.RegistryValueKind]::String)
        $taskKey.SetValue('',$taskScheme,[Microsoft.Win32.RegistryValueKind]::String)
        $taskKey.SetValue('Scheme Source',1,[Microsoft.Win32.RegistryValueKind]::DWord)
        Reload-Cursors
        for ($taskIndex=0; $taskIndex -lt 17; $taskIndex++) {
            if ($taskKey.GetValue($taskRoleNames[$taskIndex]) -ne (Join-Path $taskDestination $taskFiles[$taskIndex])) { throw '应用后设置不一致' }
        }
        if ($taskThemes.GetValue('ThemeChangesMousePointers') -ne 0) { throw '主题指针保护未保存' }
        if ((Read-ThemeDocument $taskThemePath).Text -cne $taskThemeText) { throw '应用后主题内容不一致' }
    } catch {
        $taskFailure = $_
        if ($taskRegistryChanged) {
            foreach ($taskRecord in $taskSnapshot.Records) { Restore-RegistryRecord $taskKey $taskRecord }
            Restore-RegistryRecord $taskSchemes $taskSnapshot.SchemeRecord
            Restore-RegistryRecord $taskThemes $taskSnapshot.ThemeMouseRecord
            Reload-Cursors
        }
        if ($taskThemeChanged) {
            $taskRestore = Prepare-ThemeRestore $taskSnapshot.ThemeFile
            # 原件已有备份；回滚前再次确认文件未变。
            $taskNow = [IO.File]::ReadAllBytes($taskThemePath)
            if ([Convert]::ToBase64String($taskNow) -ne [Convert]::ToBase64String($taskRestore.Document.Bytes)) { throw '回滚期间主题已发生外部变更' }
            $taskBytes = [byte[]]($taskRestore.Document.Encoding.GetPreamble() + $taskRestore.Document.Encoding.GetBytes($taskRestore.Text))
            Write-ThemeBytes $taskThemePath $taskRestore.Document.Bytes $taskBytes
        }
        throw $taskFailure
    }
    [pscustomobject]@{
        Scheme = $taskKey.GetValue('')
        InstalledDirectory = $taskDestination
        BackupFile = $taskBackupFile
        ThemeFile = $taskThemePath
        ThemeBackup = $taskThemeBackup
        ThemeChangesMousePointers = $taskThemes.GetValue('ThemeChangesMousePointers')
        CursorBaseSize = $taskKey.GetValue('CursorBaseSize')
        RoleCount = $taskRoleNames.Count
        Status = 'Applied and reloaded'
    } | Format-List
} finally {
    $taskSchemes.Dispose()
    $taskKey.Dispose()
    if ($null -ne $taskThemes) { $taskThemes.Dispose() }
}
