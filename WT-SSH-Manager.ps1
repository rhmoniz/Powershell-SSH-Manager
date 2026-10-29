<#
    WT SSH Manager
    A small GUI for creating and editing SSH sessions as Windows Terminal profiles.

    - One profile per session: host, user, port, run-at-login commands, colors.
    - Passwords are never stored. "Set up key login" uses your password once to
      install an SSH key on the server; after that, logins are automatic.
    - Backs up settings.json before every save (keeps the last 10) and only
      touches profiles this tool created.

    Run:  powershell -ExecutionPolicy Bypass -File .\WT-SSH-Manager.ps1
#>

#region Bootstrap
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    return
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'Continue'
#endregion

#region Constants
$AppDir   = Join-Path $env:APPDATA 'WT-SSH-Manager'
$DataPath = Join-Path $AppDir 'sessions.json'
$PrefsPath = Join-Path $AppDir 'prefs.json'
$KeyPath  = Join-Path $env:USERPROFILE '.ssh\id_ed25519'

# tab = tab color, bg = terminal background, fg = text color, scheme = base ANSI palette
$Presets = [ordered]@{
    'Crimson'  = @{ tab = '#C62828'; bg = '#1C0E10'; fg = '#F3DCDC'; scheme = 'One Half Dark' }
    'Amber'    = @{ tab = '#D99A00'; bg = '#1B1508'; fg = '#F6EACB'; scheme = 'One Half Dark' }
    'Emerald'  = @{ tab = '#2E9D5B'; bg = '#0C1912'; fg = '#D7F1E1'; scheme = 'One Half Dark' }
    'Ocean'    = @{ tab = '#1E78D7'; bg = '#0B1522'; fg = '#D6E6F8'; scheme = 'One Half Dark' }
    'Violet'   = @{ tab = '#8A57D6'; bg = '#150F21'; fg = '#E7DCF8'; scheme = 'One Half Dark' }
    'Teal'     = @{ tab = '#119E9E'; bg = '#091A1B'; fg = '#D3F1F0'; scheme = 'One Half Dark' }
    'Graphite' = @{ tab = '#6B7280'; bg = '#121417'; fg = '#E5E7EB'; scheme = 'Campbell' }
    'Paper'    = @{ tab = '#B45309'; bg = '#FBF7EF'; fg = '#2B2620'; scheme = 'One Half Light' }
}
$Schemes = @('One Half Dark', 'Campbell', 'Campbell Powershell', 'Tango Dark', 'Solarized Dark',
             'Vintage', 'One Half Light', 'Tango Light', 'Solarized Light')
#endregion

#region Data model
function New-Session([string]$Preset = 'Ocean') {
    $p = $Presets[$Preset]
    [pscustomobject]@{
        id         = '{' + [guid]::NewGuid().ToString() + '}'
        name       = 'New session'
        host       = ''
        user       = ''
        port       = 22
        startup    = ''
        keepShell  = $true
        keepAlive  = $true
        preset     = $Preset
        tabColor   = $p.tab
        background = $p.bg
        foreground = $p.fg
        scheme     = $p.scheme
    }
}

function ConvertTo-Session($o) {
    $s = New-Session
    foreach ($prop in @($s.PSObject.Properties.Name)) {
        if ($o.PSObject.Properties[$prop] -and $null -ne $o.$prop) { $s.$prop = $o.$prop }
    }
    $s.port = [int]$s.port
    $s
}

function Find-Session([string]$Id) {
    $script:Sessions | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

function Load-Data {
    $script:Sessions = New-Object System.Collections.ArrayList
    $script:WrittenGuids = @()
    $script:SettingsPathOverride = $null
    if (-not (Test-Path $DataPath)) { return }
    try {
        $d = [IO.File]::ReadAllText($DataPath) | ConvertFrom-Json
        foreach ($o in @($d.sessions)) { if ($o) { [void]$script:Sessions.Add((ConvertTo-Session $o)) } }
        $script:WrittenGuids = @($d.writtenGuids | Where-Object { $_ })
        $script:SettingsPathOverride = $d.settingsPath
    } catch {
        [Windows.MessageBox]::Show("Couldn't read $DataPath`n`n$($_.Exception.Message)", 'WT SSH Manager', 'OK', 'Warning') | Out-Null
    }
}

function Save-Data {
    if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }
    $d = [ordered]@{
        version      = 1
        settingsPath = $script:SettingsPathOverride
        writtenGuids = @($script:WrittenGuids)
        sessions     = @($script:Sessions)
    }
    $json = ConvertTo-Json -InputObject $d -Depth 6
    [IO.File]::WriteAllText($DataPath, $json, (New-Object Text.UTF8Encoding $false))
}

function Load-Prefs {
    if (-not (Test-Path $PrefsPath)) { return }
    try {
        $p = [IO.File]::ReadAllText($PrefsPath) | ConvertFrom-Json
        $ui.ChkCloseAfter.IsChecked = [bool]$p.closeAfterLaunch
    } catch {}
}

function Save-Prefs {
    if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }
    $json = ConvertTo-Json -InputObject ([ordered]@{ closeAfterLaunch = [bool]$ui.ChkCloseAfter.IsChecked })
    [IO.File]::WriteAllText($PrefsPath, $json, (New-Object Text.UTF8Encoding $false))
}
#endregion

#region Windows Terminal settings
function Find-WTSettings {
    if ($script:SettingsPathOverride -and (Test-Path $script:SettingsPathOverride)) { return $script:SettingsPathOverride }
    $candidates = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    $null
}

# settings.json may contain comments and trailing commas; strip them without touching strings.
function Remove-JsonComments([string]$Text) {
    $keepStrings = { param($m) if ($m.Groups[1].Success) { $m.Groups[1].Value } else { '' } }
    $t = [regex]::Replace($Text, '("(?:\\.|[^"\\])*")|//[^\r\n]*|/\*[\s\S]*?\*/', $keepStrings)
    [regex]::Replace($t, '("(?:\\.|[^"\\])*")|,(?=\s*[}\]])', $keepStrings)
}

