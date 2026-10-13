$ErrorActionPreference = 'Stop'
$taskProductionTypeBefore = [bool]('GraphitePearlNative' -as [type])
$taskTokens = $null
$taskErrors = $null
$taskAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'apply_pearl_theme.ps1'),[ref]$taskTokens,[ref]$taskErrors)
if ($taskErrors.Count) { throw ($taskErrors | Out-String) }

# 仅载入函数和角色常量，避免执行安装入口。
$taskFunctions = @('Restore-RegistryRecord','Read-ThemeDocument','Find-CursorSection','Write-ThemeBytes','Prepare-ThemeRestore','Reload-Cursors','Assert-RestoreCursorFiles','Restore-ApplyState')
foreach ($taskFunction in $taskAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
    if ($taskFunction.Name -in $taskFunctions) {
        $taskDefinition = $taskFunction.Extent.Text.Replace('[GraphitePearlNative]','[GraphitePearlRecoveryFixture.Native]')
        . ([scriptblock]::Create($taskDefinition))
    }
}
$taskRoles = $taskAst.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq 'taskRoleNames'},$false)[0]
. ([scriptblock]::Create($taskRoles.Extent.Text))

# 原生调用和注册表均使用内存模拟。
if (-not ('GraphitePearlRecoveryFixture.Native' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using Microsoft.Win32;
namespace GraphitePearlRecoveryFixture {
public static class Native {
    public static bool FailRefresh, FailLoad, FailSet;
    public static int RefreshCalls, LoadCalls, SetCalls, DestroyCalls;
    public static string LoadedPath;
    public static void Reset() {
        FailRefresh=FailLoad=FailSet=false;
        RefreshCalls=LoadCalls=SetCalls=DestroyCalls=0;
        LoadedPath=null;
    }
    public static bool SystemParametersInfoW(uint a,uint b,IntPtr c,uint d) { RefreshCalls++; return !FailRefresh; }
    public static IntPtr LoadImageW(IntPtr a,string path,uint b,int c,int d,uint e) {
        LoadCalls++; LoadedPath=path;
        return FailLoad || String.IsNullOrWhiteSpace(path) ? IntPtr.Zero : new IntPtr(1);
    }
    public static bool SetSystemCursor(IntPtr a,uint b) { SetCalls++; return !FailSet; }
    public static bool DestroyCursor(IntPtr a) { DestroyCalls++; return true; }
}
public class Key {
    public Dictionary<string,object> Values = new Dictionary<string,object>();
    public HashSet<string> FailNames = new HashSet<string>();
    public void SetValue(string name,object value,RegistryValueKind kind) {
        if (FailNames.Contains(name)) throw new InvalidOperationException("模拟注册表写入失败");
        Values[name]=value;
    }
    public void DeleteValue(string name,bool missing) {
        if (FailNames.Contains(name)) throw new InvalidOperationException("模拟注册表删除失败");
        Values.Remove(name);
    }
}
}
'@
}

function Assert-True([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected([scriptblock]$Operation,[string]$Expected) {
    $taskFailure = $null
    try { & $Operation | Out-Null } catch { $taskFailure = $_.Exception.Message }
    Assert-True ($null -ne $taskFailure -and $taskFailure.Contains($Expected)) "未正确拒绝：$Expected"
}

function Get-ItemProperty {
    param($LiteralPath)
    $taskProperties = @{}
    foreach ($taskName in $script:taskCursorKey.Values.Keys) { $taskProperties[$taskName] = $script:taskCursorKey.Values[$taskName] }
    [pscustomobject]$taskProperties
}

$taskRoot = Join-Path ([IO.Path]::GetTempPath()) ('GraphitePearl-RecoveryTests-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($taskRoot) | Out-Null
$script:taskCase = 0

function New-RecoveryCase {
    [GraphitePearlRecoveryFixture.Native]::Reset()
    $script:taskCase++
    $script:taskCursorKey = [GraphitePearlRecoveryFixture.Key]::new()
    $script:taskSchemesKey = [GraphitePearlRecoveryFixture.Key]::new()
    $script:taskThemesKey = [GraphitePearlRecoveryFixture.Key]::new()
    $script:taskCursorKey.Values['Arrow'] = 'new.cur'
    $script:taskCursorKey.Values['IBeam'] = 'new-text.cur'
    $script:taskCursorKey.Values['Person'] = 'new-person.cur'
    $script:taskSchemesKey.Values['Graphite Pearl'] = 'new'
    $script:taskThemesKey.Values['ThemeChangesMousePointers'] = 0
    $script:taskOldSection = "[Control Panel\Cursors]`nArrow=old.cur`n"
    $script:taskNewSection = "[Control Panel\Cursors]`nArrow=new.cur`n"
    $script:taskOtherSection = "[Control Panel\Desktop]`nWallpaper=keep`n"
    $script:taskThemePath = Join-Path $taskRoot ('theme-'+$script:taskCase+'.theme')
    [IO.File]::WriteAllText($script:taskThemePath,$script:taskNewSection+$script:taskOtherSection,[Text.UTF8Encoding]::new($false))
    $script:taskSnapshot = [pscustomobject]@{
        Records = @(
            [pscustomobject]@{Name='Arrow';Exists=$true;Kind='String';Value='old.cur'},
            [pscustomobject]@{Name='IBeam';Exists=$true;Kind='String';Value='old-text.cur'},
            [pscustomobject]@{Name='Person';Exists=$false;Kind='';Value=$null}
        )
        SchemeRecord = [pscustomobject]@{Name='Graphite Pearl';Exists=$false;Kind='';Value=$null}
        ThemeMouseRecord = [pscustomobject]@{Name='ThemeChangesMousePointers';Exists=$true;Kind='DWord';Value=1}
        ThemeFile = [pscustomobject]@{Path=$script:taskThemePath;OriginalSection=$script:taskOldSection;AppliedSection=$script:taskNewSection;AddedLeadingNewline=''}
    }
}

New-RecoveryCase
$script:taskCursorKey.Values.Remove('Person') | Out-Null
Reload-Cursors
Assert-True ([GraphitePearlRecoveryFixture.Native]::RefreshCalls -eq 1 -and [GraphitePearlRecoveryFixture.Native]::LoadCalls -eq 0) '缺失覆盖未使用系统默认'
foreach ($taskValue in @('','   ')) {
    New-RecoveryCase
    $script:taskCursorKey.Values['Person'] = $taskValue
    Reload-Cursors
    Assert-True ([GraphitePearlRecoveryFixture.Native]::LoadCalls -eq 0) '空覆盖仍尝试加载文件'
}
New-RecoveryCase
$script:taskCursorKey.Values['Person'] = '%SystemRoot%\Cursors\fixture.cur'
Reload-Cursors
Assert-True ([GraphitePearlRecoveryFixture.Native]::LoadedPath -eq [Environment]::ExpandEnvironmentVariables('%SystemRoot%\Cursors\fixture.cur')) '覆盖路径未展开'
Assert-True ([GraphitePearlRecoveryFixture.Native]::SetCalls -eq 1) '有效覆盖未应用'

New-RecoveryCase
[GraphitePearlRecoveryFixture.Native]::FailLoad = $true
Assert-Rejected { Reload-Cursors } '人员选择光标加载失败'
New-RecoveryCase
[GraphitePearlRecoveryFixture.Native]::FailSet = $true
Assert-Rejected { Reload-Cursors } '人员选择光标刷新失败'
Assert-True ([GraphitePearlRecoveryFixture.Native]::DestroyCalls -eq 1) '失败时未释放私有光标'

New-RecoveryCase
[GraphitePearlRecoveryFixture.Native]::FailRefresh = $true
$taskFailures = @(Restore-ApplyState $taskSnapshot $taskCursorKey $taskSchemesKey $taskThemesKey $true $true)
Assert-True ($taskFailures.Count -eq 1 -and $taskFailures[0].Contains('光标刷新')) '刷新失败未被汇总'
Assert-True ([IO.File]::ReadAllText($taskThemePath) -ceq $taskOldSection+$taskOtherSection) '刷新失败阻断了主题还原'
Assert-True ($taskCursorKey.Values['Arrow'] -eq 'old.cur' -and -not $taskCursorKey.Values.ContainsKey('Person')) '光标记录未还原'
Assert-True ($taskThemesKey.Values['ThemeChangesMousePointers'] -eq 1 -and -not $taskSchemesKey.Values.ContainsKey('Graphite Pearl')) '方案及主题标记未还原'

New-RecoveryCase
$taskCursorKey.FailNames.Add('Arrow') | Out-Null
$taskFailures = @(Restore-ApplyState $taskSnapshot $taskCursorKey $taskSchemesKey $taskThemesKey $true $true)
Assert-True ($taskFailures.Count -eq 1 -and $taskFailures[0].Contains('Arrow')) '注册表失败未被汇总'
Assert-True ($taskCursorKey.Values['IBeam'] -eq 'old-text.cur') '单个失败阻断了其他角色还原'
Assert-True ([IO.File]::ReadAllText($taskThemePath) -ceq $taskOldSection+$taskOtherSection) '注册表失败阻断了主题还原'

New-RecoveryCase
[IO.File]::WriteAllText($taskThemePath,"[Control Panel\Cursors]`nArrow=external.cur`n"+$taskOtherSection,[Text.UTF8Encoding]::new($false))
$taskFailures = @(Restore-ApplyState $taskSnapshot $taskCursorKey $taskSchemesKey $taskThemesKey $true $true)
Assert-True ($taskFailures.Count -eq 1 -and $taskFailures[0].Contains('主题文件')) '主题冲突未报告'
Assert-True ([IO.File]::ReadAllText($taskThemePath).Contains('external.cur')) '覆盖了外部主题修改'
Assert-True ([GraphitePearlRecoveryFixture.Native]::RefreshCalls -eq 1) '主题冲突阻断了最后刷新'

New-RecoveryCase
$taskRollbackBody = $taskAst.FindAll({param($node) $node -is [Management.Automation.Language.CatchClauseAst] -and $node.Body.Extent.Text.Contains('$taskFailure = $_')},$true)[0].Body.Extent.Text
$taskRollback = [scriptblock]::Create($taskRollbackBody.Substring(1,$taskRollbackBody.Length-2))
$taskKey = $taskCursorKey
$taskSchemes = $taskSchemesKey
$taskThemes = $taskThemesKey
$taskRegistryChanged = $true
$taskThemeChanged = $true
$taskBackupFile = 'fixture-backup.clixml'
[GraphitePearlRecoveryFixture.Native]::FailRefresh = $true
$taskCaught = $null
try { throw '模拟安装失败' } catch {
    try { & $taskRollback } catch { $taskCaught = $_.Exception.Message }
}
Assert-True ($null -ne $taskCaught -and $taskCaught.Contains('模拟安装失败') -and $taskCaught.Contains('光标刷新')) '原始错误和回滚错误未同时保留'
Assert-True ([IO.File]::ReadAllText($taskThemePath) -ceq $taskOldSection+$taskOtherSection) '安装异常处理未还原主题'

$taskExisting = Join-Path $taskRoot 'old.cur'
[IO.File]::WriteAllText($taskExisting,'fixture',[Text.UTF8Encoding]::new($false))
Assert-RestoreCursorFiles @([pscustomobject]@{Name='Arrow';Exists=$true;Value=$taskExisting},[pscustomobject]@{Name='Person';Exists=$true;Value=''})
Assert-Rejected { Assert-RestoreCursorFiles @([pscustomobject]@{Name='Arrow';Exists=$true;Value=(Join-Path $taskRoot 'missing.cur')}) } '原光标文件不存在'

Assert-True ([bool]('GraphitePearlNative' -as [type]) -eq $taskProductionTypeBefore) '测试污染了生产原生类型'
Write-Output 'PASS: default cursor fallback, native failures, rollback continuation, conflict protection, combined errors and restore preflight'
Write-Output 'Native calls and registry writes were mocked; real cursor settings were not changed.'
