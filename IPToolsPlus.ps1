﻿﻿﻿﻿﻿# ============================================================
#  IPToolsPlus —— IP 地址修改器复刻版 + IPv6 开关
#  功能：多网卡 IP 配置（DHCP/静态切换、网关、DNS）、
#        配置方案保存/一键应用、IPv6 禁用/启用、
#        网卡启用/禁用、MAC 地址修改
#  运行：需要管理员权限（自动提权）
#  方案文件：本目录下 ip_profiles.json
# ============================================================

# --- 检测并自动以管理员身份重新启动 ---
$id    = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" `
        -Verb RunAs -WindowStyle Hidden
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# DPI 感知 + 输入框占位符（EM_SETCUEBANNER）API
Add-Type -Namespace Native -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern int SetProcessDpiAwareness(int value);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
'@
# 优先 Per-Monitor V2：多屏 DPI 不一致时，标题栏按钮区域按当前屏幕正确渲染，
# 避免 SystemAware 在副屏出现标题栏右上角白色块/台阶；旧系统逐级回退
$dpiSet = $false
try { $dpiSet = [Native.Win32]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { $dpiSet = $false }
if (-not $dpiSet) { try { $dpiSet = ([Native.Win32]::SetProcessDpiAwareness(2) -eq 0) } catch { $dpiSet = $false } }
if (-not $dpiSet) { [void][Native.Win32]::SetProcessDPIAware() }

# 数据目录：exe 启动时通过环境变量指定；直接运行脚本时用脚本所在目录
$baseDir = if ($env:IPTOOLSPLUS_DIR) { $env:IPTOOLSPLUS_DIR }
           elseif ($PSScriptRoot)    { $PSScriptRoot }
           else                      { Split-Path -Parent $PSCommandPath }
$profileFile = Join-Path $baseDir 'ip_profiles.json'

# ---------------- 工具函数 ----------------
function Show-Msg([string]$text, [string]$title = '提示', [string]$icon = 'Information') {
    [void][Windows.Forms.MessageBox]::Show($form, $text, $title, 'OK', $icon)
}

function Test-Ipv4([string]$s) {
    if ($s -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($o in $s.Split('.')) { if ([int]$o -gt 255) { return $false } }
    return $true
}

function ConvertTo-PrefixLength([string]$mask) {
    $bits = 0
    foreach ($o in $mask.Split('.')) {
        if ([int]$o -gt 255) { return -1 }
        $bits += ([convert]::ToString([byte]$o, 2)).Trim('0').Length
    }
    return $bits
}

function ConvertTo-SubnetMask([int]$prefix) {
    if ($prefix -lt 0 -or $prefix -gt 32) { return '' }
    $bin = ('1' * $prefix).PadRight(32, '0')
    ([IPAddress]([Convert]::ToUInt64($bin, 2))).ToString()
}

function Get-StatusText([string]$s) {
    switch ($s) {
        'Up'           { '已连接' }
        'Disconnected' { '未连接' }
        'Disabled'     { '已禁用' }
        'Not Present'  { '不存在' }
        default        { $s }
    }
}

function Load-Profiles {
    if (Test-Path $profileFile) {
        try {
            $json = Get-Content $profileFile -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($json)) { return @() }
            $parsed = ConvertFrom-Json $json
            # 过滤 null / 垃圾元素，且必须有 Name 属性
            return @($parsed | Where-Object { $_ -and $_.PSObject.Properties['Name'] })
        }
        catch { return @() }
    }
    return @()
}

function ConvertTo-JsonString([string]$s) {
    '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Save-Profiles {
    param([AllowEmptyCollection()][object[]]$items)
    # 手工构建 JSON，绕开 PS5.1 ConvertTo-Json 对空数组/嵌套数组的序列化怪癖
    $objs = foreach ($p in @($items)) {
        if (-not $p) { continue }
        '    {{ "Name": {0}, "Adapter": {1}, "Dhcp": {2}, "Ip": {3}, "Mask": {4}, "Gateway": {5}, "Dns1": {6}, "Dns2": {7} }}' -f `
            (ConvertTo-JsonString ([string]$p.Name)),
            (ConvertTo-JsonString ([string]$p.Adapter)),
            $(if ($p.Dhcp) { 'true' } else { 'false' }),
            (ConvertTo-JsonString ([string]$p.Ip)),
            (ConvertTo-JsonString ([string]$p.Mask)),
            (ConvertTo-JsonString ([string]$p.Gateway)),
            (ConvertTo-JsonString ([string]$p.Dns1)),
            (ConvertTo-JsonString ([string]$p.Dns2))
    }
    $body = @($objs) -join ",`r`n"
    $json = if ($body) { "[`r`n$body`r`n]" } else { '[]' }
    Set-Content -Path $profileFile -Value $json -Encoding UTF8
}

# ---------------- 原始 MAC 缓存（每行：PnPDeviceID|MAC） ----------------
$macCacheFile = Join-Path $baseDir 'mac_originals.txt'
$script:macCache = @{}
if (Test-Path $macCacheFile) {
    foreach ($line in @(Get-Content $macCacheFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $i = $line.IndexOf('|')
        if ($i -gt 0) { $script:macCache[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
}
function Save-MacCache {
    $lines = @()
    foreach ($k in $script:macCache.Keys) { $lines += ('{0}|{1}' -f $k, $script:macCache[$k]) }
    Set-Content -Path $macCacheFile -Value $lines -Encoding UTF8
}
function Format-MacText([string]$s) {
    if (-not $s) { return '-' }
    if ($s -match '^[0-9A-Fa-f]{12}$') { return ($s -replace '(.{2})(?!$)', '$1-').ToUpper() }
    return $s
}
function Format-MacColon([string]$s) {
    $hex = ($s -replace '[^0-9A-Fa-f]', '')
    if ($hex -notmatch '^[0-9A-Fa-f]{12}$') { return '' }
    return (($hex -replace '(.{2})(?!$)', '$1:').ToUpper())
}

# ---------------- 界面 ----------------
$form               = New-Object Windows.Forms.Form
$form.Text          = 'IPToolsPlus - IP地址修改器 + IPv6开关'
$form.ClientSize    = New-Object Drawing.Size(860, 600)
$form.MinimumSize   = $form.Size
$form.Padding       = New-Object Windows.Forms.Padding(12)
$form.BackColor     = [Drawing.Color]::FromArgb(243, 246, 250)
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$form.AutoScaleMode       = 'Font'
$form.AutoScaleDimensions = New-Object Drawing.SizeF(6.0, 12.0)
$form.MaximizeBox   = $true    # 允许最大化/还原，放大界面后可扩大窗口查看全部内容

# ---- 顶部：网卡列表 ----
$hint          = New-Object Windows.Forms.Label
$hint.Text     = '请在下方选择网卡，配置会自动读入编辑区：'
$hint.Location = New-Object Drawing.Point(12, 10)
$hint.AutoSize = $true

$list               = New-Object Windows.Forms.ListView
$list.View          = 'Details'
$list.FullRowSelect = $true
$list.GridLines     = $true
$list.Location      = New-Object Drawing.Point(12, 34)
$list.Size          = New-Object Drawing.Size(724, 150)
$list.Anchor        = 'Top,Left,Right'
[void]$list.Columns.Add('网卡名称', 110)
[void]$list.Columns.Add('描述', 180)
[void]$list.Columns.Add('状态', 55)
[void]$list.Columns.Add('IPv4 地址', 120)
[void]$list.Columns.Add('IPv6', 45)
[void]$list.Columns.Add('当前 MAC', 105)
[void]$list.Columns.Add('原始 MAC', 105)

# ---- 中部：IP 配置编辑区 ----
$gbCfg         = New-Object Windows.Forms.GroupBox
$gbCfg.Text    = '所选网卡 IP 配置'
$gbCfg.Location = New-Object Drawing.Point(12, 192)
$gbCfg.Size    = New-Object Drawing.Size(724, 216)
$gbCfg.Anchor  = 'Top,Left,Right'

$rbDhcp          = New-Object Windows.Forms.RadioButton
$rbDhcp.Text     = '自动获取 IP (DHCP)'
$rbDhcp.Location = New-Object Drawing.Point(18, 26)
$rbDhcp.AutoSize = $true

$rbStatic          = New-Object Windows.Forms.RadioButton
$rbStatic.Text     = '使用下面的 IP 配置：'
$rbStatic.Location = New-Object Drawing.Point(18, 50)
$rbStatic.AutoSize = $true

# ---- 表格布局：5 列（标签+输入框+标签+输入框+生成按钮列），3 行 ----
$tlp             = New-Object Windows.Forms.TableLayoutPanel
$tlp.Location    = New-Object Drawing.Point(18, 74)
$tlp.Size        = New-Object Drawing.Size(690, 96)
$tlp.ColumnCount = 5
$tlp.RowCount    = 3
$tlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))    | Out-Null   # 0: 左列标签
$tlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 38))) | Out-Null   # 1: 左列输入
$tlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))    | Out-Null   # 2: 右列标签
$tlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 42))) | Out-Null   # 3: 右列输入
$tlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))    | Out-Null   # 4: 生成按钮
foreach ($i in 1..3) { $tlp.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 33.33))) | Out-Null }

function New-TableField([string]$label, [int]$col, [int]$row, [string]$cue, [string]$tag, [string]$accName) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $label; $l.AutoSize = $true
    $l.Anchor = 'Left'
    $l.Margin = New-Object Windows.Forms.Padding(0, 3, 6, 3)
    $t = New-Object Windows.Forms.TextBox
    $t.Dock = 'Fill'
    $t.Margin = New-Object Windows.Forms.Padding(0, 3, 14, 3)
    if ($tag) { $t.Tag = $tag }
    if ($accName) {
        $l.AccessibleName = $accName
        $t.AccessibleName = $accName
    }
    if ($cue) { [void][Native.Win32]::SendMessage($t.Handle, 0x1501, [IntPtr]1, $cue) }
    $tlp.Controls.Add($l, $col, $row)
    $tlp.Controls.Add($t, ($col + 1), $row)
    return $t
}

$txtIp   = New-TableField 'IP 地址：'   0 0 '例如 192.168.1.100'    'ip'   'IP 地址'
$txtMask = New-TableField '子网掩码：'  2 0 '例如 255.255.255.0'    'mask' '子网掩码'
$txtGw   = New-TableField '默认网关：'  0 1 '例如 192.168.1.1'      'gw'   '默认网关'
$txtDns1 = New-TableField '首选 DNS：'  2 1 '例如 223.5.5.5'        'dns'  '首选 DNS'
$txtDns2 = New-TableField '备用 DNS：'  0 2 '可留空，例如 223.6.6.6' 'dns'  '备用 DNS'
$txtMac  = New-TableField 'MAC 地址：'  2 2 '例如 0A1B2C3D4E5F'     'mac'  'MAC 地址'

$gbCfg.Controls.Add($tlp)

$tooltip = New-Object Windows.Forms.ToolTip
$chkMac          = New-Object Windows.Forms.CheckBox
$chkMac.Text     = '修改 MAC'
$chkMac.Location = New-Object Drawing.Point(600, 142)
$chkMac.AutoSize = $true
$tooltip.SetToolTip($chkMac, '勾选后按输入框内容修改 MAC；留空并应用即恢复原始 MAC')

# 当前选中网卡 MAC（右上角）：AutoSize Label 随文本自动变宽，不截断、无独立框体
$lblMacBox             = New-Object Windows.Forms.Label
$lblMacBox.AutoSize    = $true
$lblMacBox.BackColor   = [Drawing.Color]::Transparent   # 透明背景融入标题栏，任何 DPI 下都无独立色块
$lblMacBox.Font        = New-Object Drawing.Font('Consolas', 9.75, [Drawing.FontStyle]::Bold)
$lblMacBox.TextAlign   = 'MiddleLeft'

$btnApply          = New-Object Windows.Forms.Button
$btnApply.Text     = '应用配置'
$btnApply.Location = New-Object Drawing.Point(110, 176)
$btnApply.Size     = New-Object Drawing.Size(100, 28)

$btnApplyMac       = New-Object Windows.Forms.Button
$btnApplyMac.Text  = '应用 MAC'
$btnApplyMac.Location = New-Object Drawing.Point(220, 176)
$btnApplyMac.Size  = New-Object Drawing.Size(80, 28)
$tooltip.SetToolTip($btnApplyMac, '独立应用 MAC 地址修改，不影响 IP 配置')

$btnRead          = New-Object Windows.Forms.Button
$btnRead.Text     = '读取当前配置'
$btnRead.Location = New-Object Drawing.Point(310, 176)
$btnRead.Size     = New-Object Drawing.Size(110, 28)

# MAC 生成按钮（放在第 5 列，跟 MAC 输入框同行 row 2）
$btnGenMac           = New-Object Windows.Forms.Button
$btnGenMac.Text      = '生成'
$btnGenMac.Size      = New-Object Drawing.Size(55, 25)
$btnGenMac.Margin    = New-Object Windows.Forms.Padding(4, 3, 0, 3)
$btnGenMac.Anchor    = 'Left'
$tooltip.SetToolTip($btnGenMac, '生成一个随机的本地管理 MAC 地址')
$tlp.Controls.Add($btnGenMac, 4, 2)

$gbCfg.Controls.AddRange(@($rbDhcp, $rbStatic, $btnApply, $btnApplyMac, $btnRead, $chkMac))

# ---------------- 输入验证与交互反馈 ----------------
$errProvider           = New-Object Windows.Forms.ErrorProvider
$errProvider.BlinkStyle = 'NeverBlink'
# MAC 框的错误图标独占其右侧空间，不与复选框重叠
$errProvider.SetIconPadding($txtMac, 4)

$fieldMsgs = @{
    ip   = 'IP 地址格式不正确，例如 192.168.1.100'
    mask = '子网掩码格式不正确，例如 255.255.255.0'
    gw   = '网关格式不正确，例如 192.168.1.1（可留空）'
    dns  = 'DNS 格式不正确（支持 IP 或域名，可留空）'
    mac  = 'MAC 需 12 位十六进制，例如 0A1B2C3D4E5F'
}

function Test-DnsText([string]$s) {
    if (-not $s) { return $true }
    if (Test-Ipv4 $s) { return $true }
    return ($s -match '^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$')
}
function Test-MacText([string]$s) {
    if (-not $s) { return $true }
    return (($s -replace '[:-]', '') -match '^[0-9A-Fa-f]{12}$')
}
function Get-FieldValid($c) {
    $s = $c.Text.Trim()
    switch ("$($c.Tag)") {
        'ip'   { return (Test-Ipv4 $s) }
        'mask' { return ((-not $s) -or (Test-Ipv4 $s)) }
        'gw'   { return ((-not $s) -or (Test-Ipv4 $s)) }
        'dns'  { return (Test-DnsText $s) }
        'mac'  { return (Test-MacText $s) }
    }
    return $true
}
# 统一的焦点/错误状态样式：聚焦淡蓝、错误淡红 + ErrorProvider 图标
function Update-FieldValidation($c) {
    if (-not $c.Enabled -or -not $c.Visible) { $errProvider.SetError($c, ''); return }
    if (Get-FieldValid $c) {
        $errProvider.SetError($c, '')
        $c.BackColor = if ($c.Focused) { [Drawing.Color]::FromArgb(232, 243, 255) } else { [Drawing.Color]::White }
    }
    else {
        $errProvider.SetError($c, $fieldMsgs["$($c.Tag)"])
        $c.BackColor = [Drawing.Color]::FromArgb(255, 235, 238)
    }
}
foreach ($f in @($txtIp, $txtMask, $txtGw, $txtDns1, $txtDns2, $txtMac)) {
    $f.Add_TextChanged({ Update-FieldValidation $this })
    $f.Add_GotFocus({ Update-FieldValidation $this; if ($this.Text) { $this.SelectAll() } })
    $f.Add_LostFocus({ Update-FieldValidation $this })
}

# ---------------- DNS 智能建议（预设 + 输入历史） ----------------
$dnsHistoryFile = Join-Path $baseDir 'dns_history.txt'
$dnsPresets     = @('223.5.5.5', '119.29.29.29', '114.114.114.114', '8.8.8.8', '1.1.1.1')
function Get-DnsSuggestions {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($dnsPresets + @(Get-Content $dnsHistoryFile -Encoding UTF8 -ErrorAction SilentlyContinue))) {
        $s = "$s".Trim()
        if ($s -and -not $list.Contains($s)) { $list.Add($s) }
    }
    return $list
}
function Set-DnsSuggestions {
    $col = New-Object Windows.Forms.AutoCompleteStringCollection
    $col.AddRange([string[]]@(Get-DnsSuggestions))
    foreach ($t in @($txtDns1, $txtDns2)) {
        $t.AutoCompleteMode = 'SuggestAppend'
        $t.AutoCompleteSource = 'CustomSource'
        $t.AutoCompleteCustomSource = $col
    }
}
function Add-DnsHistory([string]$s) {
    $s = "$s".Trim()
    if (-not $s -or -not (Test-Ipv4 $s)) { return }
    if ((Get-DnsSuggestions) -contains $s) { return }
    Add-Content -Path $dnsHistoryFile -Value $s -Encoding UTF8
    Set-DnsSuggestions
}
Set-DnsSuggestions

# ---- 下部：配置方案 ----
$gbProfile         = New-Object Windows.Forms.GroupBox
$gbProfile.Text    = '配置方案（保存后可一键切换）'
$gbProfile.Location = New-Object Drawing.Point(12, 414)
$gbProfile.Size    = New-Object Drawing.Size(724, 132)
$gbProfile.Anchor  = 'Top,Left,Right'

$lbProfiles              = New-Object Windows.Forms.ListBox
$lbProfiles.Location     = New-Object Drawing.Point(16, 24)
$lbProfiles.Size         = New-Object Drawing.Size(270, 96)
$lbProfiles.FormattingEnabled = $true

$lblPName      = New-Object Windows.Forms.Label
$lblPName.Text = '方案名称：'
$lblPName.Location = New-Object Drawing.Point(306, 24)
$lblPName.AutoSize = $true

$txtProfileName          = New-Object Windows.Forms.TextBox
$txtProfileName.Location = New-Object Drawing.Point(306, 50)
$txtProfileName.AutoCompleteMode = 'SuggestAppend'
$txtProfileName.AutoCompleteSource = 'CustomSource'
$txtProfileName.Size     = New-Object Drawing.Size(150, 23)

$btnPSave          = New-Object Windows.Forms.Button
$btnPSave.Text     = '保存方案'
$btnPSave.Location = New-Object Drawing.Point(472, 47)
$btnPSave.Size     = New-Object Drawing.Size(100, 28)

$btnPApply         = New-Object Windows.Forms.Button
$btnPApply.Text    = '应用所选方案'
$btnPApply.Location = New-Object Drawing.Point(590, 24)
$btnPApply.Size    = New-Object Drawing.Size(120, 28)

$btnPDelete         = New-Object Windows.Forms.Button
$btnPDelete.Text    = '删除所选方案'
$btnPDelete.Location = New-Object Drawing.Point(590, 58)
$btnPDelete.Size    = New-Object Drawing.Size(120, 28)

$gbProfile.Controls.AddRange(@($lbProfiles, $lblPName, $txtProfileName, $btnPSave, $btnPApply, $btnPDelete))

# ---- 底部按钮 ----
$panel               = New-Object Windows.Forms.FlowLayoutPanel
$panel.Dock          = 'Bottom'
$panel.Height        = 52
$panel.FlowDirection = 'LeftToRight'
$panel.Padding       = New-Object Windows.Forms.Padding(10, 12, 0, 0)

function New-Btn([string]$text, [int]$w) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Size = New-Object Drawing.Size($w, 30)
    $panel.Controls.Add($b)
    return $b
}
$btnRefresh = New-Btn '刷新' 80
$btnV6Off   = New-Btn '禁用 IPv6' 110
$btnV6On    = New-Btn '启用 IPv6' 110
$btnNicOff   = New-Btn '禁用网卡' 100
$btnNicOn    = New-Btn '启用网卡' 100
$btnFlushDns = New-Btn '清 DNS 缓存' 110
$btnRenewIp  = New-Btn '重新获取 IP' 110

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabConfig = New-Object Windows.Forms.TabPage('IP 配置')
$tabProfile = New-Object Windows.Forms.TabPage('配置方案')
$tabScan = New-Object Windows.Forms.TabPage('局域网扫描')
foreach ($page in @($tabConfig, $tabProfile, $tabScan)) {
    $page.Padding = New-Object Windows.Forms.Padding(10)
    $page.BackColor = [Drawing.Color]::White
    $tabs.TabPages.Add($page)
}
$gbCfg.Dock = 'Fill'
$gbProfile.Dock = 'Fill'
$tlp.Anchor = 'Top,Left,Right'
$tabConfig.Controls.Add($gbCfg)
$tabProfile.Controls.Add($gbProfile)

$macCaption = New-Object Windows.Forms.Label
$macCaption.Text = '当前 MAC：'
$macCaption.AutoSize = $true
$macCaption.Anchor = 'Left'
$hint.Text = '选择网卡后，可编辑配置或扫描其直连网段。'
$hint.Anchor = 'Left'
$header = New-Object Windows.Forms.TableLayoutPanel
$header.Dock = 'Top'
$header.Height = 34
$header.AutoSize = $true                     # 行高随内容/DPI 自适应，避免副屏 DPI 不同导致文本溢出形成台阶
$header.AutoSizeMode = 'GrowAndShrink'
$header.BackColor = [Drawing.Color]::White   # 与下方列表统一白底，消除右上角色差台阶
$header.ColumnCount = 3
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
$lblMacBox.Anchor = 'Left'
$header.Controls.Add($hint, 0, 0)
$header.Controls.Add($macCaption, 1, 0)
$header.Controls.Add($lblMacBox, 2, 0)
$list.Dock = 'Top'
$list.Height = 150
$list.MultiSelect = $false
$list.HideSelection = $false

$chkMac.Location = New-Object Drawing.Point(440, 176)
$panel.Padding = New-Object Windows.Forms.Padding(0, 10, 0, 0)
$panel.Height = 48
$panel.WrapContents = $false
$panel.Controls.SetChildIndex($btnRenewIp, 1)
$panel.Controls.SetChildIndex($btnFlushDns, 2)
foreach ($button in @($btnApply, $btnApplyMac, $btnRead, $btnGenMac, $btnPSave, $btnPApply, $btnPDelete) + @($panel.Controls)) {
    $button.FlatStyle = 'System'
}
$form.Controls.Add($tabs)
$form.Controls.Add($panel)
$form.Controls.Add($list)
$form.Controls.Add($header)

# ---------------- 局域网扫描 ----------------
$scanBar = New-Object Windows.Forms.FlowLayoutPanel
$scanBar.Dock = 'Top'
$scanBar.AutoSize = $true
$scanBar.WrapContents = $false
$btnScan = New-Object Windows.Forms.Button
$btnScan.Text = '开始扫描'
$btnScan.AutoSize = $true
$btnScanStop = New-Object Windows.Forms.Button
$btnScanStop.Text = '停止'
$btnScanStop.AutoSize = $true
$btnScanStop.Enabled = $false
$scanSearch = New-Object Windows.Forms.TextBox
$scanSearch.Width = 240
$scanSearch.AccessibleName = '按 IP 或 MAC 筛选'
[void][Native.Win32]::SendMessage($scanSearch.Handle, 0x1501, [IntPtr]::Zero, '按 IP 或 MAC 筛选')
$scanBar.Controls.AddRange(@($btnScan, $btnScanStop, $scanSearch))
$scanRange = New-Object Windows.Forms.Label
$scanRange.Dock = 'Top'
$scanRange.AutoEllipsis = $true
$scanRange.Height = 24
$scanStatus = New-Object Windows.Forms.Label
$scanStatus.Dock = 'Bottom'
$scanStatus.Height = 30
$scanStatus.Text = '未响应不代表空闲。'
$scanList = New-Object Windows.Forms.ListView
$scanList.Dock = 'Fill'
$scanList.View = 'Details'
$scanList.FullRowSelect = $true
$scanList.GridLines = $true
[void]$scanList.Columns.Add('IPv4 地址', 150)
[void]$scanList.Columns.Add('MAC 地址', 180)
[void]$scanList.Columns.Add('状态', 155)
[void]$scanList.Columns.Add('最近确认时间', 170)
$tabScan.Controls.AddRange(@($scanList, $scanStatus, $scanRange, $scanBar))

Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading;

namespace Native {
    public sealed class LanSweep {
        [StructLayout(LayoutKind.Explicit, Size = 88)]
        private struct Neighbor {
            [FieldOffset(0)] public ushort Family;
            [FieldOffset(4)] public uint Address;
            [FieldOffset(28)] public uint InterfaceIndex;
            [FieldOffset(40)] public byte Mac0;
            [FieldOffset(41)] public byte Mac1;
            [FieldOffset(42)] public byte Mac2;
            [FieldOffset(43)] public byte Mac3;
            [FieldOffset(44)] public byte Mac4;
            [FieldOffset(45)] public byte Mac5;
            [FieldOffset(72)] public uint MacLength;
        }
        [DllImport("iphlpapi.dll")]
        private static extern uint ResolveIpNetEntry2(ref Neighbor row, IntPtr sourceAddress);

        public sealed class Hit {
            public string IP, Mac, Time;
        }
        public static string Text(long number) {
            return new IPAddress(new byte[] {(byte)(number >> 24), (byte)(number >> 16), (byte)(number >> 8), (byte)number}).ToString();
        }
        public static long Number(string text) {
            string[] parts = text.Split('.');
            if (parts.Length != 4) throw new ArgumentException("IPv4 required");
            long number = 0;
            foreach (string part in parts) number = (number << 8) | Byte.Parse(part);
            return number;
        }
        public static string Probe(uint index, string ip) {
            Neighbor row = new Neighbor { Family = 2, InterfaceIndex = index, Address = BitConverter.ToUInt32(IPAddress.Parse(ip).GetAddressBytes(), 0) };
            if (ResolveIpNetEntry2(ref row, IntPtr.Zero) != 0 || row.MacLength != 6) return null;
            byte[] mac = { row.Mac0, row.Mac1, row.Mac2, row.Mac3, row.Mac4, row.Mac5 };
            if ((mac[0] & 1) != 0 || Array.TrueForAll(mac, b => b == 0)) return null;
            return BitConverter.ToString(mac).Replace('-', ':');
        }

        public readonly ConcurrentQueue<Hit> Results = new ConcurrentQueue<Hit>();
        private readonly uint index;
        private readonly long[] first, last, local;
        private readonly object gate = new object();
        private int range;
        private long next, checkedCount;
        private int workers = 8;
        private volatile bool stopped;
        private volatile string failure;
        private void AddressChanged(object sender, EventArgs args) {
            failure = "IPv4 网络配置已变化，请重新扫描。";
            Stop();
        }
        public long Checked { get { return Interlocked.Read(ref checkedCount); } }
        public bool Finished { get { return Volatile.Read(ref workers) == 0; } }
        public string Failure { get { return failure; } }
        public void Stop() {
            stopped = true;
            NetworkChange.NetworkAddressChanged -= AddressChanged;
        }

        public LanSweep(uint index, long[] first, long[] last, long[] local) {
            this.index = index; this.first = first; this.last = last; this.local = local;
            next = first[0];
            NetworkChange.NetworkAddressChanged += AddressChanged;
            for (int i = 0; i < 8; i++) {
                if (!ThreadPool.QueueUserWorkItem(Work)) Interlocked.Decrement(ref workers);
            }
        }
        private void Work(object unused) {
            try {
                while (!stopped) {
                    long target;
                    lock (gate) {
                        if (stopped || range == first.Length) return;
                        target = next++;
                        if (target == last[range] && ++range < first.Length) next = first[range];
                    }
                    if (Array.IndexOf(local, target) < 0) {
                        string ip = Text(target);
                        string mac = Probe(index, ip);
                        if (mac != null && !stopped) Results.Enqueue(new Hit { IP = ip, Mac = mac, Time = DateTime.Now.ToString("HH:mm:ss") });
                    }
                    Interlocked.Increment(ref checkedCount);
                }
            } catch (Exception ex) {
                failure = ex.Message;
                stopped = true;
            } finally {
                Interlocked.Decrement(ref workers);
            }
        }
    }
}
'@

# ---------------- 核心逻辑 ----------------
function Get-SelectedAdapter {
    if ($list.SelectedItems.Count -eq 0) { return $null }
    return $list.SelectedItems[0].Tag
}

function Get-LanRanges([uint32]$index) {
    $addresses = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.AddressState -in @('Preferred', 'Deprecated') })
    if (-not $addresses.Count) { return }
    $routes = @(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.NextHop -eq '0.0.0.0' })
    $ranges = foreach ($address in $addresses) {
        $prefix = [int]$address.PrefixLength
        if ($prefix -lt 1 -or $prefix -gt 31) { continue }
        $size = 1L -shl (32 - $prefix)
        $number = [Native.LanSweep]::Number($address.IPAddress)
        $network = $number - ($number % $size)
        $cidr = ([Native.LanSweep]::Text($network)) + '/' + $prefix
        if ($cidr -notin $routes.DestinationPrefix) { continue }
        $edge = if ($prefix -eq 31) { 0 } else { 1 }
        [pscustomobject]@{ First = $network + $edge; Last = $network + $size - 1 - $edge; Cidr = $cidr }
    }
    $end = -1L
    foreach ($range in @($ranges | Sort-Object First, @{Expression='Last'; Descending=$true})) {
        if ($range.Last -le $end) { continue }
        if ($range.First -le $end) { $range.First = $end + 1 }
        $end = $range.Last
        $range
    }
}

$script:scanJob = $null
$script:scanTotal = 0L
$script:scanRows = @{}
$script:scanItems = @{}
$script:scanFound = 0
$scanTimer = New-Object Windows.Forms.Timer
$scanTimer.Interval = 180

function Update-LanRow($row) {
    $query = $scanSearch.Text.Trim()
    $macQuery = $query -replace '[:\-]', ''
    $matches = -not $query -or $row.IP.Contains($query) -or
        ($macQuery -and ($row.Mac -replace ':', '').IndexOf($macQuery, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    $item = $script:scanItems[$row.IP]
    if (-not $matches) {
        if ($item) { $scanList.Items.Remove($item); $script:scanItems.Remove($row.IP) }
        return
    }
    if (-not $item) {
        $item = New-Object Windows.Forms.ListViewItem($row.IP)
        [void]$item.SubItems.Add('')
        [void]$item.SubItems.Add('')
        [void]$item.SubItems.Add('')
        [void]$scanList.Items.Add($item)
        $script:scanItems[$row.IP] = $item
    }
    $item.SubItems[1].Text = $row.Mac
    $item.SubItems[2].Text = $row.State
    $item.SubItems[3].Text = $row.Time
}

function Stop-LanScan([bool]$clear) {
    if ($script:scanJob) {
        $script:scanJob.Stop()
        $script:scanJob = $null
    }
    $scanTimer.Stop()
    $btnScan.Enabled = $true
    $btnScanStop.Enabled = $false
    if ($clear) {
        $script:scanRows.Clear()
        $script:scanItems.Clear()
        $scanList.Items.Clear()
        $scanRange.Text = ''
        $scanStatus.Text = '未响应不代表空闲。'
    }
}

function Start-LanScan {
    Stop-LanScan $true
    $adapter = Get-SelectedAdapter
    if (-not $adapter -or $adapter.Status -ne 'Up') {
        $scanStatus.Text = '请选择一块已连接的网卡。'
        return
    }
    try {
        $index = $adapter.ifIndex
        $ranges = @(Get-LanRanges $index)
        if (-not $ranges.Count) { $scanStatus.Text = '所选网卡没有可扫描的直连 IPv4 网段。'; return }
        $local = [long[]]@(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop |
            ForEach-Object { [Native.LanSweep]::Number($_.IPAddress) })
        $scanRange.Text = '{0}  |  {1}' -f $adapter.Name, ($ranges.Cidr -join ', ')
        $script:scanTotal = 0L
        $script:scanFound = 0
        foreach ($range in $ranges) { $script:scanTotal += $range.Last - $range.First + 1 }
        $scanList.BeginUpdate()
        try {
            foreach ($entry in @(Get-NetNeighbor -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                $mac = Format-MacColon $entry.LinkLayerAddress
                if (-not $mac -or $mac -eq '00:00:00:00:00:00' -or ([Convert]::ToByte($mac.Substring(0, 2), 16) -band 1)) { continue }
                $n = [Native.LanSweep]::Number($entry.IPAddress)
                if ($local -contains $n) { continue }
                foreach ($range in $ranges) {
                    if ($n -lt $range.First -or $n -gt $range.Last) { continue }
                    $row = [pscustomobject]@{ IP = $entry.IPAddress; Mac = $mac; State = '邻居缓存（未确认）'; Time = '—' }
                    $script:scanRows[$row.IP] = $row
                    Update-LanRow $row
                    break
                }
            }
        } finally { $scanList.EndUpdate() }
        $script:scanJob = [Native.LanSweep]::new($index, [long[]]$ranges.First, [long[]]$ranges.Last, $local)
        $btnScan.Enabled = $false
        $btnScanStop.Enabled = $true
        $scanStatus.Text = '正在扫描；未响应不代表空闲。'
        $scanTimer.Start()
    } catch {
        Stop-LanScan $false
        $scanStatus.Text = '无法开始扫描：' + $_.Exception.Message
    }
}

$scanTimer.Add_Tick({
    $job = $script:scanJob
    if (-not $job) { return }
    $scanList.BeginUpdate()
    try {
        $hit = $null
        for ($i = 0; $i -lt 200 -and $job.Results.TryDequeue([ref]$hit); $i++) {
            $row = [pscustomobject]@{ IP = $hit.IP; Mac = $hit.Mac; State = '本轮确认占用'; Time = $hit.Time }
            if (-not $script:scanRows.ContainsKey($row.IP) -or $script:scanRows[$row.IP].State -ne $row.State) { $script:scanFound++ }
            $script:scanRows[$row.IP] = $row
            Update-LanRow $row
        }
    } finally { $scanList.EndUpdate() }
    $progress = '{0:N0}/{1:N0} 个地址，确认 {2:N0} 个占用；未响应不代表空闲。' -f $job.Checked, $script:scanTotal, $script:scanFound
    if ($job.Finished -and $job.Results.IsEmpty) {
        Stop-LanScan $false
        $scanStatus.Text = if ($job.Failure) { '扫描中止：' + $job.Failure } elseif ($job.Checked -lt $script:scanTotal) { '未完整扫描：' + $progress } else { '扫描完成：' + $progress }
    } else { $scanStatus.Text = '扫描中：' + $progress }
})
$scanSearch.Add_TextChanged({
    $scanList.BeginUpdate()
    try {
        $scanList.Items.Clear()
        $script:scanItems.Clear()
        foreach ($row in $script:scanRows.Values) { Update-LanRow $row }
    } finally { $scanList.EndUpdate() }
})
$btnScan.Add_Click({ Start-LanScan })
$btnScanStop.Add_Click({
    $checkedCount = $script:scanJob.Checked
    Stop-LanScan $false
    $scanStatus.Text = '已停止（{0:N0}/{1:N0}）；仅显示已收到的结果，未响应不代表空闲。' -f $checkedCount, $script:scanTotal
})
$tabs.Add_SelectedIndexChanged({
    if ($tabs.SelectedTab -eq $tabScan) { Start-LanScan } else { Stop-LanScan $true }
})
$form.Add_FormClosed({ Stop-LanScan $false; $scanTimer.Dispose() })

function Get-ActiveAdapter($adapters, $routes, $ipMap) {
    $connected = @($adapters | Where-Object { $_.Status -eq 'Up' })
    $byIndex = @{}
    foreach ($adapter in $connected) { $byIndex[[int]$adapter.ifIndex] = $adapter }
    foreach ($prefix in @('0.0.0.0/0', '::/0')) {
        $best = $routes | Where-Object {
            $_.DestinationPrefix -eq $prefix -and $_.State -eq 'Alive' -and $byIndex.ContainsKey([int]$_.InterfaceIndex)
        } | Sort-Object @{Expression={ [long]$_.RouteMetric + [long]$_.InterfaceMetric }}, InterfaceIndex | Select-Object -First 1
        if ($best) { return $byIndex[[int]$best.InterfaceIndex] }
    }
    # 无默认路由时，只在候选唯一时自动选择，避免把虚拟网卡或任意一块网卡当作在用网卡。
    $withAddress = @($connected | Where-Object { $ipMap.ContainsKey($_.ifIndex) })
    if ($withAddress.Count -eq 1) { return $withAddress[0] }
    if ($connected.Count -eq 1) { return $connected[0] }
}

function Refresh-AdapterList([switch]$SelectActive) {
    $keepName = $null
    if (-not $SelectActive -and $list.SelectedItems.Count -gt 0) { $keepName = $list.SelectedItems[0].Tag.Name }

    $form.Cursor = 'WaitCursor'
    $list.BeginUpdate()
    try {
        # ---- 一次性批量读取全部数据，避免逐网卡查询导致刷新缓慢 ----
        $bindings = @{}
        Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue |
            ForEach-Object { $bindings[$_.Name] = $_.Enabled }

        # MAC 覆盖（已修改标记），一次查询全部网卡
        $ovMap = @{}
        Get-NetAdapterAdvancedProperty -RegistryKeyword 'NetworkAddress' -ErrorAction SilentlyContinue |
            ForEach-Object { $ovMap[$_.Name] = $_.RegistryValue }

        $macCacheDirty = $false

        $ipMap = @{}
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
            ForEach-Object {
                if (-not $ipMap.ContainsKey($_.InterfaceIndex)) {
                    $ipMap[$_.InterfaceIndex] = New-Object System.Collections.Generic.List[string]
                }
                $ipMap[$_.InterfaceIndex].Add($_.IPAddress)
            }

        $adapters = @(Get-NetAdapter -ErrorAction Stop | Sort-Object Name)
        $routes = @(foreach ($prefix in @('0.0.0.0/0', '::/0')) {
            Get-NetRoute -PolicyStore ActiveStore -DestinationPrefix $prefix -ErrorAction SilentlyContinue
        })
        $active = Get-ActiveAdapter $adapters $routes $ipMap
        $activeItem = $null; $keepItem = $null
        $items = foreach ($a in $adapters) {
            $ipText = '-'
            if ($ipMap.ContainsKey($a.ifIndex)) { $ipText = ($ipMap[$a.ifIndex] -join ', ') }

            $enabled = $bindings[$a.Name]
            $v6Text = if ($null -eq $enabled) { '未知' } elseif ($enabled) { '启用' } else { '已禁用' }

            # 当前 MAC / 原始 MAC
            $curMac = Format-MacText $a.MacAddress
            $ov = $ovMap[$a.Name]
            $origMac = if ($a.PnPDeviceID) { $script:macCache[$a.PnPDeviceID] }
            if ($a.PnPDeviceID -and -not $origMac -and -not $ov -and $a.MacAddress) {
                # 从未被修改 → 当前 MAC 就是原始 MAC，记入缓存
                $origMac = (Format-MacText $a.MacAddress)
                $script:macCache[$a.PnPDeviceID] = $origMac
                $macCacheDirty = $true
            }
            if (-not $origMac) { $origMac = '未知(已修改)' }

            $item = New-Object Windows.Forms.ListViewItem($a.Name)
            [void]$item.SubItems.Add($a.InterfaceDescription)
            [void]$item.SubItems.Add((Get-StatusText "$($a.Status)"))
            [void]$item.SubItems.Add($ipText)
            [void]$item.SubItems.Add($v6Text)
            [void]$item.SubItems.Add($curMac)
            [void]$item.SubItems.Add($origMac)
            $item.Tag = $a
            $item

            if ($active -and $a.ifIndex -eq $active.ifIndex) { $activeItem = $item }
            if ($keepName -eq $a.Name) { $keepItem = $item }
        }

        $list.Items.Clear()
        if ($items) { $list.Items.AddRange([Windows.Forms.ListViewItem[]]@($items)) }
        $sel = if ($keepItem) { $keepItem } else { $activeItem }
        if ($sel) {
            $sel.Selected = $true
            $sel.Focused = $true
            $sel.EnsureVisible()
            if ($sel.Selected) {
                if ($SelectActive) {
                    $tabs.SelectedTab = $tabConfig
                    $hint.Text = '已定位当前在用网卡：' + $sel.Text
                } else { $hint.Text = '选择网卡后，可编辑配置或扫描其直连网段。' }
            }
            else { $hint.Text = '未能自动选中网卡，请在列表中手动选择。' }
        } else {
            $hint.Text = '无法确定当前在用网卡，请在列表中手动选择。'
        }
        if ($macCacheDirty) { Save-MacCache }
    }
    catch {
        $hint.Text = '网卡刷新或自动定位失败，请手动刷新后选择。'
        Show-Msg ("获取网卡信息失败：{0}" -f $_.Exception.Message) '错误' 'Error'
    }
    finally {
        $list.EndUpdate()
        $form.Cursor = 'Default'
    }
    Refresh-ProfileList
}

function Load-AdapterConfig {
    $a = Get-SelectedAdapter
    if ($null -eq $a) { return }
    # 右上角显示框：当前选中网卡的 MAC（XX:XX:XX:XX:XX:XX）
    $lblMacBox.Text = Format-MacColon $a.MacAddress
    try {
        $if   = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop
        $dhcp = ($if.Dhcp -eq 'Enabled')

        $ipObj = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
        $gwObj = Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $dns = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)

        $rbDhcp.Checked = $dhcp
        $rbStatic.Checked = -not $dhcp
        if ($ipObj) {
            $txtIp.Text   = $ipObj.IPAddress
            $txtMask.Text = ConvertTo-SubnetMask $ipObj.PrefixLength
        }
        else { $txtIp.Text = ''; $txtMask.Text = '' }
        $txtGw.Text   = if ($gwObj) { $gwObj.NextHop } else { '' }
        $txtDns1.Text = if ($dns.Count -gt 0) { $dns[0] } else { '' }
        $txtDns2.Text = if ($dns.Count -gt 1) { $dns[1] } else { '' }
    }
    catch {
        Show-Msg ("读取网卡配置失败：{0}" -f $_.Exception.Message) '错误' 'Error'
    }
}

# WMI 返回码转成可读文字
function Get-WmiResultText([int]$code) {
    switch ($code) {
        0        { '成功' }
        1        { '成功（需重启计算机生效）' }
        64       { '此平台不支持该方法' }
        65       { '未知错误' }
        66       { '子网掩码无效' }
        70       { 'IP 地址无效' }
        71       { '网关 IP 无效' }
        78       { 'IP 或网关不在同一子网内' }
        84       { '该 IP 未能启用' }
        91       { '拒绝访问（权限不足）' }
        100      { 'DHCP 服务不可用' }
        default  { "错误代码 $code" }
    }
}

function Get-AdapterWmiConfig([int]$ifIndex) {
    $nic = Get-CimInstance -ClassName Win32_NetworkAdapter -Filter "InterfaceIndex=$ifIndex" -ErrorAction Stop
    if (-not $nic) { throw '未找到对应的网卡（WMI）。' }
    $cfg = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "Index=$($nic.DeviceID)" -ErrorAction Stop
    if (-not $cfg) { throw '未找到对应的网络配置（WMI）。' }
    return $cfg
}

# 直接由当前提权进程写 DNS 注册表（NameServer），不经过 WMI 宿主 WmiPrvSE.exe，
# 避免 360"注册表防护"把 WMI 改 DNS 误判为恶意 DNS 劫持。
function Set-AdapterDnsDirect([string]$ifGuid, [string[]]$servers) {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$ifGuid"
    if (-not (Test-Path $regPath)) { throw "未找到网卡注册表接口项：$ifGuid" }

    $clean = @($servers | Where-Object { $_ })
    if ($clean.Count -gt 0) {
        $value = ($clean -join ',')
        Set-ItemProperty -Path $regPath -Name 'NameServer' -Value $value -Type String -ErrorAction Stop
        # 回读验证
        $readBack = (Get-ItemProperty -Path $regPath -Name 'NameServer' -ErrorAction Stop).NameServer
        if ($readBack -ne $value) { throw "DNS 注册表写入回读不一致：期望 $value，实际 $readBack" }
    }
    else {
        # 删除手动 NameServer；DHCP 网卡自动回退到 DhcpNameServer，静态网卡则不指定 DNS
        Remove-ItemProperty -Path $regPath -Name 'NameServer' -ErrorAction SilentlyContinue
    }

    # 进程内刷新 DNS 缓存，使新 DNS 立即生效（不启动 ipconfig.exe）
    if (Get-Command Clear-DnsClientCache -ErrorAction SilentlyContinue) {
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    }
}

# 与原版 IP地址修改器 相同的 WMI 方式设置 IP，避免先删后建引起的"对象已存在"等错误
function Apply-AdapterConfig([string]$name, [bool]$useDhcp, [string]$ip, [string]$mask,
    [string]$gw, [string]$d1, [string]$d2) {

    $a = Get-NetAdapter -Name $name -ErrorAction Stop

    if (-not $useDhcp) {
        if (-not (Test-Ipv4 $ip))   { throw 'IP 地址格式不正确。' }
        $prefix = ConvertTo-PrefixLength $mask
        if ($prefix -lt 0)          { throw '子网掩码格式不正确。' }
        if ($gw -and -not (Test-Ipv4 $gw)) { throw '默认网关格式不正确。' }
    }
    foreach ($d in @($d1, $d2)) {
        if ($d -and -not (Test-Ipv4 $d)) { throw 'DNS 地址格式不正确。' }
    }

    $cfg = Get-AdapterWmiConfig $a.ifIndex

    if ($useDhcp) {
        $r = $cfg | Invoke-CimMethod -MethodName EnableDHCP -ErrorAction Stop
        if ($r.ReturnValue -ne 0) { throw ('启用 DHCP 失败：' + (Get-WmiResultText $r.ReturnValue)) }
        # 清空手动 DNS（直接删 NameServer，自动回退到 DHCP 下发的 DhcpNameServer）
        Set-AdapterDnsDirect -ifGuid $a.InterfaceGuid -servers @()
    }
    else {
        $target = [Native.LanSweep]::Text([Native.LanSweep]::Number($ip))
        $known = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -eq $target })
        $other = $known | Where-Object { $_.InterfaceIndex -ne $a.ifIndex } | Select-Object -First 1
        $own = $known | Where-Object { $_.InterfaceIndex -eq $a.ifIndex -and $_.AddressState -in @('Preferred', 'Deprecated') } | Select-Object -First 1
        $warning = $null
        if ($other) {
            $warning = '本机网卡「{0}」已配置 {1}。' -f $other.InterfaceAlias, $target
        } elseif (-not $own) {
            $mac = $null
            try {
                if ($a.Status -eq 'Up') {
                    $number = [Native.LanSweep]::Number($target)
                    foreach ($range in @(Get-LanRanges $a.ifIndex)) {
                        if ($number -ge $range.First -and $number -le $range.Last) {
                            $mac = [Native.LanSweep]::Probe($a.ifIndex, $target)
                            break
                        }
                    }
                }
            } catch { $mac = $null }
            $warning = if ($mac) { '检测到 {0} 已有响应，MAC 为 {1}。' -f $target, $mac }
                       else { '无法确认 {0} 是否空闲。局域网设备可能休眠、被隔离或不在当前直连网段。' -f $target }
        }
        if ($warning) {
            $message = $warning + "`r`n`r`n仍要在网卡「$($a.Name)」上应用吗？"
            $choice = [Windows.Forms.MessageBox]::Show($form, $message, '静态 IP 占用检查', 'YesNo', 'Warning', 'Button2')
            if ($choice -ne 'Yes') { return $false }
        }
        $r = $cfg | Invoke-CimMethod -MethodName EnableStatic `
            -Arguments @{ IPAddress = [string[]]@($target); SubnetMask = [string[]]@($mask) } -ErrorAction Stop
        if ($r.ReturnValue -ne 0) { throw ('设置静态 IP 失败：' + (Get-WmiResultText $r.ReturnValue)) }

        if ($gw) {
            # 注意：该方法的实际参数名是 DefaultIPGateway（微软文档误写为 GatewayIPAddress）
            $r = $cfg | Invoke-CimMethod -MethodName SetGateways `
                -Arguments @{ DefaultIPGateway = [string[]]@($gw); GatewayCostMetric = [uint16[]]@(1) } -ErrorAction Stop
            if ($r.ReturnValue -ne 0) { throw ('设置网关失败：' + (Get-WmiResultText $r.ReturnValue)) }
        }

        # DNS 直接写注册表 NameServer，不经 WMI 宿主，避免 360 注册表防护误报
        Set-AdapterDnsDirect -ifGuid $a.InterfaceGuid -servers @($d1, $d2)
        $written = Get-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $target -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($written.AddressState -eq 'Duplicate') { throw "Windows 检测到 $target 地址重复；请重新配置该网卡。" }
        if ($written.AddressState -ne 'Preferred') {
            Show-Msg "配置已写入，但 Windows 尚未确认 $target 可用。请刷新后核对地址状态。" '地址尚未确认' 'Warning'
        }
    }
    return $true
}

function Apply-MacChange([string]$name, [string]$mac) {
    $hex = ($mac -replace '[:\-\.]', '').ToUpper()
    if ($hex) {
        if ($hex -notmatch '^[0-9A-Fa-f]{12}$') { throw 'MAC 地址格式不正确（12 位十六进制）。' }
        # 本地管理位（bit 1）校验：第二位必须是 2/6/A/E，否则多数驱动会静默拒绝
        $secondChar = $hex[1]
        if ($secondChar -notin @('2','6','A','E')) {
            $confirm = [Windows.Forms.MessageBox]::Show($form,
                ("MAC 第二位为 '{0}'，未设置本地管理位，多数网卡驱动会拒绝这种自定义地址。`n" +
                 "是否仍要尝试写入？（建议改用如 6E:24:08:5C:1C:09 的地址）" -f $secondChar),
                '兼容性警告', 'YesNo', 'Warning')
            if ($confirm -ne 'Yes') { throw '已取消修改。' }
        }
    }

    $adapter = Get-NetAdapter -Name $name -ErrorAction Stop
    $ifGuid  = $adapter.InterfaceGuid
    $regBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}'

    # ---- 方案 A：注册表直写（匹配 DriverDesc 非空的真实驱动子键） ----
    $regSuccess = $false
    $regMatches = @()
    Get-ChildItem $regBase -ErrorAction SilentlyContinue | ForEach-Object {
        $subKey   = $_.PSPath
        $netCfgId = (Get-ItemProperty -Path $subKey -Name 'NetCfgInstanceId' -ErrorAction SilentlyContinue).NetCfgInstanceId
        if ($netCfgId -eq $ifGuid) {
            $driverDesc = (Get-ItemProperty -Path $subKey -Name 'DriverDesc' -ErrorAction SilentlyContinue).DriverDesc
            $regMatches += @{ SubKey = $subKey; DriverDesc = $driverDesc }
        }
    }

    if ($regMatches.Count -gt 0) {
        # 优先选 DriverDesc 非空的（这才是真正生效的驱动子键）
        $realMatch = $regMatches | Where-Object { $_.DriverDesc } | Select-Object -First 1
        if (-not $realMatch) { $realMatch = $regMatches[0] }

        if ($hex) {
            Set-ItemProperty -Path $realMatch.SubKey -Name 'NetworkAddress' -Value $hex -Type String -ErrorAction Stop
            $readBack = (Get-ItemProperty -Path $realMatch.SubKey -Name 'NetworkAddress' -ErrorAction SilentlyContinue).NetworkAddress
            if ($readBack -eq $hex) {
                $regSuccess = $true
            } else {
                $form.Text = 'MAC 修改中：注册表回读不匹配，尝试方案 B...'
                $form.Refresh()
            }
        } else {
            Remove-ItemProperty -Path $realMatch.SubKey -Name 'NetworkAddress' -ErrorAction SilentlyContinue
            $regSuccess = $true
        }
    }

    # ---- 方案 B：Set-NetAdapterAdvancedProperty（fallback） ----
    if (-not $regSuccess -and $hex) {
        $form.Text = 'MAC 修改中：注册表方案未生效，尝试 Set-NetAdapterAdvancedProperty...'
        $form.Refresh()
        try {
            Set-NetAdapterAdvancedProperty -Name $name -RegistryKeyword 'NetworkAddress' -RegistryValue $hex -ErrorAction Stop
            $regSuccess = $true
        } catch {
            throw "MAC 修改失败：注册表方案未匹配，Set-NetAdapterAdvancedProperty 也失败：$($_.Exception.Message)"
        }
    }

    if (-not $regSuccess -and -not $hex) {
        # 恢复 MAC 时如果没有注册表项就直接跳过
    }

    # ---- 重启网卡使 MAC 生效 ----
    $oldTitle = $form.Text
    $form.Text = 'MAC 修改中：正在禁用网卡...'
    $form.Refresh()
    Disable-NetAdapter -Name $name -Confirm:$false -ErrorAction Stop
    Start-Sleep -Milliseconds 1200
    $form.Text = 'MAC 修改中：正在启用网卡...'
    $form.Refresh()
    Enable-NetAdapter  -Name $name -Confirm:$false -ErrorAction Stop
    Start-Sleep -Milliseconds 2500
    $form.Text = $oldTitle
}

