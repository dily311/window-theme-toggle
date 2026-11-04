# powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ".\ThemeToggle.ps1"
# ThemeToggle.ps1
# Windows 10/11 - PowerShell + WinForms
# 시스템 트레이에서 다크/라이트 모드를 전환하는 개인용 유틸리티

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Windows 테마 변경 알림 API
if (-not ([System.Management.Automation.PSTypeName]'ThemeToggle.NativeMethods').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ThemeToggle {
    public static class NativeMethods {
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint Msg,
            UIntPtr wParam,
            string lParam,
            uint fuFlags,
            uint uTimeout,
            out UIntPtr lpdwResult
        );

        public static readonly IntPtr HWND_BROADCAST = new IntPtr(0xffff);
        public const uint WM_SETTINGCHANGE = 0x001A;
        public const uint SMTO_ABORTIFHUNG = 0x0002;

        public static void NotifyThemeChanged() {
            UIntPtr result;
            SendMessageTimeout(
                HWND_BROADCAST,
                WM_SETTINGCHANGE,
                UIntPtr.Zero,
                "ImmersiveColorSet",
                SMTO_ABORTIFHUNG,
                1000,
                out result
            );

            SendMessageTimeout(
                HWND_BROADCAST,
                WM_SETTINGCHANGE,
                UIntPtr.Zero,
                "WindowsThemeElement",
                SMTO_ABORTIFHUNG,
                1000,
                out result
            );
        }
    }
}
'@
}

$script:ThemeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

# 현재 테마 읽기: dark 또는 light
function Get-WindowsTheme {
    try {
        $settings = Get-ItemProperty -Path $script:ThemeKey -ErrorAction Stop

        if ([int]$settings.SystemUsesLightTheme -eq 0 -and
            [int]$settings.AppsUseLightTheme -eq 0) {
            return 'dark'
        }

        return 'light'
    }
    catch {
        return 'light'
    }
}

# 테마 변경
function Set-WindowsTheme {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('dark', 'light')]
        [string]$Theme
    )

    $value = if ($Theme -eq 'dark') { 0 } else { 1 }

    if (-not (Test-Path $script:ThemeKey)) {
        New-Item -Path $script:ThemeKey -Force | Out-Null
    }

    New-ItemProperty -Path $script:ThemeKey `
        -Name 'SystemUsesLightTheme' `
        -Value $value -PropertyType DWord -Force | Out-Null

    New-ItemProperty -Path $script:ThemeKey `
        -Name 'AppsUseLightTheme' `
        -Value $value -PropertyType DWord -Force | Out-Null

    # Windows에 변경 사실 알리기
    [ThemeToggle.NativeMethods]::NotifyThemeChanged()

    return $true
}

function Get-DynamicTrayIcon {
    param([string]$Theme)
    $path = if ($Theme -eq 'dark') {
        Join-Path $PSScriptRoot "icon/moon.ico"
    } else {
        Join-Path $PSScriptRoot "icon/sun.ico"
    }
    if (Test-Path $path) {
        return New-Object System.Drawing.Icon($path)
    }
    return [System.Drawing.SystemIcons]::Application
}

# 트레이 툴팁 및 아이콘 갱신 함수 수정
function Update-Tray {
    param([string]$Theme)
    
    # 전달받은 테마에 맞는 아이콘과 툴팁 설정
    $script:NotifyIcon.Icon = Get-DynamicTrayIcon -Theme $Theme
    $script:NotifyIcon.Text = if ($Theme -eq 'dark') {
        '다크 모드 (클릭하여 라이트로 전환)'
    } else {
        '라이트 모드 (클릭하여 다크로 전환)'
    }
}

# ----------------------------
# 시스템 트레이 테마 토글
# ----------------------------

$script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = '종료'
$exitItem.Add_Click({
    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()
    $script:TrayMenu.Dispose()
    $script:ContextForm.Close()
})

[void]$script:TrayMenu.Items.Add($exitItem)

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$initialTheme = Get-WindowsTheme
$script:NotifyIcon.Icon = Get-DynamicTrayIcon -Theme $initialTheme
Update-Tray -Theme $initialTheme
$script:NotifyIcon.ContextMenuStrip = $script:TrayMenu
$script:NotifyIcon.Visible = $true

# 왼쪽 클릭하면 즉시 테마 전환
$script:NotifyIcon.Add_MouseClick({
    param($sender, $e)

    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
        return
    }

    try {
        $current = Get-WindowsTheme
        # 테마 업데이트 (반대 테마로 토글)
        $nextTheme = if ($current -eq 'dark') { 'light' } else { 'dark' }
        Set-WindowsTheme -Theme $nextTheme | Out-Null
        
        # 즉시 트레이 갱신
        Update-Tray -Theme $nextTheme
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "테마 변경 실패: $($_.Exception.Message)",
            '테마 전환 오류'
        ) | Out-Null
    }
})

# 숨겨진 메시지 루프용 폼
$script:ContextForm = New-Object System.Windows.Forms.Form
$script:ContextForm.ShowInTaskbar = $false
$script:ContextForm.WindowState = 'Minimized'
$script:ContextForm.Opacity = 0

# 백그라운드에서 주기적으로 윈도우 테마 변화 감지 (1초 간격)
$script:LastKnownTheme = $initialTheme
$script:ThemeTimer = New-Object System.Windows.Forms.Timer
$script:ThemeTimer.Interval = 1000 # 1초
$script:ThemeTimer.Add_Tick({
    $currentTheme = Get-WindowsTheme
    if ($currentTheme -ne $script:LastKnownTheme) {
        $script:LastKnownTheme = $currentTheme
        Update-Tray -Theme $currentTheme
    }
})
$script:ThemeTimer.Start()

$script:ContextForm.Add_Shown({
    $script:ContextForm.Hide()
})

$script:ContextForm.Add_FormClosed({
    $script:ThemeTimer.Stop()
    $script:ThemeTimer.Dispose()
    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()
})

[System.Windows.Forms.Application]::Run($script:ContextForm)