function Get-Target($s) {
    if ($s.user) { "$($s.user)@$($s.host)" } else { "$($s.host)" }
}

function Build-CommandLine($s) {
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('ssh')
    $cmds = (($s.startup -replace "`r`n", "`n") -split "`n" |
             ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' }) -join "`n"
    if ($cmds)                 { $parts.Add('-t') }
    if ($s.keepAlive)          { $parts.Add('-o ServerAliveInterval=30') }
    if ([int]$s.port -ne 22)   { $parts.Add("-p $($s.port)") }
    $parts.Add((Get-Target $s))
    if ($cmds) {
        if ($s.keepShell) { $cmds += "`nexec `"`${SHELL:-bash}`" -l" }
        # Base64 keeps quotes and special characters intact through Windows and the remote shell.
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cmds + "`n"))
        $parts.Add("`"bash -lic 'eval \`"`$(echo $b64 | base64 -d)\`"'`"")
    }
    $parts -join ' '
}

function Build-WTProfile($s) {
    [pscustomobject][ordered]@{
        guid                     = $s.id
        name                     = $s.name
        commandline              = (Build-CommandLine $s)
        tabTitle                 = $s.name
        suppressApplicationTitle = $true
        tabColor                 = $s.tabColor
        background               = $s.background
        foreground               = $s.foreground
        cursorColor              = $s.foreground
        colorScheme              = $s.scheme
        hidden                   = $false
    }
}

# Returns @{ Path; Backup } on success, $null on failure.
function Save-ToWT {
    $path = Find-WTSettings
    if (-not $path) {
        $r = Show-Message "Windows Terminal's settings.json wasn't found in the usual places.`n`nBrowse for it?" 'YesNo' 'Question'
        if ($r -ne 'Yes') { return $null }
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'settings.json|settings.json|JSON files|*.json'
        if (-not $dlg.ShowDialog($win)) { return $null }
        $path = $dlg.FileName
        $script:SettingsPathOverride = $path
    }

    try {
        $raw = [IO.File]::ReadAllText($path)
        $settings = (Remove-JsonComments $raw) | ConvertFrom-Json
    } catch {
        Show-Message "Couldn't parse $path. Nothing was changed.`n`n$($_.Exception.Message)" 'OK' 'Error' | Out-Null
        return $null
    }

    $managed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($g in @($script:WrittenGuids) + @($script:Sessions | ForEach-Object { $_.id })) { if ($g) { [void]$managed.Add([string]$g) } }

    $isArray = $settings.profiles -is [array]
    if ($null -eq $settings.profiles) {
        $settings | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{ list = @() })
    }
    $existing = if ($isArray) { @($settings.profiles) } else { @($settings.profiles.list) }
    $kept   = @($existing | Where-Object { $_ -and -not $managed.Contains([string]$_.guid) })
    $ours   = @($script:Sessions | ForEach-Object { Build-WTProfile $_ })
    $merged = @($kept) + @($ours)

    if ($isArray) {
        $settings.profiles = $merged
    } elseif ($settings.profiles.PSObject.Properties['list']) {
        $settings.profiles.list = $merged
    } else {
        $settings.profiles | Add-Member -NotePropertyName list -NotePropertyValue $merged
    }

    try {
        $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$path.bak-$stamp"
        Copy-Item -LiteralPath $path -Destination $backup -ErrorAction Stop
        Get-ChildItem -LiteralPath (Split-Path $path) -Filter ((Split-Path $path -Leaf) + '.bak-*') |
            Sort-Object Name -Descending | Select-Object -Skip 10 | Remove-Item -ErrorAction SilentlyContinue

        $json = ConvertTo-Json -InputObject $settings -Depth 32
        [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))
    } catch {
        Show-Message "Couldn't write $path.`n`n$($_.Exception.Message)" 'OK' 'Error' | Out-Null
        return $null
    }

    $script:WrittenGuids = @($script:Sessions | ForEach-Object { $_.id })
    @{ Path = $path; Backup = (Split-Path $backup -Leaf) }
}
#endregion

#region XAML
[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WT SSH Manager" Width="1120" Height="740" MinWidth="1000" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#F3F4F6"
        FontFamily="Segoe UI" FontSize="13" Foreground="#1F2328">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#1F2328"/>
      <Setter Property="BorderBrush" Value="#CDD2D9"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#2563EB"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="BorderBrush" Value="#2563EB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="BorderBrush" Value="#CDD2D9"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,8,0,0"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#57606A"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,12,0,4"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,22,0,0"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6E7781"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
    </Style>
    <Style x:Key="Swatch" TargetType="Border">
      <Setter Property="Width" Value="36"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="CornerRadius" Value="5"/>
      <Setter Property="BorderBrush" Value="#CDD2D9"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="ToolTip" Value="Pick a color"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="270"/>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="350"/>
    </Grid.ColumnDefinitions>
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Session list -->
    <Border Grid.Column="0" Background="White" BorderBrush="#E1E4E8" BorderThickness="0,0,1,0">
      <DockPanel Margin="14,16,14,14">
        <TextBlock DockPanel.Dock="Top" Text="Sessions" FontSize="17" FontWeight="SemiBold" Margin="4,0,0,12"/>
        <UniformGrid DockPanel.Dock="Bottom" Columns="3" Margin="0,12,0,0">
          <Button x:Name="BtnNew" Content="New" Style="{StaticResource Btn}" Margin="0,0,4,0" Padding="6,7"/>
          <Button x:Name="BtnDup" Content="Duplicate" Style="{StaticResource Btn}" Margin="2,0,2,0" Padding="6,7"/>
          <Button x:Name="BtnDel" Content="Delete" Style="{StaticResource Btn}" Margin="4,0,0,0" Padding="6,7"/>
        </UniformGrid>
        <TextBlock DockPanel.Dock="Bottom" Style="{StaticResource Hint}" Margin="4,10,0,0"
                   Text="Double-click a session to open it. Ctrl- or Shift-click to select several, then Open."/>
        <ListBox x:Name="LstSessions" BorderThickness="0" Background="Transparent" SelectionMode="Extended"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
      </DockPanel>
    </Border>

    <!-- Connection editor -->
    <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="EditorPanel" Margin="28,4,28,28">
        <TextBlock Text="Connection" Style="{StaticResource Section}"/>
        <TextBlock Text="Session name (shown on the tab)" Style="{StaticResource Label}"/>
        <TextBox x:Name="TxtName"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="2*"/>
            <ColumnDefinition Width="12"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="12"/>
            <ColumnDefinition Width="72"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0">
            <TextBlock Text="Host or IP" Style="{StaticResource Label}"/>
            <TextBox x:Name="TxtHost"/>
          </StackPanel>
          <StackPanel Grid.Column="2">
            <TextBlock Text="Username" Style="{StaticResource Label}"/>
            <TextBox x:Name="TxtUser"/>
          </StackPanel>
          <StackPanel Grid.Column="4">
            <TextBlock Text="Port" Style="{StaticResource Label}"/>
            <TextBox x:Name="TxtPort"/>
          </StackPanel>
        </Grid>

        <TextBlock Text="Run at login" Style="{StaticResource Section}"/>
        <TextBlock Style="{StaticResource Hint}" Text="One command per line. They run in a login shell right after you connect, for example cd ~/projects/api then claude --continue."/>
        <TextBox x:Name="TxtStartup" AcceptsReturn="True" TextWrapping="NoWrap" MinHeight="86" Margin="0,8,0,0"
                 VerticalContentAlignment="Top" FontFamily="Cascadia Mono, Consolas" FontSize="12.5"
                 HorizontalScrollBarVisibility="Auto"/>
        <CheckBox x:Name="ChkKeepShell" Content="Drop to a normal shell when the commands finish"/>
        <CheckBox x:Name="ChkKeepAlive" Content="Send keep-alives so idle sessions don't get dropped"/>

        <TextBlock Text="Login" Style="{StaticResource Section}"/>
        <TextBlock x:Name="TxtKeyInfo" Style="{StaticResource Hint}"/>
        <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
          <Button x:Name="BtnSetupKey" Content="Set up key login" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
          <Button x:Name="BtnTest" Content="Test connection" Style="{StaticResource Btn}"/>
        </StackPanel>
        <TextBlock x:Name="TxtKeyStatus" TextWrapping="Wrap" Margin="0,8,0,0"/>

        <TextBlock Text="Command Windows Terminal will run" Style="{StaticResource Section}"/>
        <TextBox x:Name="TxtCmd" IsReadOnly="True" TextWrapping="Wrap" Margin="0,8,0,0" Background="#F6F8FA"
                 FontFamily="Cascadia Mono, Consolas" FontSize="12" Foreground="#3B434B"/>
      </StackPanel>
    </ScrollViewer>

    <!-- Appearance -->
    <Border Grid.Column="2" Background="White" BorderBrush="#E1E4E8" BorderThickness="1,0,0,0">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="AppearancePanel" Margin="20,4,20,20">
          <TextBlock Text="Appearance" Style="{StaticResource Section}"/>

          <Border CornerRadius="8" BorderBrush="#CDD2D9" BorderThickness="1" Margin="0,12,0,0" Background="#202124">
            <StackPanel>
              <Border Padding="8,8,8,0">
                <Border x:Name="PrevTab" CornerRadius="6,6,0,0" Padding="12,6" HorizontalAlignment="Left">
                  <TextBlock x:Name="PrevTabText" FontSize="12" FontWeight="SemiBold"/>
                </Border>
              </Border>
              <Border x:Name="PrevBody" Padding="12,10" MinHeight="96" CornerRadius="0,0,7,7">
                <StackPanel>
                  <TextBlock x:Name="PrevLine1" FontFamily="Cascadia Mono, Consolas" FontSize="12" Opacity="0.65"/>
                  <TextBlock x:Name="PrevLine2" FontFamily="Cascadia Mono, Consolas" FontSize="12" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/>
                  <TextBlock x:Name="PrevLine3" FontFamily="Cascadia Mono, Consolas" FontSize="12" Margin="0,2,0,0"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </Border>

          <TextBlock Text="Presets" Style="{StaticResource Label}" Margin="0,16,0,6"/>
          <WrapPanel x:Name="PresetPanel"/>

          <TextBlock Text="Tab color" Style="{StaticResource Label}"/>
          <StackPanel Orientation="Horizontal">
            <Border x:Name="SwTab" Tag="tab" Style="{StaticResource Swatch}"/>
            <TextBox x:Name="TxtTab" Width="100" FontFamily="Cascadia Mono, Consolas"/>
          </StackPanel>
          <TextBlock Text="Background" Style="{StaticResource Label}"/>
          <StackPanel Orientation="Horizontal">
            <Border x:Name="SwBg" Tag="bg" Style="{StaticResource Swatch}"/>
            <TextBox x:Name="TxtBg" Width="100" FontFamily="Cascadia Mono, Consolas"/>
          </StackPanel>
          <TextBlock Text="Text" Style="{StaticResource Label}"/>
          <StackPanel Orientation="Horizontal">
            <Border x:Name="SwFg" Tag="fg" Style="{StaticResource Swatch}"/>
            <TextBox x:Name="TxtFg" Width="100" FontFamily="Cascadia Mono, Consolas"/>
          </StackPanel>

          <TextBlock Text="Base color scheme" Style="{StaticResource Label}"/>
          <ComboBox x:Name="CmbScheme" Padding="6,5"/>
          <TextBlock Style="{StaticResource Hint}" Text="Sets the other colors programs use (ls, git, syntax highlighting). Background and text above override it."/>
        </StackPanel>
      </ScrollViewer>
    </Border>

    <!-- Footer -->
    <Border Grid.Row="1" Grid.ColumnSpan="3" Background="White" BorderBrush="#E1E4E8" BorderThickness="0,1,0,0" Padding="16,10">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <CheckBox x:Name="ChkCloseAfter" Content="Close after opening" VerticalAlignment="Center" Margin="0,0,16,0"
                    ToolTip="Close this window once your sessions open in Windows Terminal"/>
          <Button x:Name="BtnLaunch" Content="Open in Terminal" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
          <Button x:Name="BtnSave" Content="Save to Windows Terminal" Style="{StaticResource Primary}"/>
        </StackPanel>
        <StackPanel VerticalAlignment="Center" Margin="0,0,16,0">
          <TextBlock x:Name="TxtStatus"/>
          <TextBlock x:Name="TxtPath" Foreground="#8C959F" FontSize="11" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
$ui = @{}
foreach ($m in [regex]::Matches($Xaml.OuterXml, 'x:Name="(\w+)"')) {
    $n = $m.Groups[1].Value
    if ($n -ne 'b') { $ui[$n] = $win.FindName($n) }
}
#endregion

#region UI helpers
$BrushConv = New-Object System.Windows.Media.BrushConverter
function To-Brush([string]$Hex) {
    try { $BrushConv.ConvertFromString($Hex) } catch { $BrushConv.ConvertFromString('#000000') }
}
function Test-Hex([string]$Hex) { $Hex -match '^#[0-9A-Fa-f]{6}$' }
function Get-ContrastBrush([string]$Hex) {
    try { $c = [System.Drawing.ColorTranslator]::FromHtml($Hex) } catch { return (To-Brush '#FFFFFF') }
    if ((0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) -gt 150) { To-Brush '#111111' } else { To-Brush '#FFFFFF' }
}

function Show-Message([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    if ($win -and $win.IsLoaded) { [Windows.MessageBox]::Show($win, $Text, 'WT SSH Manager', $Buttons, $Icon) }
    else { [Windows.MessageBox]::Show($Text, 'WT SSH Manager', $Buttons, $Icon) }
}

function Invoke-Safe([scriptblock]$Action) {
    try { & $Action } catch { Show-Message ("Something went wrong:`n`n" + $_.Exception.Message) 'OK' 'Error' | Out-Null }
}

function Set-Status([string]$Text, [string]$Kind = 'normal') {
    $ui.TxtStatus.Text = $Text
    $ui.TxtStatus.Foreground = switch ($Kind) {
        'ok'    { To-Brush '#1A7F37' }
        'warn'  { To-Brush '#9A6700' }
        'error' { To-Brush '#CF222E' }
        default { To-Brush '#1F2328' }
    }
}

function Set-Dirty {
    $script:Dirty = $true
    Set-Status 'Unsaved changes' 'warn'
}

function Set-KeyStatus($Ok, [string]$Text) {
    $ui.TxtKeyStatus.Text = $Text
    $ui.TxtKeyStatus.Foreground = if ($Ok -eq $true) { To-Brush '#1A7F37' } elseif ($Ok -eq $false) { To-Brush '#CF222E' } else { To-Brush '#6E7781' }
}

function Update-KeyInfo {
    $state = if (Test-Path "$KeyPath.pub") { 'found' } else { 'not created yet; it will be made the first time you set up key login' }
    $ui.TxtKeyInfo.Text = "Passwords are never stored. Set up key login once per server: you type the password one time in a console window, your public key is added to the server, and every login after that is automatic.`n`nYour key: $KeyPath ($state)"
}

function New-ListItemContent($s) {
    $dp = New-Object Windows.Controls.DockPanel
    $dp.Margin = New-Object Windows.Thickness 0, 3, 0, 3

    $sw = New-Object Windows.Controls.Border
    $sw.Width = 6
    $sw.CornerRadius = New-Object Windows.CornerRadius 3
    $sw.Background = To-Brush $s.tabColor
    $sw.Margin = New-Object Windows.Thickness 0, 0, 10, 0
    [Windows.Controls.DockPanel]::SetDock($sw, [Windows.Controls.Dock]::Left)
    [void]$dp.Children.Add($sw)

    $sp = New-Object Windows.Controls.StackPanel
    $t1 = New-Object Windows.Controls.TextBlock
    $t1.Text = if ($s.name) { $s.name } else { '(unnamed)' }
    $t1.FontWeight = [Windows.FontWeights]::SemiBold
    $t1.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $t2 = New-Object Windows.Controls.TextBlock
    $t2.Text = if ($s.host) { (Get-Target $s) + $(if ([int]$s.port -ne 22) { ":$($s.port)" } else { '' }) } else { 'No host yet' }
    $t2.Foreground = To-Brush '#6E7781'
    $t2.FontSize = 12
    $t2.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    [void]$sp.Children.Add($t1)
    [void]$sp.Children.Add($t2)
    [void]$dp.Children.Add($sp)
    $dp
}

function Refresh-List([string]$SelectId) {
    $script:Loading = $true
    $ui.LstSessions.Items.Clear()
    foreach ($s in $script:Sessions) {
        $it = New-Object Windows.Controls.ListBoxItem
        $it.Content = New-ListItemContent $s
        $it.Tag = $s.id
        $it.Padding = New-Object Windows.Thickness 6, 4, 6, 4
        [void]$ui.LstSessions.Items.Add($it)
        if ($s.id -eq $SelectId) { $ui.LstSessions.SelectedItem = $it }
    }
    $script:Loading = $false

    if ($ui.LstSessions.SelectedItem) { Load-Session (Find-Session $ui.LstSessions.SelectedItem.Tag) }
    elseif ($ui.LstSessions.Items.Count) { $ui.LstSessions.SelectedIndex = 0 }
    else { Load-Session $null }
    Update-LaunchButton
}

function Get-ListItem([string]$Id) {
    foreach ($it in $ui.LstSessions.Items) { if ($it.Tag -eq $Id) { return $it } }
    $null
}

# Selected sessions, in list order
function Get-SelectedSessions {
    foreach ($it in $ui.LstSessions.Items) {
        if ($it.IsSelected) { Find-Session $it.Tag }
    }
}

function Update-LaunchButton {
    $n = $ui.LstSessions.SelectedItems.Count
    $ui.BtnLaunch.Content = if ($n -gt 1) { "Open $n sessions..." } else { 'Open in Terminal' }
    $ui.BtnLaunch.IsEnabled = ($n -ge 1)
    $ui.BtnDup.IsEnabled = ($n -eq 1)
    $ui.BtnDel.Content = if ($n -gt 1) { "Delete $n" } else { 'Delete' }
}

function Build-LaunchMenu {
    $m = New-Object Windows.Controls.ContextMenu
    foreach ($opt in @(@('tabs', 'Tabs in one window'), @('grid', 'Split panes in one tab'), @('windows', 'Separate windows'))) {
        $mi = New-Object Windows.Controls.MenuItem
        $mi.Header = $opt[1]
        $mi.Tag = $opt[0]
        $mi.Add_Click({ param($sender, $e) Invoke-Safe { Start-Sessions @(Get-SelectedSessions) $sender.Tag } })
        [void]$m.Items.Add($mi)
    }
    $m.Placement = [Windows.Controls.Primitives.PlacementMode]::Top
    $script:LaunchMenu = $m
}

function Build-PresetChips {
    $script:PresetChips = @()
    foreach ($name in $Presets.Keys) {
        $p = $Presets[$name]
        $chip = New-Object Windows.Controls.Border
        $chip.Width = 94; $chip.Height = 44
        $chip.CornerRadius = New-Object Windows.CornerRadius 6
        $chip.Margin = New-Object Windows.Thickness 0, 0, 6, 6
        $chip.Background = To-Brush $p.bg
        $chip.BorderThickness = New-Object Windows.Thickness 2
        $chip.BorderBrush = To-Brush '#00FFFFFF'
        $chip.Cursor = [Windows.Input.Cursors]::Hand
        $chip.Tag = $name
        $chip.ToolTip = "$name preset"

        $sp = New-Object Windows.Controls.StackPanel
        $strip = New-Object Windows.Controls.Border
        $strip.Height = 7
        $strip.CornerRadius = New-Object Windows.CornerRadius 4, 4, 0, 0
        $strip.Background = To-Brush $p.tab
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = $name
        $tb.Foreground = To-Brush $p.fg
        $tb.FontSize = 12
        $tb.Margin = New-Object Windows.Thickness 9, 7, 0, 0
        [void]$sp.Children.Add($strip)
        [void]$sp.Children.Add($tb)
        $chip.Child = $sp

        $chip.Add_MouseLeftButtonUp({ param($sender, $e) Invoke-Safe { Apply-Preset $sender.Tag } })
        [void]$ui.PresetPanel.Children.Add($chip)
        $script:PresetChips += $chip
    }
}

function Highlight-Preset {
    $s = $script:Current
    foreach ($chip in $script:PresetChips) {
        $chip.BorderBrush = if ($s -and $chip.Tag -eq $s.preset) { To-Brush '#2563EB' } else { To-Brush '#00FFFFFF' }
    }
}
#endregion

#region Editor logic
function Load-Session($s) {
    $script:Current = $s
    $on = [bool]$s
    $ui.EditorPanel.IsEnabled = $on
    $ui.AppearancePanel.IsEnabled = $on
    $ui.BtnDup.IsEnabled = $on
    $ui.BtnDel.IsEnabled = $on

    $script:Loading = $true
    try {
        if (-not $s) {
            foreach ($n in 'TxtName', 'TxtHost', 'TxtUser', 'TxtPort', 'TxtStartup', 'TxtTab', 'TxtBg', 'TxtFg', 'TxtCmd') { $ui[$n].Text = '' }
            $ui.TxtKeyStatus.Text = ''
            Highlight-Preset
            return
        }
        $ui.TxtName.Text = $s.name
        $ui.TxtHost.Text = $s.host
        $ui.TxtUser.Text = $s.user
        $ui.TxtPort.Text = [string]$s.port
        $ui.TxtStartup.Text = $s.startup
        $ui.ChkKeepShell.IsChecked = [bool]$s.keepShell
        $ui.ChkKeepAlive.IsChecked = [bool]$s.keepAlive
        $ui.TxtTab.Text = $s.tabColor
        $ui.TxtBg.Text = $s.background
        $ui.TxtFg.Text = $s.foreground
        if (-not $ui.CmbScheme.Items.Contains($s.scheme)) { [void]$ui.CmbScheme.Items.Add($s.scheme) }
        $ui.CmbScheme.SelectedItem = $s.scheme
        foreach ($n in 'TxtPort', 'TxtTab', 'TxtBg', 'TxtFg') { $ui[$n].BorderBrush = To-Brush '#CDD2D9' }
        Set-KeyStatus $null ''
    } finally {
        $script:Loading = $false
    }
    Update-Visuals
}

function Update-Visuals {
    $s = $script:Current
    if (-not $s) { return }

    $ui.SwTab.Background = To-Brush $s.tabColor
    $ui.SwBg.Background  = To-Brush $s.background
    $ui.SwFg.Background  = To-Brush $s.foreground

    $ui.PrevTab.Background = To-Brush $s.tabColor
    $ui.PrevTabText.Foreground = Get-ContrastBrush $s.tabColor
    $ui.PrevTabText.Text = if ($s.name) { $s.name } else { 'New session' }
    $ui.PrevBody.Background = To-Brush $s.background
    $fg = To-Brush $s.foreground
    foreach ($n in 'PrevLine1', 'PrevLine2', 'PrevLine3') { $ui[$n].Foreground = $fg }

    $who = if ($s.user) { $s.user } else { $env:USERNAME.ToLower() }
    $hostShort = if (-not $s.host) { 'server' }
                 elseif ($s.host -match '^\d{1,3}(\.\d{1,3}){3}$') { $s.host }
                 else { ($s.host -split '\.')[0] }
    $first = (($s.startup -replace "`r", '') -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    $ui.PrevLine1.Text = 'Last login: ' + (Get-Date).ToString('ddd MMM d HH:mm:ss yyyy')
    $ui.PrevLine2.Text = "${who}@${hostShort}:~`$ $first"
    $ui.PrevLine3.Text = [string][char]0x2588

    $ui.TxtCmd.Text = if ($s.host) { Build-CommandLine $s } else { 'Enter a host to see the command.' }

    Highlight-Preset
    $li = Get-ListItem $s.id
    if ($li) { $li.Content = New-ListItemContent $s }
}

function Sync-FromUI {
    if ($script:Loading -or -not $script:Current) { return }
    $s = $script:Current

    $s.name = $ui.TxtName.Text.Trim()
    $s.host = $ui.TxtHost.Text.Trim()
    $s.user = $ui.TxtUser.Text.Trim()

    $port = 0
    if ([int]::TryParse($ui.TxtPort.Text.Trim(), [ref]$port) -and $port -ge 1 -and $port -le 65535) {
        $s.port = $port
        $ui.TxtPort.BorderBrush = To-Brush '#CDD2D9'
    } else {
        $ui.TxtPort.BorderBrush = To-Brush '#CF222E'
    }

    $s.startup   = $ui.TxtStartup.Text
    $s.keepShell = [bool]$ui.ChkKeepShell.IsChecked
    $s.keepAlive = [bool]$ui.ChkKeepAlive.IsChecked

    foreach ($pair in @(@('TxtTab', 'tabColor'), @('TxtBg', 'background'), @('TxtFg', 'foreground'))) {
        $tb = $ui[$pair[0]]
        $val = $tb.Text.Trim()
        if (Test-Hex $val) {
            $s.($pair[1]) = $val.ToUpper()
            $tb.BorderBrush = To-Brush '#CDD2D9'
        } else {
            $tb.BorderBrush = To-Brush '#CF222E'
        }
    }
    if ($ui.CmbScheme.SelectedItem) { $s.scheme = [string]$ui.CmbScheme.SelectedItem }

    $s.preset = 'Custom'
    foreach ($n in $Presets.Keys) {
        $p = $Presets[$n]
        if ($p.tab -eq $s.tabColor -and $p.bg -eq $s.background -and $p.fg -eq $s.foreground) { $s.preset = $n; break }
    }

    Set-Dirty
    Update-Visuals
}

function Apply-Preset([string]$Name) {
    $s = $script:Current
    if (-not $s) { return }
    $p = $Presets[$Name]
    $s.preset = $Name
    $s.tabColor = $p.tab; $s.background = $p.bg; $s.foreground = $p.fg; $s.scheme = $p.scheme

    $script:Loading = $true
    try {
        $ui.TxtTab.Text = $p.tab; $ui.TxtBg.Text = $p.bg; $ui.TxtFg.Text = $p.fg
        foreach ($n in 'TxtTab', 'TxtBg', 'TxtFg') { $ui[$n].BorderBrush = To-Brush '#CDD2D9' }
        $ui.CmbScheme.SelectedItem = $p.scheme
    } finally { $script:Loading = $false }

    Set-Dirty
    Update-Visuals
}

function Pick-Color([string]$Which) {
    if (-not $script:Current) { return }
    $map = @{ tab = 'TxtTab'; bg = 'TxtBg'; fg = 'TxtFg' }
    $tb = $ui[$map[$Which]]
    $dlg = New-Object System.Windows.Forms.ColorDialog
    $dlg.FullOpen = $true
    $dlg.AnyColor = $true
    try { $dlg.Color = [System.Drawing.ColorTranslator]::FromHtml($tb.Text) } catch {}
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $c = $dlg.Color
        $tb.Text = '#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B   # triggers Sync-FromUI
    }
}
#endregion