function Get-FormConfig {
    return @{
        Dhcp  = $rbDhcp.Checked
        Ip    = $txtIp.Text.Trim()
        Mask  = $txtMask.Text.Trim()
        Gw    = $txtGw.Text.Trim()
        Dns1  = $txtDns1.Text.Trim()
        Dns2  = $txtDns2.Text.Trim()
        Mac   = $txtMac.Text.Trim()
        SetMac = $chkMac.Checked
    }
}

function Refresh-ProfileList {
    $lbProfiles.Items.Clear()
    $names = @(Load-Profiles | ForEach-Object { $_.Name })
    foreach ($n in $names) { [void]$lbProfiles.Items.Add($n) }
    # 方案名称输入建议随方案列表同步更新
    $col = New-Object Windows.Forms.AutoCompleteStringCollection
    $col.AddRange([string[]]$names)
    $txtProfileName.AutoCompleteCustomSource = $col
}

# ---------------- 事件 ----------------
$list.Add_SelectedIndexChanged({
    if ($list.SelectedItems.Count -gt 0) { Load-AdapterConfig }
    else {
        $lblMacBox.Text = '-'
        foreach ($field in @($txtIp, $txtMask, $txtGw, $txtDns1, $txtDns2)) { $field.Clear() }
    }
    if ($tabs.SelectedTab -eq $tabScan) { Start-LanScan }
})

