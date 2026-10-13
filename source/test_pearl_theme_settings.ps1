$ErrorActionPreference = 'Stop'
$taskSource = Join-Path $PSScriptRoot 'apply_pearl_theme.ps1'
$taskTokens = $null
$taskErrors = $null
$taskAst = [Management.Automation.Language.Parser]::ParseFile($taskSource,[ref]$taskTokens,[ref]$taskErrors)
if ($taskErrors.Count) { throw ($taskErrors | Out-String) }

# 仅载入纯文件函数，不执行系统设置操作。
$taskFunctions = @('Read-ThemeDocument','Find-CursorSection','Update-ThemeCursors','Write-ThemeBytes','Write-ThemeDocument','Prepare-ThemeRestore')
foreach ($taskFunction in $taskAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] },$false)) {
    if ($taskFunction.Name -in $taskFunctions) { . ([scriptblock]::Create($taskFunction.Extent.Text)) }
}

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected([scriptblock]$Operation,[string]$Expected) {
    $taskFailure = $null
    try { & $Operation | Out-Null } catch { $taskFailure = $_.Exception.Message }
    Assert-True ($null -ne $taskFailure -and $taskFailure.Contains($Expected)) "未正确拒绝：$Expected"
}

$taskRoot = Join-Path ([IO.Path]::GetTempPath()) ('GraphitePearl-ThemeTests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($taskRoot) | Out-Null
$taskValues = [ordered]@{ DefaultValue='Graphite Pearl'; Arrow='C:\Theme\arrow.cur'; Person='C:\Theme\person.cur' }
$taskEncodings = @([Text.UTF8Encoding]::new($false,$true),[Text.UTF8Encoding]::new($true,$true),[Text.UnicodeEncoding]::new($false,$true,$true),[Text.UnicodeEncoding]::new($true,$true,$true))
$taskIndex = 0
foreach ($taskEncoding in $taskEncodings) {
    foreach ($taskNewline in @("`n","`r`n")) {
        $taskIndex++
        $taskText = @('[Theme]','DisplayName=测试主题','[Control Panel\Cursors]','; 保留原注释','Arrow =old.cur','Extra=keep','DefaultValue=old','','[Control Panel\Desktop]','Wallpaper=C:\wallpaper.jpg','[Sounds]','SchemeName=keep','') -join $taskNewline
        $taskPath = Join-Path $taskRoot "sample-$taskIndex.theme"
        $taskBytes = [byte[]]($taskEncoding.GetPreamble() + $taskEncoding.GetBytes($taskText))
        [IO.File]::WriteAllBytes($taskPath,$taskBytes)
        $taskDocument = Read-ThemeDocument $taskPath
        $taskEdited = Update-ThemeCursors $taskDocument.Text $taskValues
        $taskBeforeSection = Find-CursorSection $taskText
        $taskAfterSection = Find-CursorSection $taskEdited
        Assert-True ($taskText.Remove($taskBeforeSection.Index,$taskBeforeSection.Length) -ceq $taskEdited.Remove($taskAfterSection.Index,$taskAfterSection.Length)) '改动了光标段之外的内容'
        Assert-True ($taskEdited.Contains('Extra=keep') -and $taskEdited.Contains('; 保留原注释')) '删除了原光标段其他内容'
        Assert-True ($taskEdited.Contains('Arrow =C:\Theme\arrow.cur')) '没有保留键的原格式'
        Assert-True ((Update-ThemeCursors $taskEdited $taskValues) -ceq $taskEdited) '重复更新不稳定'
        $taskSaved = Write-ThemeDocument $taskDocument $taskEdited
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($taskSaved)) -ceq [Convert]::ToBase64String($taskBytes)) '备份不完整'
        $taskAfter = Read-ThemeDocument $taskPath
        Assert-True ($taskAfter.Text -ceq $taskEdited) '写入结果不一致'
        Assert-True ($taskAfter.Encoding.CodePage -eq $taskEncoding.CodePage) '文件编码改变'
        $taskChange = [pscustomobject]@{ Path=$taskPath; OriginalSection=$taskBeforeSection.Value; AppliedSection=$taskAfterSection.Value; AddedLeadingNewline='' }
        Assert-True ((Prepare-ThemeRestore $taskChange).Text -ceq $taskText) '恢复没有还原原光标段'
        Assert-Rejected { Write-ThemeDocument $taskDocument $taskText } '外部变更'

        # 模拟用户随后改壁纸，恢复时必须保留。
        $taskOtherPath = Join-Path $taskRoot "wallpaper-$taskIndex.theme"
        $taskOtherText = $taskEdited.Replace('C:\wallpaper.jpg','C:\changed.jpg')
        [IO.File]::WriteAllBytes($taskOtherPath,[byte[]]($taskEncoding.GetPreamble() + $taskEncoding.GetBytes($taskOtherText)))
        $taskChange.Path = $taskOtherPath
        Assert-True ((Prepare-ThemeRestore $taskChange).Text -ceq $taskText.Replace('C:\wallpaper.jpg','C:\changed.jpg')) '恢复覆盖了后改的壁纸'

        $taskConflictPath = Join-Path $taskRoot "conflict-$taskIndex.theme"
        [IO.File]::WriteAllBytes($taskConflictPath,[byte[]]($taskEncoding.GetPreamble() + $taskEncoding.GetBytes($taskEdited.Replace('C:\Theme\arrow.cur','C:\another.cur'))))
        $taskChange.Path = $taskConflictPath
        Assert-Rejected { Prepare-ThemeRestore $taskChange } '外部修改'
    }
}