#region Actions
function Invoke-New {
    $used = @($script:Sessions | ForEach-Object { $_.preset })
    $pick = @($Presets.Keys | Where-Object { $_ -ne 'Paper' -and $used -notcontains $_ }) | Select-Object -First 1
    if (-not $pick) { $pick = 'Ocean' }
    $s = New-Session $pick
    if ($script:Current) { $s.user = $script:Current.user }
    [void]$script:Sessions.Add($s)
    Set-Dirty
    Refresh-List $s.id
    [void]$ui.TxtName.Focus()
    $ui.TxtName.SelectAll()
}

function Invoke-Duplicate {
    $src = $script:Current
    if (-not $src) { return }
    $s = ConvertTo-Session $src
    $s.id = '{' + [guid]::NewGuid().ToString() + '}'
    $s.name = "$($src.name) (copy)"
    [void]$script:Sessions.Insert($script:Sessions.IndexOf($src) + 1, $s)
    Set-Dirty
    Refresh-List $s.id
}

function Invoke-Delete {
    $targets = @(Get-SelectedSessions)
    if (-not $targets.Count -and $script:Current) { $targets = @($script:Current) }
    if (-not $targets.Count) { return }
    $what = if ($targets.Count -eq 1) { "`"$($targets[0].name)`"" } else { "$($targets.Count) sessions" }
    $r = Show-Message "Delete $what?`n`nThe Windows Terminal profiles are removed the next time you save." 'YesNo' 'Question'
    if ($r -ne 'Yes') { return }
    $i = $script:Sessions.IndexOf($targets[0])
    foreach ($t in $targets) { $script:Sessions.Remove($t) }
    $next = if ($script:Sessions.Count) { $script:Sessions[[Math]::Min($i, $script:Sessions.Count - 1)].id } else { $null }
    Set-Dirty
    Refresh-List $next
}

function Invoke-Save {
    foreach ($s in $script:Sessions) {
        if (-not $s.name -or -not $s.host) {
            Refresh-List $s.id
            Show-Message 'Each session needs a name and a host before saving.' 'OK' 'Warning' | Out-Null
            return $false
        }
    }
    $result = Save-ToWT
    if (-not $result) { return $false }
    Save-Data
    $script:Dirty = $false
    Set-Status ("Saved {0} session{1} to Windows Terminal." -f $script:Sessions.Count, $(if ($script:Sessions.Count -eq 1) { '' } else { 's' })) 'ok'
    $ui.TxtPath.Text = "$($result.Path)   (backup: $($result.Backup))"
    return $true
}

function Start-WT([string]$Arguments) {
    try {
        Start-Process -FilePath 'wt.exe' -ArgumentList $Arguments -ErrorAction Stop
        return $true
    } catch {
        Show-Message "Couldn't start Windows Terminal (wt.exe).`n`n$($_.Exception.Message)" 'OK' 'Error' | Out-Null
        return $false
    }
}

# Builds a wt.exe command that tiles the sessions in one tab: columns first, then rows within each column.
function Build-GridArgs([string[]]$Ids) {
    $inv  = [Globalization.CultureInfo]::InvariantCulture
    $n    = $Ids.Count
    $cols = [int][Math]::Ceiling([Math]::Sqrt($n))
    $rows = @(for ($j = 0; $j -lt $cols; $j++) { [int][Math]::Floor($n / $cols) + $(if ($j -lt ($n % $cols)) { 1 } else { 0 }) })

    $cells = @(); $k = 0
    for ($j = 0; $j -lt $cols; $j++) {
        $col = @()
        for ($r = 0; $r -lt $rows[$j]; $r++) { $col += $Ids[$k]; $k++ }
        $cells += , $col
    }

    $cmds = New-Object System.Collections.Generic.List[string]
    $cmds.Add("nt -p `"$($cells[0][0])`"")
    for ($j = 1; $j -lt $cols; $j++) {
        $size = ($cols - $j) / ($cols - $j + 1)
        $cmds.Add(('sp -V -s {0} -p "{1}"' -f $size.ToString('0.####', $inv), $cells[$j][0]))
    }
    for ($j = $cols - 1; $j -ge 0; $j--) {
        $r = $rows[$j]
        for ($i = 1; $i -lt $r; $i++) {
            $size = ($r - $i) / ($r - $i + 1)
            $cmds.Add(('sp -H -s {0} -p "{1}"' -f $size.ToString('0.####', $inv), $cells[$j][$i]))
        }
        if ($j -gt 0) { $cmds.Add('mf left') }
    }
    '-w 0 ' + ($cmds -join ' ; ')
}

function Start-Sessions($List, [string]$Mode = 'tabs') {
    $List = @($List | Where-Object { $_ })
    if (-not $List.Count) { return }
    $unsaved = @($List | Where-Object { $script:WrittenGuids -notcontains $_.id }).Count
    if ($script:Dirty -or $unsaved) {
        if (-not (Invoke-Save)) { return }
        Start-Sleep -Milliseconds 800   # let Windows Terminal pick up the new settings
    }
    $ids = @($List | ForEach-Object { $_.id })
    $ok = $false
    switch ($Mode) {
        'windows' {
            foreach ($id in $ids) {
                if (Start-WT "-w new nt -p `"$id`"") { $ok = $true }
                Start-Sleep -Milliseconds 300
            }
        }
        'grid' {
            if ($ids.Count -gt 9) {
                if ((Show-Message "Tile $($ids.Count) sessions in one tab? The panes will be small." 'YesNo' 'Question') -ne 'Yes') { return }
            }
            $ok = Start-WT (Build-GridArgs $ids)
        }
        default {
            $ok = Start-WT ('-w 0 ' + (($ids | ForEach-Object { "nt -p `"$_`"" }) -join ' ; '))
        }
    }
    if ($ok -and $ui.ChkCloseAfter.IsChecked) { $win.Close() }
}

function Invoke-LaunchSelected {
    $sel = @(Get-SelectedSessions)
    if (-not $sel.Count -and $script:Current) { $sel = @($script:Current) }
    if ($sel.Count -eq 0) { return }
    if ($sel.Count -eq 1) { Start-Sessions $sel 'tabs'; return }
    $script:LaunchMenu.PlacementTarget = $ui.BtnLaunch
    $script:LaunchMenu.IsOpen = $true
}

function Test-KeyLogin {
    $s = $script:Current
    if (-not $s -or -not $s.host) { Set-KeyStatus $false 'Enter a host first.'; return }
    Set-KeyStatus $null 'Testing connection...'
    $win.Cursor = [Windows.Input.Cursors]::Wait
    $win.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
    try {
        $out = & ssh.exe -o BatchMode=yes -o ConnectTimeout=6 -p ([string]$s.port) (Get-Target $s) 'echo __WT_OK__' 2>&1 | Out-String
    } catch {
        $out = $_.Exception.Message
    } finally {
        $win.Cursor = $null
    }
    if ($out -match '__WT_OK__') {
        Set-KeyStatus $true 'Key login works. No password needed for this server.'
    } elseif ($out -match 'Host key verification failed') {
        Set-KeyStatus $false "This server's identity isn't trusted yet. Click Set up key login; you'll be asked to confirm it once."
    } elseif ($out -match 'Permission denied') {
        Set-KeyStatus $false 'The server did not accept the key yet. Click Set up key login. (If your key has a passphrase, this test only passes while ssh-agent holds it.)'
    } else {
        $last = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        Set-KeyStatus $false "Couldn't connect: $last"
    }
}

function Invoke-KeySetup {
    $s = $script:Current
    if (-not $s -or -not $s.host) { Set-KeyStatus $false 'Enter a host first.'; return }
    if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
        Show-Message 'The OpenSSH client (ssh.exe) is not installed. Add "OpenSSH Client" from Windows Optional Features, then try again.' 'OK' 'Warning' | Out-Null
        return
    }

    $pubPath = "$KeyPath.pub"
    if (-not (Test-Path $pubPath)) {
        if (Test-Path $KeyPath) {
            Show-Message "Found $KeyPath but not its .pub file. Recreate it with:`n`nssh-keygen -y -f `"$KeyPath`" > `"$pubPath`"" 'OK' 'Warning' | Out-Null
            return
        }
        $msg = "No SSH key exists yet, so one will be created at:`n$KeyPath`n`n" +
               "A console window will ask for a passphrase:`n" +
               "  - Leave it blank for fully automatic logins.`n" +
               "  - Or set one for extra protection. You'll type it when connecting unless ssh-agent holds it."
        if ((Show-Message $msg 'OKCancel' 'Information') -ne 'OK') { return }
        $dir = Split-Path $KeyPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Start-Process -FilePath 'ssh-keygen.exe' -ArgumentList "-t ed25519 -f `"$KeyPath`" -C `"$($env:USERNAME)@$($env:COMPUTERNAME)`"" -Wait
        Update-KeyInfo
        if (-not (Test-Path $pubPath)) { Set-KeyStatus $false 'The key was not created.'; return }
    }

    $key = ([IO.File]::ReadAllText($pubPath)).Trim()
    if ($key -match "['`"\r\n]") { Show-Message "Unexpected characters in $pubPath." 'OK' 'Error' | Out-Null; return }

    $target = Get-Target $s
    $remote = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && " +
              "(grep -qxF '$key' ~/.ssh/authorized_keys || echo '$key' >> ~/.ssh/authorized_keys) && echo 'Key installed.'"
    $q = { param($v) "'" + ([string]$v -replace "'", "''") + "'" }

    $ps = @"
`$Host.UI.RawUI.WindowTitle = 'Install SSH key'
Write-Host $(& $q "Installing your SSH key on $target") -ForegroundColor Cyan
Write-Host 'Type the server password when asked. It is used once and never saved.' -ForegroundColor Gray
Write-Host ''
& ssh.exe -p $(& $q $s.port) $(& $q $target) $(& $q $remote)
`$code = `$LASTEXITCODE
Write-Host ''
if (`$code -eq 0) { Write-Host 'Done. Future logins to this server will use the key.' -ForegroundColor Green }
else { Write-Host "ssh exited with code `$code." -ForegroundColor Red }
Read-Host 'Press Enter to close' | Out-Null
exit `$code
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps))
    Set-KeyStatus $null 'Finish in the console window that just opened...'
    $win.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" -Wait -PassThru
    if ($proc.ExitCode -eq 0) { Test-KeyLogin }
    else { Set-KeyStatus $false "Key install didn't complete (ssh exit code $($proc.ExitCode))." }
}
#endregion

#region Wire up
$ui.LstSessions.Add_SelectionChanged({
    param($sender, $e)
    if ($script:Loading) { return }
    Invoke-Safe {
        $it = $null
        if ($e.AddedItems.Count) {
            $it = $e.AddedItems[$e.AddedItems.Count - 1]
        } elseif ($ui.LstSessions.SelectedItems.Count -and $script:Current) {
            $cur = Get-ListItem $script:Current.id
            if (-not ($cur -and $cur.IsSelected)) { $it = $ui.LstSessions.SelectedItem }
        }
        if ($it) { Load-Session (Find-Session $it.Tag) }
        Update-LaunchButton
    }
})
$ui.LstSessions.Add_MouseDoubleClick({
    param($sender, $e)
    $d = $e.OriginalSource
    while ($d -and -not ($d -is [Windows.Controls.ListBoxItem])) {
        if ($d -is [Windows.Media.Visual]) { $d = [Windows.Media.VisualTreeHelper]::GetParent($d) }
        else { $d = [Windows.LogicalTreeHelper]::GetParent($d) }
    }
    if ($d) { Invoke-Safe { Start-Sessions @(Find-Session $d.Tag) 'tabs' } }
})
$ui.LstSessions.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [Windows.Input.Key]::Return) { $e.Handled = $true; Invoke-Safe { Invoke-LaunchSelected } }
})
foreach ($n in 'TxtName', 'TxtHost', 'TxtUser', 'TxtPort', 'TxtStartup', 'TxtTab', 'TxtBg', 'TxtFg') {
    $ui[$n].Add_TextChanged({ Invoke-Safe { Sync-FromUI } })
}
$ui.ChkKeepShell.Add_Click({ Invoke-Safe { Sync-FromUI } })
$ui.ChkKeepAlive.Add_Click({ Invoke-Safe { Sync-FromUI } })
$ui.CmbScheme.Add_SelectionChanged({ Invoke-Safe { Sync-FromUI } })
foreach ($n in 'SwTab', 'SwBg', 'SwFg') {
    $ui[$n].Add_MouseLeftButtonUp({ param($sender, $e) Invoke-Safe { Pick-Color $sender.Tag } })
}

$ui.BtnNew.Add_Click({ Invoke-Safe { Invoke-New } })
$ui.BtnDup.Add_Click({ Invoke-Safe { Invoke-Duplicate } })
$ui.BtnDel.Add_Click({ Invoke-Safe { Invoke-Delete } })
$ui.BtnSave.Add_Click({ Invoke-Safe { [void](Invoke-Save) } })
$ui.ChkCloseAfter.Add_Click({ Invoke-Safe { Save-Prefs } })
$ui.BtnLaunch.Add_Click({ Invoke-Safe { Invoke-LaunchSelected } })
$ui.BtnSetupKey.Add_Click({ Invoke-Safe { Invoke-KeySetup } })
$ui.BtnTest.Add_Click({ Invoke-Safe { Test-KeyLogin } })

$win.Add_Closing({
    param($sender, $e)
    if (-not $script:Dirty) { return }
    $r = Show-Message 'Save changes to Windows Terminal before closing?' 'YesNoCancel' 'Question'
    if ($r -eq 'Cancel') { $e.Cancel = $true }
    elseif ($r -eq 'Yes') { if (-not (Invoke-Save)) { $e.Cancel = $true } }
})
#endregion

#region Start
$script:Loading = $false
$script:Dirty = $false
$script:Current = $null

Load-Data
Build-PresetChips
Build-LaunchMenu
Load-Prefs
foreach ($sc in $Schemes) { [void]$ui.CmbScheme.Items.Add($sc) }
Update-KeyInfo

$wtPath = Find-WTSettings
$ui.TxtPath.Text = if ($wtPath) { "Windows Terminal settings: $wtPath" } else { "Windows Terminal settings.json not found yet. You can browse for it when you save." }

$firstId = if ($script:Sessions.Count) { $script:Sessions[0].id } else { $null }
Refresh-List $firstId

if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    Set-Status 'OpenSSH client not found. Add "OpenSSH Client" from Windows Optional Features.' 'warn'
} elseif (-not $script:Sessions.Count) {
    Set-Status 'Click New to add your first session.'
} else {
    Set-Status ("{0} session{1} loaded." -f $script:Sessions.Count, $(if ($script:Sessions.Count -eq 1) { '' } else { 's' }))
}

[void]$win.ShowDialog()
#endregion