$btnRefresh.Add_Click({ Refresh-AdapterList })

$rbDhcp.Add_CheckedChanged({ if ($rbDhcp.Checked) { foreach ($c in @($txtIp, $txtMask, $txtGw, $txtDns1, $txtDns2)) { $c.Enabled = $false; $errProvider.SetError($c, '') } } })
$rbStatic.Add_CheckedChanged({ if ($rbStatic.Checked) { foreach ($c in @($txtIp, $txtMask, $txtGw, $txtDns1, $txtDns2)) { $c.Enabled = $true; Update-FieldValidation $c } } })

$btnApply.Add_Click({
    $a = Get-SelectedAdapter
    if ($null -eq $a) { Show-Msg '请先在上方列表选择一块网卡。'; return }

    # 应用前统一验证：有错误时聚焦第一个出错输入框并提示
    $bad = $null
    foreach ($f in @($txtIp, $txtMask, $txtGw, $txtDns1, $txtDns2, $txtMac)) {
        if ($f.Enabled -and -not (Get-FieldValid $f)) { $bad = $f; break }
    }
    if ($bad) {
        Update-FieldValidation $bad
        [void]$bad.Focus()
        Show-Msg ("输入有误：{0}" -f $fieldMsgs["$($bad.Tag)"]) '错误' 'Error'
        return
    }

    $cfg = Get-FormConfig
    $actionText = if ($cfg.Dhcp) { '将网卡【{0}】切换为 DHCP 自动获取' -f $a.Name } else { '将网卡【{0}】切换为静态 IP {1}' -f $a.Name, $cfg.Ip }
    $confirm = [Windows.Forms.MessageBox]::Show($form, ($actionText + '，确定吗？'), '确认', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    try {
        $form.Cursor = 'WaitCursor'
        if (-not (Apply-AdapterConfig -name $a.Name -useDhcp $cfg.Dhcp -ip $cfg.Ip -mask $cfg.Mask -gw $cfg.Gw -d1 $cfg.Dns1 -d2 $cfg.Dns2)) { return }
        if ($cfg.SetMac) { Apply-MacChange -name $a.Name -mac $cfg.Mac }
        if ($cfg.Dns1) { Add-DnsHistory $cfg.Dns1 }
        if ($cfg.Dns2) { Add-DnsHistory $cfg.Dns2 }
        Refresh-AdapterList -SelectActive
        Show-Msg '配置已应用成功。' '完成'
    }
    catch {
        Show-Msg ("应用失败：{0}" -f $_.Exception.Message) '错误' 'Error'
        Refresh-AdapterList
    }
    finally {
        $form.Cursor = 'Default'
    }
})

$btnRead.Add_Click({ Load-AdapterConfig })

# --- 生成随机 MAC ---
$btnGenMac.Add_Click({
    # 第二位随机选 2/6/A/E（本地管理位为 1），其余 10 位随机
    $secondChars = @('2','6','A','E')
    $hexChars = '0123456789ABCDEF'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('0')                                        # 第一位固定 0
    [void]$sb.Append($secondChars[(Get-Random 4)])              # 第二位本地管理位
    for ($i = 0; $i -lt 10; $i++) {                              # 其余 10 位随机
        [void]$sb.Append($hexChars[(Get-Random 16)])
    }
    $raw = $sb.ToString()
    # 格式化为 XX:XX:XX:XX:XX:XX
    $formatted = ($raw -replace '(.{2})(?!$)', '$1:')
    $txtMac.Text = $formatted
    $chkMac.Checked = $true
    Update-FieldValidation $txtMac
})

# --- 独立应用 MAC ---
$btnApplyMac.Add_Click({
    $a = Get-SelectedAdapter
    if ($null -eq $a) { Show-Msg '请先在上方列表选择一块网卡。'; return }
    $mac = $txtMac.Text.Trim()
    if (-not $mac) { Show-Msg '请先输入 MAC 地址或点击"生成"按钮。' '提示'; return }
    if (-not (Test-MacText $mac)) {
        Update-FieldValidation $txtMac
        [void]$txtMac.Focus()
        Show-Msg 'MAC 地址格式不正确（12 位十六进制）。' '错误' 'Error'
        return
    }
    $hex = ($mac -replace '[:\-\.]', '').ToUpper()
    $formatted = ($hex -replace '(.{2})(?!$)', '$1:')
    $secondChar = $hex[1]
    if ($secondChar -notin @('2','6','A','E')) {
        $confirm = [Windows.Forms.MessageBox]::Show($form,
            ("MAC 第二位为 '{0}'，未设置本地管理位，多数网卡驱动会拒绝。`n是否仍要尝试？" -f $secondChar),
            '兼容性警告', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }
    }
    $confirm2 = [Windows.Forms.MessageBox]::Show($form,
        "确定将网卡【$($a.Name)】的 MAC 修改为 $formatted 吗？", '确认', 'YesNo', 'Question')
    if ($confirm2 -ne 'Yes') { return }

    try {
        $form.Cursor = 'WaitCursor'
        Apply-MacChange -name $a.Name -mac $mac
        Refresh-AdapterList -SelectActive
        Show-Msg 'MAC 地址已应用。' '完成'
    }
    catch {
        Show-Msg ("MAC 修改失败：{0}" -f $_.Exception.Message) '错误' 'Error'
        Refresh-AdapterList
    }
    finally {
        $form.Cursor = 'Default'
    }
})

# --- IPv6 开关 ---
function Set-SelectedIpv6([bool]$enable) {
    $a = Get-SelectedAdapter
    if ($null -eq $a) { Show-Msg '请先在上方列表选择一块网卡。'; return }
    $actionText = if ($enable) { '启用' } else { '禁用' }
    $confirmText = "确定{0}网卡【{1}】的 IPv6 吗？" -f $actionText, $a.Name
    $confirm = [Windows.Forms.MessageBox]::Show($form, $confirmText, '确认', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }
    try {
        if ($enable) { Enable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction Stop }
        else         { Disable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction Stop }
        Refresh-AdapterList -SelectActive
        Show-Msg ("已{0}网卡【{1}】的 IPv6。" -f $actionText, $a.Name) '完成'
    }
    catch {
        Show-Msg ("操作失败：{0}" -f $_.Exception.Message) '错误' 'Error'
    }
}
$btnV6Off.Add_Click({ Set-SelectedIpv6 $false })
$btnV6On.Add_Click({ Set-SelectedIpv6 $true })

# --- 网卡 启用/禁用 ---
function Set-SelectedNic([bool]$enable) {
    $a = Get-SelectedAdapter
    if ($null -eq $a) { Show-Msg '请先在上方列表选择一块网卡。'; return }
    $actionText = if ($enable) { '启用' } else { '禁用' }
    $warn = if ($enable) { '' } else { "`n注意：禁用网卡会中断该网卡上的网络连接！" }
    $confirmText = "确定{0}网卡【{1}】吗？{2}" -f $actionText, $a.Name, $warn
    $confirm = [Windows.Forms.MessageBox]::Show($form, $confirmText, '确认', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }
    try {
        if ($enable) { Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop }
        else         { Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop }
        Refresh-AdapterList -SelectActive
        Show-Msg ("已{0}网卡【{1}】。" -f $actionText, $a.Name) '完成'
    }
    catch {
        Show-Msg ("操作失败：{0}" -f $_.Exception.Message) '错误' 'Error'
    }
}
$btnNicOff.Add_Click({ Set-SelectedNic $false })
$btnNicOn.Add_Click({ Set-SelectedNic $true })

# --- 清理 DNS 缓存（使用进程内原生命令，不启动外部 exe，避免安全软件拦截） ---
$btnFlushDns.Add_Click({
    $confirm = [Windows.Forms.MessageBox]::Show($form, '确定清理系统 DNS 解析缓存吗？', '确认', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }
    try {
        $form.Cursor = 'WaitCursor'
        $oldTitle = $form.Text
        $form.Text = '正在清理 DNS 缓存...'
        $form.Refresh()
        if (Get-Command Clear-DnsClientCache -ErrorAction SilentlyContinue) {
            # Win8/Server2012+ 原生 cmdlet，纯进程内调用，不产生子进程
            Clear-DnsClientCache -ErrorAction Stop
        } else {
            # 极老系统（Win7/2008R2）兜底：调用 DNS API
            $sig = @'
[DllImport("dnsapi.dll", SetLastError=true)]
public static extern void DnsFlushResolverCache();
'@
            $dnsApi = Add-Type -MemberDefinition $sig -Name DnsApi -Namespace Win32 -PassThru -ErrorAction SilentlyContinue
            if (-not $dnsApi) { $dnsApi = [Win32.DnsApi] }
            $dnsApi::DnsFlushResolverCache()
        }
        $form.Text = $oldTitle
        Show-Msg 'DNS 解析缓存已成功清理。' '完成'
    }
    catch {
        $form.Text = $oldTitle
        Show-Msg ("清理 DNS 缓存失败：{0}" -f $_.Exception.Message) '错误' 'Error'
    }
    finally {
        $form.Cursor = 'Default'
    }
})

# --- 重新获取 IP（仅对用户选中的网卡；WMI 进程内调用，不启动 ipconfig.exe，避免安全软件拦截） ---
$btnRenewIp.Add_Click({
    $a = Get-SelectedAdapter
    if ($null -eq $a) { Show-Msg '请先在上方列表选择要操作的网卡。'; return }

    try {
        $cfg = Get-AdapterWmiConfig $a.ifIndex
    } catch {
        Show-Msg ("无法读取网卡配置：{0}" -f $_.Exception.Message) '错误' 'Error'
        return
    }

    if ($cfg.DHCPEnabled) {
        $modeText = 'DHCP 重新请求（释放当前租约并重新获取 IP）'
    } else {
        $modeText = '静态 IP 重新配置（按当前静态参数重新应用）'
    }
    $confirm = [Windows.Forms.MessageBox]::Show($form,
        ("将仅对选中的网卡【{0}】执行：{1}`n其他网卡不受影响。`n执行期间该网卡网络会短暂中断，确定吗？" -f $a.Name, $modeText),
        '确认', 'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }

    try {
        $form.Cursor = 'WaitCursor'
        $oldTitle = $form.Text

        if ($cfg.DHCPEnabled) {
            # ---- DHCP 网卡：释放 → 续租（仅该网卡） ----
            if (-not $cfg.IPEnabled) {
                $form.Text = $oldTitle
                Show-Msg ("网卡【{0}】当前未连接或未启用，无法获取 DHCP 地址。" -f $a.Name) '提示' 'Warning'
                return
            }

            $form.Text = ("网卡【{0}】：正在释放 IP 地址..." -f $a.Name)
            $form.Refresh()
            $r1 = $cfg | Invoke-CimMethod -MethodName ReleaseDHCPLease -ErrorAction Stop
            if ($r1.ReturnValue -ne 0) {
                throw ("释放 DHCP 租约失败，状态码：{0}" -f $r1.ReturnValue)
            }
            Start-Sleep -Milliseconds 1000

            $form.Text = ("网卡【{0}】：正在重新获取 IP 地址..." -f $a.Name)
            $form.Refresh()
            # 释放后重新查询，避免使用已失效的 CIM 对象
            $cfgFresh = Get-AdapterWmiConfig $a.ifIndex
            $r2 = $cfgFresh | Invoke-CimMethod -MethodName RenewDHCPLease -ErrorAction Stop
            if ($r2.ReturnValue -ne 0) {
                throw ("DHCP 续租失败，状态码：{0}" -f $r2.ReturnValue)
            }
            Start-Sleep -Milliseconds 1800
        }
        else {
            # ---- 静态 IP 网卡：按当前参数重新应用配置 ----
            if (-not $cfg.IPAddress -or $cfg.IPAddress.Count -eq 0) {
                throw '该网卡为静态配置但未读取到当前 IP，无法重新配置。'
            }
            $v4List = @()
            for ($i = 0; $i -lt $cfg.IPAddress.Count; $i++) {
                if ($cfg.IPAddress[$i] -match '^\d+\.') { $v4List += $i }
            }
            if ($v4List.Count -eq 0) { throw '未找到该网卡的 IPv4 静态地址。' }
            $idx = $v4List[0]
            $curIp   = $cfg.IPAddress[$idx]
            $curMask = if ($cfg.IPSubnet -and $idx -lt $cfg.IPSubnet.Count) { $cfg.IPSubnet[$idx] } else { $null }
            $curGw   = if ($cfg.DefaultIPGateway) { $cfg.DefaultIPGateway[0] } else { $null }
            $dnsArr  = @($cfg.DNSServerSearchOrder | Where-Object { $_ -and $_ -notmatch ':' })
            $d1 = if ($dnsArr.Count -ge 1) { $dnsArr[0] } else { '' }
            $d2 = if ($dnsArr.Count -ge 2) { $dnsArr[1] } else { '' }

            if (-not $curMask) { throw '未读取到当前子网掩码，无法重新配置。' }
            $form.Text = ("网卡【{0}】：正在重新应用静态配置..." -f $a.Name)
            $form.Refresh()
            if (-not (Apply-AdapterConfig -name $a.Name -useDhcp $false -ip $curIp -mask $curMask -gw $curGw -d1 $d1 -d2 $d2)) { return }
            Start-Sleep -Milliseconds 1200
        }

        $form.Text = $oldTitle

        # ---- 读取更新后的权威配置（WMI 查询同一接口）并反馈 ----
        $after = Get-AdapterWmiConfig $a.ifIndex
        Refresh-AdapterList -SelectActive

        $newIps  = @($after.IPAddress | Where-Object { $_ -and $_ -notmatch ':' })
        $ipLine  = if ($newIps.Count -gt 0) { $newIps -join ', ' } else { '（无 IPv4 地址）' }
        $maskLine = if ($after.IPSubnet) { ($after.IPSubnet | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1) } else { '-' }
        $gwLine  = if ($after.DefaultIPGateway) { ($after.DefaultIPGateway | Where-Object { $_ -notmatch ':' }) -join ', ' } else { '无' }
        $modeLine = if ($after.DHCPEnabled) { 'DHCP 自动获取' } else { '静态 IP' }
        $dhcpSrv  = if ($after.DHCPServer) { $after.DHCPServer } else { '-' }

        $summary = @"
网卡【$($a.Name)】IP 重新获取完成。

配置方式：$modeLine
IPv4 地址：$ipLine
子网掩码：$maskLine
默认网关：$gwLine
"@
        if ($after.DHCPEnabled) { $summary += "`nDHCP 服务器：$dhcpSrv" }
        Show-Msg $summary '完成'
    }
    catch {
        $form.Text = $oldTitle
        Show-Msg ("重新获取 IP 失败：{0}" -f $_.Exception.Message) '错误' 'Error'
        Refresh-AdapterList
    }
    finally {
        $form.Cursor = 'Default'
    }
})

# --- 方案管理 ---
$btnPSave.Add_Click({
    $a = Get-SelectedAdapter
    if ($null -eq $a) { Show-Msg '请先选择网卡，再保存方案（方案会记录当前编辑区的配置）。'; return }
    $name = $txtProfileName.Text.Trim()
    if (-not $name) { Show-Msg '请先填写方案名称。'; return }

    $cfg = Get-FormConfig
    # @() 必须包住整条管道，保证过滤结果始终是数组
    $profiles = @(Load-Profiles | Where-Object { $_.Name -ne $name })
    $profiles += [pscustomobject]@{
        Name = $name; Adapter = $a.Name; Dhcp = $cfg.Dhcp
        Ip = $cfg.Ip; Mask = $cfg.Mask; Gateway = $cfg.Gw
        Dns1 = $cfg.Dns1; Dns2 = $cfg.Dns2
    }
    try {
        Save-Profiles $profiles
    }
    catch {
        Show-Msg ("保存失败：{0}" -f $_.Exception.Message) '错误' 'Error'
        return
    }
    Refresh-ProfileList
    Show-Msg ("方案【{0}】已保存。" -f $name) '完成'
})

$btnPApply.Add_Click({
    if ($lbProfiles.SelectedIndex -lt 0) { Show-Msg '请先在左侧列表选择要应用的方案。'; return }
    $p = (Load-Profiles) | Where-Object { $_.Name -eq $lbProfiles.SelectedItem } | Select-Object -First 1
    if ($null -eq $p) { Show-Msg '方案数据读取失败。' '错误' 'Error'; return }
    if (-not (Get-NetAdapter -Name $p.Adapter -ErrorAction SilentlyContinue)) {
        Show-Msg ("方案中的网卡【{0}】当前不存在，无法应用。" -f $p.Adapter) '错误' 'Error'; return
    }
    $confirmText = "确定把网卡【{0}】应用为方案【{1}】的配置吗？" -f $p.Adapter, $p.Name
    $confirm = [Windows.Forms.MessageBox]::Show($form, $confirmText, '确认', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    try {
        if (-not (Apply-AdapterConfig -name $p.Adapter -useDhcp ([bool]$p.Dhcp) -ip $p.Ip -mask $p.Mask -gw $p.Gateway -d1 $p.Dns1 -d2 $p.Dns2)) { return }
        Refresh-AdapterList -SelectActive
        Show-Msg '方案已应用。' '完成'
    }
    catch {
        Show-Msg ("应用失败：{0}" -f $_.Exception.Message) '错误' 'Error'
        Refresh-AdapterList
    }
})

$btnPDelete.Add_Click({
    if ($lbProfiles.SelectedIndex -lt 0) { Show-Msg '请先选择要删除的方案。'; return }
    $name = $lbProfiles.SelectedItem
    $confirm = [Windows.Forms.MessageBox]::Show($form, ("确定删除方案【{0}】吗？" -f $name), '确认', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }
    $profiles = @(Load-Profiles | Where-Object { $_.Name -ne $name })
    try {
        Save-Profiles $profiles
    }
    catch {
        Show-Msg ("删除失败：{0}" -f $_.Exception.Message) '错误' 'Error'
        return
    }
    Refresh-ProfileList
})

# ---------------- 界面缩放（Ctrl+滚轮 / 触控双指 / 按钮 / 键盘） ----------------
# 原先没有任何缩放实现，此处统一提供四种触发方式，共用同一状态与范围限制。
$script:zoomMin = 0.75
$script:zoomMax = 2.0
$script:zoomFactor = 1.0

# 不在工具栏放缩放按钮：仅用 Ctrl+滚轮 / Ctrl + +/-/0 / 触控双指，比例显示在标题栏
$script:zoomBaseTitle = $form.Text

# 快照：记录每个控件的原始字体、位置、尺寸与列宽，缩放始终相对 100% 计算，避免累积误差。
$script:zoomSnapshot = @()
function Add-ZoomSnapshot($root) {
    foreach ($ctl in $root.Controls) {
        $entry = @{
            Control = $ctl
            Font = [Drawing.Font]$ctl.Font.Clone()
            Size = $ctl.Size
            Location = $ctl.Location
            Margin = $ctl.Margin
            Padding = $ctl.Padding
            PaddingIsPoint = ($ctl.Padding -is [Drawing.Point])   # TabControl.Padding 是 Point，其余控件是 Padding
            Dock = $ctl.Dock
            AutoSize = $ctl.AutoSize
            ParentLayout = ($ctl.Parent -is [Windows.Forms.TableLayoutPanel] -or $ctl.Parent -is [Windows.Forms.FlowLayoutPanel])
            Columns = $null
            LastFont = $null
        }
        if ($ctl -is [Windows.Forms.ListView]) {
            $widths = @()
            foreach ($col in $ctl.Columns) { $widths += $col.Width }
            $entry.Columns = $widths
        }
        $script:zoomSnapshot += $entry
        if ($ctl.HasChildren) { Add-ZoomSnapshot $ctl }
    }
}

function Scale-Padding($padding, [double]$factor) {
    [Windows.Forms.Padding]::new(
        [int][Math]::Round($padding.Left * $factor),
        [int][Math]::Round($padding.Top * $factor),
        [int][Math]::Round($padding.Right * $factor),
        [int][Math]::Round($padding.Bottom * $factor))
}

function Fit-ListColumns($lv, [int[]]$baseWidths, [double]$factor) {
    # 列宽 = 基础宽度 × 缩放因子，再按列表实际宽度等比分配填满，窗口放大/缩小时无需逐列手拖
    if (-not $lv -or $lv.IsDisposed -or $lv.Columns.Count -ne $baseWidths.Count) { return }
    $avail = $lv.ClientSize.Width - 4
    if ($avail -lt 100) { return }
    $sum = 0.0
    foreach ($w in $baseWidths) { $sum += $w * $factor }
    if ($sum -le 0) { return }
    $ratio = $avail / $sum
    $lv.BeginUpdate()
    try {
        for ($i = 0; $i -lt $baseWidths.Count; $i++) {
            $lv.Columns[$i].Width = [Math]::Max(30, [int][Math]::Round($baseWidths[$i] * $factor * $ratio))
        }
    } finally { $lv.EndUpdate() }
}

function Apply-ZoomFactor([double]$factor) {
    $form.SuspendLayout()
    try {
        foreach ($e in $script:zoomSnapshot) {
            $c = $e.Control
            if ($c.IsDisposed) { continue }
            # 不修改窗体自身字体，避免触发 AutoScaleMode=Font 的二次自动缩放
            $newFont = New-Object Drawing.Font($e.Font.FontFamily, [single][Math]::Max(6.0, $e.Font.Size * $factor), $e.Font.Style, $e.Font.Unit)
            $c.Font = $newFont
            if ($e.LastFont) { $e.LastFont.Dispose() }   # 仅释放本模块创建的上一帧字体，原始共享字体不释放
            $e.LastFont = $newFont

            $c.Margin = Scale-Padding $e.Margin $factor
            if ($e.PaddingIsPoint) {
                $c.Padding = [Drawing.Point]::new([int][Math]::Round($e.Padding.X * $factor), [int][Math]::Round($e.Padding.Y * $factor))
            } else {
                $c.Padding = Scale-Padding $e.Padding $factor
            }
            if (-not $e.ParentLayout) {
                # 普通容器：由本模块按快照重算；布局容器子控件交给布局管理器，仅缩放字体与边距
                switch ([string]$e.Dock) {
                    'None' {
                        $c.Location = [Drawing.Point]::new([int][Math]::Round($e.Location.X * $factor), [int][Math]::Round($e.Location.Y * $factor))
                        if (-not $e.AutoSize) { $c.Size = [Drawing.Size]::new([int][Math]::Round($e.Size.Width * $factor), [int][Math]::Round($e.Size.Height * $factor)) }
                    }
                    'Top'    { if (-not $e.AutoSize) { $c.Height = [Math]::Max(1, [int][Math]::Round($e.Size.Height * $factor)) } }
                    'Bottom' { if (-not $e.AutoSize) { $c.Height = [Math]::Max(1, [int][Math]::Round($e.Size.Height * $factor)) } }
                    'Left'   { if (-not $e.AutoSize) { $c.Width  = [Math]::Max(1, [int][Math]::Round($e.Size.Width  * $factor)) } }
                    'Right'  { if (-not $e.AutoSize) { $c.Width  = [Math]::Max(1, [int][Math]::Round($e.Size.Width  * $factor)) } }
                }
            } elseif ($c.Parent -is [Windows.Forms.FlowLayoutPanel] -and -not $e.AutoSize -and [string]$e.Dock -eq 'None') {
                $c.Size = [Drawing.Size]::new([int][Math]::Round($e.Size.Width * $factor), [int][Math]::Round($e.Size.Height * $factor))
            }
        }
    } finally {
        $form.ResumeLayout($true)
    }
    Fit-ListColumns $list $script:listBaseCols $factor
    Fit-ListColumns $scanList $script:scanBaseCols $factor
}

function Sync-ZoomState {
    $pct = [int][Math]::Round($script:zoomFactor * 100)
    $form.Text = if ($pct -eq 100) { $script:zoomBaseTitle } else { '{0}  [{1}%]' -f $script:zoomBaseTitle, $pct }
}

$script:zoomAnim = $null
$zoomTimer = New-Object Windows.Forms.Timer
$zoomTimer.Interval = 15
$zoomTimer.Add_Tick({
    $a = $script:zoomAnim
    if (-not $a) { $zoomTimer.Stop(); return }
    # 140ms 平滑过渡（smoothstep 缓动），按钮/滚轮/键盘共用
    $t = [Math]::Min(1.0, ([DateTime]::Now - $a.Start).TotalMilliseconds / 140.0)
    $ease = $t * $t * (3 - 2 * $t)
    $script:zoomFactor = $a.From + ($a.To - $a.From) * $ease
    Apply-ZoomFactor $script:zoomFactor
    if ($t -ge 1.0) { $zoomTimer.Stop(); $script:zoomAnim = $null }
    Sync-ZoomState
})

function Set-Zoom([double]$target, [switch]$Immediate) {
    # 统一边界：75% ~ 200%
    $target = [Math]::Max($script:zoomMin, [Math]::Min($script:zoomMax, $target))
    if ($Immediate) {
        $zoomTimer.Stop()
        $script:zoomAnim = $null
        $script:zoomFactor = $target
        Apply-ZoomFactor $target
        Sync-ZoomState
        return
    }
    $script:zoomAnim = @{ From = $script:zoomFactor; To = $target; Start = [DateTime]::Now }
    $zoomTimer.Start()
}
function Step-Zoom([int]$direction) {
    Set-Zoom ([Math]::Round(($script:zoomFactor + 0.1 * $direction) * 100) / 100)
}
function Set-ZoomByRatio([double]$ratio) {
    # 触控双指：连续比例输入直接跟手应用，避免动画排队造成迟滞
    if ($ratio -le 0) { return }
    Set-Zoom ($script:zoomFactor * $ratio) -Immediate
}
function Test-ZoomKey($keyData) {
    if (([int]$keyData -band [int][Windows.Forms.Keys]::Control) -eq 0) { return $false }
    switch ([int]$keyData -band 0xFFFF) {
        107 { Step-Zoom 1;  return $true }   # Ctrl + 小键盘 +
        109 { Step-Zoom -1; return $true }   # Ctrl + 小键盘 -
        187 { Step-Zoom 1;  return $true }   # Ctrl + =
        189 { Step-Zoom -1; return $true }   # Ctrl + -
        48  { Set-Zoom 1.0; return $true }   # Ctrl + 0
        96  { Set-Zoom 1.0; return $true }   # Ctrl + 小键盘 0
    }
    return $false
}

$form.KeyPreview = $true
$form.Add_KeyDown({
    param($sender, $e)
    if (Test-ZoomKey $e.KeyData) { $e.Handled = $true; $e.SuppressKeyPress = $true }
})

# Ctrl+滚轮 与 触控双指（WM_GESTURE / GID_ZOOM）在消息循环层拦截，焦点在子控件时同样有效
Add-Type -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll') -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Native {
    public sealed class ZoomMessageFilter : IMessageFilter {
        public Func<bool> ZoomModifier = () => (Control.ModifierKeys & Keys.Control) == Keys.Control;
        public event Action<int> WheelZoom;
        public event Action<double> GestureZoom;
        private double lastDistance;

        [StructLayout(LayoutKind.Sequential)]
        private struct GestureInfo {
            public uint cbSize, dwFlags, dwID;
            public IntPtr hwndTarget;
            public short x, y;
            public uint dwInstanceID, dwSequenceID;
            public ulong ullArguments;
            public uint cbExtraArguments;
        }
        [DllImport("user32.dll")] private static extern bool GetGestureInfo(IntPtr hGestureInfo, ref GestureInfo info);
        [DllImport("user32.dll")] private static extern bool CloseGestureInfoHandle(IntPtr hGestureInfo);

        public bool PreFilterMessage(ref Message m) {
            if (m.Msg == 0x020A) { // WM_MOUSEWHEEL
                if (!ZoomModifier()) return false;
                int delta = (short)((m.WParam.ToInt64() >> 16) & 0xFFFF);
                Action<int> handler = WheelZoom;
                if (handler == null || delta == 0) return false;
                handler(delta > 0 ? 1 : -1);
                return true;
            }
            if (m.Msg == 0x0119) { // WM_GESTURE
                GestureInfo info = new GestureInfo();
                info.cbSize = (uint)Marshal.SizeOf(typeof(GestureInfo));
                if (!GetGestureInfo(m.LParam, ref info)) return false;
                try {
                    if (info.dwID != 3) return false; // 只接管 GID_ZOOM，平移等其它手势交还系统
                    double distance = info.ullArguments;
                    if ((info.dwFlags & 1) != 0) { lastDistance = distance; return true; } // GF_BEGIN
                    if (lastDistance > 0 && distance > 0) {
                        Action<double> handler = GestureZoom;
                        if (handler != null) handler(distance / lastDistance);
                    }
                    lastDistance = distance;
                    return true;
                } finally { CloseGestureInfoHandle(m.LParam); }
            }
            return false;
        }
    }
}
'@
$script:zoomFilter = New-Object Native.ZoomMessageFilter
$script:zoomFilter.add_WheelZoom({ param($direction) Step-Zoom $direction })
$script:zoomFilter.add_GestureZoom({ param($ratio) Set-ZoomByRatio $ratio })
[Windows.Forms.Application]::AddMessageFilter($script:zoomFilter)

Add-ZoomSnapshot $form
$script:listBaseCols = [int[]]@($list.Columns | ForEach-Object Width)
$script:scanBaseCols = [int[]]@($scanList.Columns | ForEach-Object Width)
$list.Add_SizeChanged({ Fit-ListColumns $list $script:listBaseCols $script:zoomFactor })
$scanList.Add_SizeChanged({ Fit-ListColumns $scanList $script:scanBaseCols $script:zoomFactor })
Sync-ZoomState
$form.Add_FormClosed({
    [Windows.Forms.Application]::RemoveMessageFilter($script:zoomFilter)
    $zoomTimer.Dispose()
})

$form.Add_Shown({
    # 先让窗口立即绘制，占位提示 + 定时器延迟加载网卡数据（WMI 冷启动可达数秒）
    $ph = New-Object Windows.Forms.ListViewItem('正在读取网卡信息，请稍候...')
    $ph.ForeColor = [Drawing.Color]::Gray
    [void]$list.Items.Add($ph)

    $script:loadTimer = New-Object Windows.Forms.Timer
    $script:loadTimer.Interval = 150
    $script:loadTimer.Add_Tick({
        $script:loadTimer.Stop()
        Refresh-AdapterList
        $script:loadTimer.Dispose()
    })
    $script:loadTimer.Start()

    # 首次显示时列宽也按可用宽度填充（句柄已创建，避免初始不触发 SizeChanged）
    Fit-ListColumns $list $script:listBaseCols $script:zoomFactor
    Fit-ListColumns $scanList $script:scanBaseCols $script:zoomFactor
})

[void]$form.ShowDialog()
$form.Dispose()
