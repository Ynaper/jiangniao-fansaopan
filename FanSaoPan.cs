using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace FanSaoPan
{
    // ===== Settings =====
    public class AppSettings
    {
        public bool FirstRunComplete { get; set; }
        public bool AutoStartEnabled { get; set; }
        public bool ShowOverlayByDefault { get; set; }
        public bool OverlayPermanentlyHidden { get; set; }
        public List<string> CustomReplies { get; set; }
        public List<Dictionary<string, object>> CustomCharacters { get; set; }
    }

    // ===== Simple JSON Helper (avoids external deps) =====
    static class SimpleJson
    {
        public static AppSettings Read(string path)
        {
            if (!File.Exists(path)) return Defaults();
            var json = File.ReadAllText(path, Encoding.UTF8);
            var s = new AppSettings();
            s.FirstRunComplete = GetBool(json, "FirstRunComplete");
            s.AutoStartEnabled = GetBool(json, "AutoStartEnabled");
            s.ShowOverlayByDefault = GetBool(json, "ShowOverlayByDefault", true);
            s.OverlayPermanentlyHidden = GetBool(json, "OverlayPermanentlyHidden");
            s.CustomReplies = GetList(json, "CustomReplies");
            s.CustomCharacters = new List<Dictionary<string, object>>();
            return s;
        }

        public static void Write(string path, AppSettings s)
        {
            var sb = new StringBuilder();
            sb.AppendLine("{");
            sb.AppendLine($"    \"AutoStartEnabled\":  {s.AutoStartEnabled.ToString().ToLower()},");
            sb.AppendLine($"    \"FirstRunComplete\":  {s.FirstRunComplete.ToString().ToLower()},");
            sb.Append("    \"CustomReplies\":  [");
            if (s.CustomReplies != null && s.CustomReplies.Count > 0)
            {
                sb.AppendLine();
                for (int i = 0; i < s.CustomReplies.Count; i++)
                {
                    var escaped = s.CustomReplies[i].Replace("\\", "\\\\").Replace("\"", "\\\"");
                    sb.Append($"        \"{escaped}\"");
                    if (i < s.CustomReplies.Count - 1) sb.Append(",");
                    sb.AppendLine();
                }
            }
            sb.AppendLine("                      ],");
            sb.AppendLine($"    \"ShowOverlayByDefault\":  {s.ShowOverlayByDefault.ToString().ToLower()},");
            sb.AppendLine($"    \"OverlayPermanentlyHidden\":  {s.OverlayPermanentlyHidden.ToString().ToLower()},");
            sb.AppendLine("    \"CustomCharacters\":  [");
            sb.AppendLine("                         ]");
            sb.AppendLine("}");
            File.WriteAllText(path, sb.ToString(), Encoding.UTF8);
        }

        static AppSettings Defaults()
        {
            return new AppSettings { ShowOverlayByDefault = true };
        }

        static bool GetBool(string json, string key, bool def = false)
        {
            var m = Regex.Match(json, $@"""{key}"":\s*(true|false)", RegexOptions.IgnoreCase);
            return m.Success ? bool.Parse(m.Groups[1].Value) : def;
        }

        static List<string> GetList(string json, string key)
        {
            var list = new List<string>();
            var m = Regex.Match(json, $@"""{key}"":\s*\[(.*?)\]", RegexOptions.Singleline);
            if (!m.Success) return list;
            var content = m.Groups[1].Value;
            var items = Regex.Matches(content, @"""([^""\\]*(?:\\.[^""\\]*)*)""");
            foreach (Match item in items)
                list.Add(item.Groups[1].Value.Replace("\\\"", "\"").Replace("\\\\", "\\"));
            return list;
        }
    }

    // ===== Settings Form =====
    public class SettingsForm : Form
    {
        private CheckBox chkAutoStart, chkShowOverlay;
        private Button btnAddChar, btnAddReply, btnSave, btnCancel;
        private Label lblStatus;
        private string scriptDir;
        private AppSettings settings;

        public SettingsForm(string scriptDir)
        {
            this.scriptDir = scriptDir;
            settings = SimpleJson.Read(Path.Combine(scriptDir, "settings.json"));
            InitializeUI();
            LoadSettings();
        }

        void InitializeUI()
        {
            Text = "反扫盘 · 设置";
            Size = new Size(500, 380);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            BackColor = Color.FromArgb(245, 246, 250);
            Font = new Font("Microsoft YaHei UI", 9f);
            Icon = SystemIcons.Application;

            var header = new Label
            {
                Text = "反扫盘",
                Font = new Font("Microsoft YaHei UI", 18f, FontStyle.Bold),
                ForeColor = Color.FromArgb(45, 52, 54),
                Location = new Point(30, 20),
                AutoSize = true
            };
            var subtitle = new Label
            {
                Text = "ACE-Guard 进程监控 · 角色悬浮窗",
                Font = new Font("Microsoft YaHei UI", 9f),
                ForeColor = Color.Gray,
                Location = new Point(30, 50),
                AutoSize = true
            };
            Controls.Add(header);
            Controls.Add(subtitle);

            // Left panel - checkboxes
            var leftPanel = new GroupBox
            {
                Text = "常规设置",
                Location = new Point(30, 85),
                Size = new Size(200, 120),
                FlatStyle = FlatStyle.System
            };
            chkAutoStart = new CheckBox
            {
                Text = "开机自启动",
                Location = new Point(15, 30),
                AutoSize = true,
                Font = new Font("Microsoft YaHei UI", 11f)
            };
            chkShowOverlay = new CheckBox
            {
                Text = "默认打开悬浮窗",
                Location = new Point(15, 65),
                AutoSize = true,
                Font = new Font("Microsoft YaHei UI", 11f)
            };
            leftPanel.Controls.Add(chkAutoStart);
            leftPanel.Controls.Add(chkShowOverlay);
            Controls.Add(leftPanel);

            // Right panel - buttons
            var rightLabel = new Label
            {
                Text = "自定义",
                Location = new Point(290, 85),
                Font = new Font("Microsoft YaHei UI", 9f),
                ForeColor = Color.Gray,
                AutoSize = true
            };
            btnAddChar = CreateOutlineButton("＋ 新增自定义角色", new Point(290, 110));
            btnAddReply = CreateOutlineButton("＋ 新增自定义回复", new Point(290, 160));
            Controls.Add(rightLabel);

            // Bottom panel
            lblStatus = new Label
            {
                Location = new Point(30, 240),
                Size = new Size(440, 25),
                ForeColor = Color.FromArgb(0, 184, 148),
                Font = new Font("Microsoft YaHei UI", 9f)
            };
            Controls.Add(lblStatus);

            btnCancel = new Button
            {
                Text = "关闭",
                Location = new Point(300, 285),
                Size = new Size(75, 32),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.Transparent,
                ForeColor = Color.Gray,
                Font = new Font("Microsoft YaHei UI", 9f),
                Cursor = Cursors.Hand
            };
            btnCancel.FlatAppearance.BorderSize = 0;

            btnSave = new Button
            {
                Text = "保存设置",
                Location = new Point(385, 285),
                Size = new Size(90, 32),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(108, 92, 231),
                ForeColor = Color.White,
                Font = new Font("Microsoft YaHei UI", 9f, FontStyle.Bold),
                Cursor = Cursors.Hand
            };
            btnSave.FlatAppearance.BorderSize = 0;

            btnSave.Paint += (s, e) =>
            {
                var btn = (Button)s;
                using (var brush = new SolidBrush(btn.BackColor))
                    e.Graphics.FillRectangle(brush, 0, 0, btn.Width, btn.Height);
                TextRenderer.DrawText(e.Graphics, btn.Text, btn.Font, btn.ClientRectangle, btn.ForeColor,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            };
            btnSave.MouseEnter += (s, e) => { btnSave.BackColor = Color.FromArgb(90, 75, 209); btnSave.Invalidate(); };
            btnSave.MouseLeave += (s, e) => { btnSave.BackColor = Color.FromArgb(108, 92, 231); btnSave.Invalidate(); };

            Controls.Add(btnCancel);
            Controls.Add(btnSave);

            // Events
            btnSave.Click += BtnSave_Click;
            btnCancel.Click += (s, e) => { DialogResult = DialogResult.Cancel; Close(); };
            btnAddChar.Click += BtnAddChar_Click;
            btnAddReply.Click += BtnAddReply_Click;
            FormClosing += (s, e) => { if (DialogResult == DialogResult.None) DialogResult = DialogResult.Cancel; };
        }

        Button CreateOutlineButton(string text, Point loc)
        {
            var btn = new Button
            {
                Text = text,
                Location = loc,
                Size = new Size(180, 36),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.Transparent,
                ForeColor = Color.FromArgb(108, 92, 231),
                Font = new Font("Microsoft YaHei UI", 9f),
                Cursor = Cursors.Hand
            };
            btn.FlatAppearance.BorderColor = Color.FromArgb(108, 92, 231);
            btn.FlatAppearance.BorderSize = 1;
            btn.MouseEnter += (s, e) => btn.BackColor = Color.FromArgb(240, 237, 255);
            btn.MouseLeave += (s, e) => btn.BackColor = Color.Transparent;
            Controls.Add(btn);
            return btn;
        }

        void LoadSettings()
        {
            chkAutoStart.Checked = settings.AutoStartEnabled;
            chkShowOverlay.Checked = settings.ShowOverlayByDefault;
        }

        void BtnSave_Click(object sender, EventArgs e)
        {
            settings.AutoStartEnabled = chkAutoStart.Checked;
            settings.ShowOverlayByDefault = chkShowOverlay.Checked;
            settings.FirstRunComplete = true;
            SimpleJson.Write(Path.Combine(scriptDir, "settings.json"), settings);

            // Handle scheduled task
            var installScript = Path.Combine(scriptDir, "Install-StartupMonitor.ps1");
            var uninstallScript = Path.Combine(scriptDir, "Uninstall-StartupMonitor.ps1");
            var taskScript = chkAutoStart.Checked ? installScript : uninstallScript;

            try
            {
                RunPowerShell($"-File \"{taskScript}\"", true);
                lblStatus.Text = chkAutoStart.Checked ? "已启用开机自启动" : "已关闭开机自启动";
                lblStatus.ForeColor = Color.FromArgb(0, 184, 148);
            }
            catch
            {
                lblStatus.Text = "设置已保存（需管理员权限管理自启任务）";
                lblStatus.ForeColor = Color.Orange;
            }

            var timer = new Timer { Interval = 1000 };
            timer.Tick += (s2, e2) => { timer.Stop(); DialogResult = DialogResult.OK; Close(); };
            timer.Start();
        }

        void BtnAddChar_Click(object sender, EventArgs e)
        {
            using (var fd = new OpenFileDialog
            {
                Title = "选择角色图片",
                Filter = "图片文件|*.png;*.jpg;*.jpeg;*.gif;*.bmp|所有文件|*.*",
                Multiselect = true
            })
            {
                if (fd.ShowDialog() == DialogResult.OK)
                {
                    var charDir = Path.Combine(scriptDir, "characters");
                    Directory.CreateDirectory(charDir);
                    int count = 0;
                    foreach (var file in fd.FileNames)
                    {
                        var destName = Path.GetFileName(file);
                        var dest = Path.Combine(charDir, destName);
                        if (File.Exists(dest))
                        {
                            var baseName = Path.GetFileNameWithoutExtension(destName);
                            var ext = Path.GetExtension(destName);
                            destName = $"{baseName}_{DateTime.Now:HHmmss}{ext}";
                            dest = Path.Combine(charDir, destName);
                        }
                        File.Copy(file, dest);
                        count++;
                    }
                    lblStatus.Text = $"已添加 {count} 个角色图片，重启悬浮窗后生效";
                    lblStatus.ForeColor = Color.FromArgb(0, 184, 148);
                }
            }
        }

        void BtnAddReply_Click(object sender, EventArgs e)
        {
            using (var inputForm = new Form
            {
                Text = "新增自定义回复",
                Size = new Size(380, 220),
                StartPosition = FormStartPosition.CenterParent,
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false,
                BackColor = Color.FromArgb(245, 246, 250),
                Font = new Font("Microsoft YaHei UI", 9f),
                Owner = this
            })
            {
                var label = new Label
                {
                    Text = "输入点击悬浮窗时显示的回复文字：",
                    Location = new Point(20, 15),
                    AutoSize = true
                };
                var textBox = new TextBox
                {
                    Location = new Point(20, 40),
                    Size = new Size(325, 50),
                    Multiline = true
                };
                var btnOK = new Button
                {
                    Text = "添加",
                    Location = new Point(270, 110),
                    Size = new Size(75, 30),
                    DialogResult = DialogResult.OK,
                    FlatStyle = FlatStyle.Flat,
                    BackColor = Color.FromArgb(108, 92, 231),
                    ForeColor = Color.White
                };
                var btnCancel2 = new Button
                {
                    Text = "取消",
                    Location = new Point(185, 110),
                    Size = new Size(75, 30),
                    DialogResult = DialogResult.Cancel,
                    FlatStyle = FlatStyle.Flat
                };

                inputForm.Controls.Add(label);
                inputForm.Controls.Add(textBox);
                inputForm.Controls.Add(btnOK);
                inputForm.Controls.Add(btnCancel2);
                inputForm.AcceptButton = btnOK;
                inputForm.CancelButton = btnCancel2;

                if (inputForm.ShowDialog() == DialogResult.OK && !string.IsNullOrWhiteSpace(textBox.Text))
                {
                    var text = textBox.Text.Trim();
                    if (settings.CustomReplies == null)
                        settings.CustomReplies = new List<string>();
                    settings.CustomReplies.Add(text);

                    // Also update overlay-ui.json
                      var uiFile = Path.Combine(scriptDir, "overlay-ui.json");
                      if (File.Exists(uiFile))
                      {
                          try
                          {
                              var uiJson = File.ReadAllText(uiFile, Encoding.UTF8);
                              var uiDict = Json.Deserialize<Dictionary<string, object>>(uiJson);
                              if (uiDict != null)
                              {
                                  if (!uiDict.ContainsKey("clickLines"))
                                      uiDict["clickLines"] = new List<object>();
                                  var clickLines = (List<object>)uiDict["clickLines"];
                                  clickLines.Add(text);
                                  uiDict["clickLines"] = clickLines;
                                  File.WriteAllText(uiFile, Json.Serialize(uiDict), Encoding.UTF8);
                              }
                          }
                          catch { }
                      }
                    lblStatus.Text = "已添加自定义回复: " + text;
                    lblStatus.ForeColor = Color.FromArgb(0, 184, 148);
                }
            }
        }

        static string RunPowerShell(string args, bool asAdmin = false)
        {
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass {args}",
                UseShellExecute = true,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            if (asAdmin) psi.Verb = "runas";
            using (var p = Process.Start(psi))
            {
                p.WaitForExit();
                if (p.ExitCode != 0)
                    throw new Exception($"PowerShell exited with code {p.ExitCode}");
                return "";
            }
        }
    }

    // ===== Main Application =====
    static class Program
    {
        static NotifyIcon trayIcon;
        static string scriptDir;
        static AppSettings settings;

        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            scriptDir = AppDomain.CurrentDomain.BaseDirectory;
            bool isBoot = false;
            foreach (var arg in args)
            {
                if (arg.Equals("-boot", StringComparison.OrdinalIgnoreCase))
                    isBoot = true;
            }

            settings = SimpleJson.Read(Path.Combine(scriptDir, "settings.json"));

            // Start monitor
            StartMonitor();

            // Create tray icon
            CreateTray();

            if (isBoot)
            {
                // Boot mode: no settings window, start overlay if enabled
                if (settings.ShowOverlayByDefault && !settings.OverlayPermanentlyHidden)
                    StartOverlay();
            }
            else
            {
                // Manual launch
                if (!settings.FirstRunComplete)
                {
                    ShowSettings();
                    settings = SimpleJson.Read(Path.Combine(scriptDir, "settings.json"));
                }
                if (settings.ShowOverlayByDefault && !settings.OverlayPermanentlyHidden)
                    StartOverlay();
            }

            SyncTrayMenu();
            Application.Run();
        }

        static void CreateTray()
        {
            var menu = new ContextMenuStrip();

            var settingsItem = menu.Items.Add("打开设置");
            settingsItem.Click += (s, e) => ShowSettings();

            menu.Items.Add(new ToolStripSeparator());

            var showOverlayItem = menu.Items.Add("显示悬浮窗");
            var hideOverlayItem = menu.Items.Add("隐藏悬浮窗");
            showOverlayItem.Click += (s, e) => ToggleOverlay();
            hideOverlayItem.Click += (s, e) => ToggleOverlay();

            menu.Items.Add(new ToolStripSeparator());

            var exitItem = menu.Items.Add("退出");
            exitItem.Click += (s, e) =>
            {
                StopOverlay();
                StopMonitor();
                trayIcon.Visible = false;
                trayIcon.Dispose();
                Application.Exit();
            };

            trayIcon = new NotifyIcon
            {
                Icon = SystemIcons.Application,
                Text = "反扫盘",
                Visible = true,
                ContextMenuStrip = menu
            };
            trayIcon.DoubleClick += (s, e) => ShowSettings();
        }

        static void ShowSettings()
        {
            using (var form = new SettingsForm(scriptDir))
            {
                form.ShowDialog();
                settings = SimpleJson.Read(Path.Combine(scriptDir, "settings.json"));
                SyncTrayMenu();
                if (settings.ShowOverlayByDefault && !settings.OverlayPermanentlyHidden && !IsOverlayRunning())
                    StartOverlay();
            }
        }

        static void ToggleOverlay()
        {
            if (IsOverlayRunning())
            {
                StopOverlay();
            }
            else
            {
                settings.OverlayPermanentlyHidden = false;
                SimpleJson.Write(Path.Combine(scriptDir, "settings.json"), settings);
                StartOverlay();
            }
            SyncTrayMenu();
        }

        static void SyncTrayMenu()
        {
            if (trayIcon?.ContextMenuStrip == null) return;
            var menu = trayIcon.ContextMenuStrip;
            // Items: 0=打开设置, 1=sep, 2=显示, 3=隐藏, 4=sep, 5=退出
            bool running = IsOverlayRunning();
            bool permHidden = settings.OverlayPermanentlyHidden;
            if (menu.Items.Count >= 6)
            {
                menu.Items[2].Visible = permHidden || !running;
                menu.Items[3].Visible = running && !permHidden;
            }
        }

        static void StartMonitor()
        {
            var script = Path.Combine(scriptDir, "Set-ProcessEfficiencyMonitor.ps1");
            var logFile = Path.Combine(scriptDir, "monitor.log");
            if (!File.Exists(script)) return;
            if (IsProcessRunning("Set-ProcessEfficiencyMonitor")) return;

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"{script}\" -LogFile \"{logFile}\" -PollIntervalSeconds 60",
                WorkingDirectory = scriptDir,
                WindowStyle = ProcessWindowStyle.Hidden,
                UseShellExecute = true
            };
            try { Process.Start(psi); } catch { }
        }

        static void StartOverlay()
        {
            var script = Path.Combine(scriptDir, "Show-CharacterOverlay.ps1");
            if (!File.Exists(script)) return;
            if (IsProcessRunning("Show-CharacterOverlay")) return;

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File \"{script}\"",
                WorkingDirectory = scriptDir,
                WindowStyle = ProcessWindowStyle.Hidden,
                UseShellExecute = true
            };
            try { Process.Start(psi); } catch { }
        }

        static void StopOverlay()
        {
            KillProcess("Show-CharacterOverlay");
        }

        static void StopMonitor()
        {
            KillProcess("Set-ProcessEfficiencyMonitor");
            var pidFile = Path.Combine(scriptDir, "monitor.pid");
            if (File.Exists(pidFile)) File.Delete(pidFile);
        }

        static void KillProcess(string name)
        {
            foreach (var p in Process.GetProcessesByName("powershell"))
            {
                try
                {
                    if (p.MainWindowTitle.Contains(name) || 
                        (p.StartInfo?.Arguments?.Contains(name) == true))
                    {
                        p.Kill();
                        continue;
                    }
                }
                catch { }
            }
            // Fallback: use WMI
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = $"-NoProfile -Command \"Get-CimInstance Win32_Process | Where-Object {{ $_.CommandLine -like '*{name}*' }} | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force }}\"",
                    WindowStyle = ProcessWindowStyle.Hidden,
                    UseShellExecute = true
                };
                using (var p = Process.Start(psi)) { p.WaitForExit(3000); }
            }
            catch { }
        }

        static bool IsOverlayRunning()
        {
            return IsProcessRunning("Show-CharacterOverlay");
        }

        static bool IsProcessRunning(string name)
        {
            try
            {
                foreach (var p in Process.GetProcessesByName("powershell"))
                {
                    try
                    {
                        using (var searcher = new System.Management.ManagementObjectSearcher(
                            $"SELECT CommandLine FROM Win32_Process WHERE ProcessId = {p.Id}"))
                        {
                            foreach (var obj in searcher.Get())
                            {
                                var cmd = obj["CommandLine"]?.ToString() ?? "";
                                if (cmd.Contains(name)) return true;
                            }
                        }
                    }
                    catch { }
                }
            }
            catch { }
            return false;
        }
    }
}