$taskDuplicate = "[Control Panel\Cursors]`nArrow=one`nArrow=two`n"
Assert-Rejected { Update-ThemeCursors $taskDuplicate $taskValues } '键重复'
Assert-Rejected { Find-CursorSection ($taskDuplicate + "[Control Panel\Cursors]`n") } '重复光标段'
foreach ($taskEnding in @('',"`n")) {
    $taskText = "[Theme]`nDisplayName=test" + $taskEnding
    $taskEdited = Update-ThemeCursors $taskText $taskValues
    $taskPath = Join-Path $taskRoot ('missing-' + $taskEnding.Length + '.theme')
    [IO.File]::WriteAllText($taskPath,$taskEdited,[Text.UTF8Encoding]::new($false))
    $taskChange = [pscustomobject]@{ Path=$taskPath; OriginalSection=''; AppliedSection=(Find-CursorSection $taskEdited).Value; AddedLeadingNewline=$(if ($taskEnding) { '' } else { "`n" }) }
    Assert-True ((Prepare-ThemeRestore $taskChange).Text -ceq $taskText) '新增光标段无法完整恢复'
}

$taskLegacyPath = Join-Path $taskRoot 'legacy.theme'
$taskLegacyBytes = [byte[]]([Text.Encoding]::ASCII.GetBytes('; Copyright ') + @(0xA9) + [Text.Encoding]::ASCII.GetBytes("`r`n[Control Panel\Cursors]`r`nArrow=old.cur`r`n[Sounds]`r`nSchemeName=keep`r`n"))
[IO.File]::WriteAllBytes($taskLegacyPath,$taskLegacyBytes)
$taskDocument = Read-ThemeDocument $taskLegacyPath
Assert-True ($taskDocument.Encoding.CodePage -eq 28591) '没有启用旧编码字节保留'
$taskEdited = Update-ThemeCursors $taskDocument.Text $taskValues $true
$taskSaved = Write-ThemeDocument $taskDocument $taskEdited
Assert-True ([IO.File]::ReadAllBytes($taskLegacyPath)[12] -eq 0xA9) '旧编码字节被改写'
Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($taskSaved)) -ceq [Convert]::ToBase64String($taskLegacyBytes)) '旧编码备份不完整'
Assert-Rejected { Update-ThemeCursors $taskDocument.Text ([ordered]@{ Arrow='C:\中文\arrow.cur' }) $true } 'ASCII 光标路径'

Write-Output 'PASS: syntax; 8 encoding/newline combinations; legacy byte preservation; backups; idempotence; restore; unrelated settings; conflict rejection; missing and duplicate sections'
Write-Output ('Temporary fixtures: ' + $taskRoot)
