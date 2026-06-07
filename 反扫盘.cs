using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Threading;
using System.Xml;
using Forms = System.Windows.Forms;

class Program
{
    static string ScriptDir, SettingsFile, OverlayUiFile, CharactersDir;
    static string MonitorScript, OverlayScript, InstallScript, UninstallScript, XamlFile;

    // Settings
    static bool Settings_FirstRun = false;
    static bool Settings_AutoStart = false;
    static bool Settings_ShowOverlay = true;
    static bool Settings_OverlayHidden = false;

    static Forms.NotifyIcon TrayIcon;
    static Forms.ToolStripMenuItem OverlayToggleItem;
    static Window SettingsWindow;
    static JavaScriptSerializer Json = new JavaScriptSerializer();
    static Button BtnStartStop;
    static TextBlock StatusText;
    static DispatcherTimer StatusTimer;

    [STAThread]
    static void Main(string[] args)
    {
        bool isBoot = args.Any(a => a.Equals("-Boot", StringComparison.OrdinalIgnoreCase));
        bool showSettings = args.Any(a => a.Equals("-Settings", StringComparison.OrdinalIgnoreCase));
        ScriptDir = AppDomain.CurrentDomain.BaseDirectory;
        SettingsFile = Path.Combine(ScriptDir, "settings.json");
        OverlayUiFile = Path.Combine(ScriptDir, "overlay-ui.json");
        CharactersDir = Path.Combine(ScriptDir, "characters");
        MonitorScript = Path.Combine(ScriptDir, "Set-ProcessEfficiencyMonitor.ps1");
        OverlayScript = Path.Combine(ScriptDir, "Show-CharacterOverlay.ps1");
        InstallScript = Path.Combine(ScriptDir, "Install-StartupMonitor.ps1");
        UninstallScript = Path.Combine(ScriptDir, "Uninstall-StartupMonitor.ps1");
        XamlFile = Path.Combine(ScriptDir, "settings-window.xaml");

        LoadAllSettings();
        CreateTrayIcon();

        if (isBoot)
        {
            StartMonitorProcess();
            if (Settings_ShowOverlay && !Settings_OverlayHidden)
                StartOverlayProcess();
        }
        else if (showSettings)
        {
            ShowSettingsWindow();
        }
        else
        {
            if (!Settings_FirstRun)
                ShowSettingsWindow();
            if (Settings_ShowOverlay && !Settings_OverlayHidden)
                StartOverlayProcess();
        }
        SyncTrayMenu();
        Forms.Application.Run();
    }

    // ==================== Settings I/O ====================

    static void LoadAllSettings()
    {
        try
        {
            if (File.Exists(SettingsFile))
            {
                string json = File.ReadAllText(SettingsFile, Encoding.UTF8).TrimStart('\uFEFF');
                var dict = Json.Deserialize<Dictionary<string, object>>(json);
                if (dict != null)
                {
                    Settings_FirstRun = GetBool(dict, "FirstRunComplete");
                    Settings_AutoStart = GetBool(dict, "AutoStartEnabled");
                    Settings_ShowOverlay = !dict.ContainsKey("ShowOverlayByDefault") || GetBool(dict, "ShowOverlayByDefault");
                    Settings_OverlayHidden = GetBool(dict, "OverlayPermanentlyHidden");
                }
            }
        }
        catch (Exception ex) { System.Diagnostics.Debug.WriteLine("LoadSettings error: " + ex.Message); }
    }

    static bool GetBool(Dictionary<string, object> dict, string key)
    {
        if (!dict.ContainsKey(key)) return false;
        object val = dict[key];
        if (val is bool) return (bool)val;
        if (val is string) { bool b; return bool.TryParse((string)val, out b) && b; }
        try { return Convert.ToBoolean(val); } catch { return false; }
    }

    static void SaveAllSettings()
    {
        try
        {
            var dict = new Dictionary<string, object>
            {
                {"FirstRunComplete", Settings_FirstRun},
                {"AutoStartEnabled", Settings_AutoStart},
                {"ShowOverlayByDefault", Settings_ShowOverlay},
                {"OverlayPermanentlyHidden", Settings_OverlayHidden}
            };
            string json = Json.Serialize(dict);
            File.WriteAllText(SettingsFile, json, Encoding.UTF8);
        }
        catch (Exception ex) { System.Diagnostics.Debug.WriteLine("SaveSettings error: " + ex.Message); }
    }

    // ==================== Tray Icon ====================

    static void CreateTrayIcon()
    {
        TrayIcon = new Forms.NotifyIcon
        {
            Text = "\u53cd\u626b\u76d8",
            Visible = true
        };
            try { TrayIcon.Icon = new System.Drawing.Icon(Path.Combine(ScriptDir, "icon.ico")); }
            catch { TrayIcon.Icon = System.Drawing.SystemIcons.Application; }

        var menu = new Forms.ContextMenuStrip();
        var settingsItem = menu.Items.Add("\u6253\u5f00\u8bbe\u7f6e");
        settingsItem.Click += (s, e) => ShowSettingsWindow();

        menu.Items.Add("-");

        OverlayToggleItem = (Forms.ToolStripMenuItem)menu.Items.Add("\u663e\u793a/\u9690\u85cf\u60ac\u6d6e\u7a97");
        OverlayToggleItem.Click += (s, e) => ToggleOverlay();

        menu.Items.Add("-");

        var exitItem = menu.Items.Add("\u9000\u51fa");
        exitItem.Click += (s, e) =>
        {
            TrayIcon.Visible = false; TrayIcon.Dispose();
            KillAllBackground();
            Forms.Application.Exit(); Environment.Exit(0);
        };

        TrayIcon.ContextMenuStrip = menu;
        TrayIcon.DoubleClick += (s, e) => ShowSettingsWindow();
    }

    static void SyncTrayMenu()
    {
        if (TrayIcon == null || OverlayToggleItem == null) return;
        OverlayToggleItem.Text = "\u663e\u793a/\u9690\u85cf\u60ac\u6d6e\u7a97";
    }

    // ==================== Process Management ====================

    static bool WmiContains(string procName, string argPat)
    {
        try
        {
            using (var s = new ManagementObjectSearcher(
                "SELECT CommandLine FROM Win32_Process WHERE Name = '" + procName + "'"))
            {
                foreach (var mo in s.Get())
                {
                    string c = mo["CommandLine"] as string;
                    if (c != null && c.Contains(argPat)) return true;
                }
            }
        }
        catch { }
        return false;
    }

    static bool IsMonitorRunning() { return WmiContains("powershell.exe", "Set-ProcessEfficiencyMonitor"); }
    static bool IsOverlayRunning() { return WmiContains("powershell.exe", "Show-CharacterOverlay"); }
    static bool IsServiceRunning() { return IsMonitorRunning() || IsOverlayRunning(); }

    static void StartMonitorProcess()
    {
        if (IsMonitorRunning()) return;
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + MonitorScript
                    + "\" -LogFile \"" + Path.Combine(ScriptDir, "monitor.log") + "\" -PollIntervalSeconds 60",
                WorkingDirectory = ScriptDir,
                WindowStyle = ProcessWindowStyle.Hidden,
                CreateNoWindow = true,
                UseShellExecute = false
            });
        }
        catch { }
    }

    static void StartOverlayProcess()
    {
        if (IsOverlayRunning()) return;
        if (!File.Exists(OverlayScript)) return;
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + OverlayScript + "\"",
                WorkingDirectory = ScriptDir,
                WindowStyle = ProcessWindowStyle.Hidden,
                CreateNoWindow = false,
                UseShellExecute = true
            });
        }
        catch { }
    }

    static void KillProcessByArg(string argPat)
    {
        try
        {
            using (var s = new ManagementObjectSearcher(
                "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'powershell.exe'"))
            {
                foreach (var mo in s.Get())
                {
                    string c = mo["CommandLine"] as string;
                    if (c != null && c.Contains(argPat))
                    {
                        try { Process.GetProcessById(Convert.ToInt32(mo["ProcessId"])).Kill(); }
                        catch { }
                    }
                }
            }
        }
        catch { }
    }

    static void KillAllBackground()
    {
        KillProcessByArg("Set-ProcessEfficiencyMonitor");
        KillProcessByArg("Show-CharacterOverlay");
    }

    static void ToggleOverlay()
    {
        if (IsOverlayRunning())
        {
            KillProcessByArg("Show-CharacterOverlay");
        }
        else
        {
            Settings_OverlayHidden = false;
            SaveAllSettings();
            StartOverlayProcess();
        }
        SyncTrayMenu();
        RefreshButtonState();
    }

    // ==================== Start/Stop ====================

    static void DoStartAll()
    {
        StartMonitorProcess();
        System.Threading.Thread.Sleep(800);
        Settings_OverlayHidden = false;
        SaveAllSettings();
        if (Settings_ShowOverlay && !Settings_OverlayHidden)
            StartOverlayProcess();
        SyncTrayMenu();
        UpdateStartStopButton(true);
        // Hide settings window into the tray after starting
        if (SettingsWindow != null)
        {
            SettingsWindow.Hide();
        }
    }

    static void DoStopAll()
    {
        KillAllBackground();
        SyncTrayMenu();
        UpdateStartStopButton(false);
    }

    static void UpdateStartStopButton(bool running)
    {
        if (BtnStartStop == null) return;
        try
        {
            BtnStartStop.Dispatcher.Invoke(new Action(() =>
            {
                BtnStartStop.Content = running ? "\u505c\u6b62\u8fd0\u884c" : "\u5f00\u59cb\u8fd0\u884c";
                BtnStartStop.Background = running
                    ? new SolidColorBrush((Color)ColorConverter.ConvertFromString("#E17055"))
                    : new SolidColorBrush((Color)ColorConverter.ConvertFromString("#00B894"));
                BtnStartStop.Foreground = new SolidColorBrush(Colors.White);
            }));
        }
        catch { }
    }

    static void RefreshButtonState()
    {
        if (BtnStartStop == null) return;
        try
        {
            // Small delay to let processes start/stop
            System.Threading.Thread.Sleep(300);
            bool running = IsServiceRunning();
            UpdateStartStopButton(running);
        }
        catch { }
    }

    // ==================== Settings Window ====================

    static void ShowSettingsWindow()
    {
        if (SettingsWindow != null)
        {
            if (SettingsWindow.Visibility != Visibility.Visible)
            {
                SettingsWindow.Show();
                SettingsWindow.WindowState = WindowState.Normal;
            }
            SettingsWindow.Activate();
            // Reload checkbox state
            ReloadCheckboxes();
            return;
        }

        LoadAllSettings();

        Window window;
        try
        {
            if (File.Exists(XamlFile))
            {
                string xaml = File.ReadAllText(XamlFile, Encoding.UTF8).TrimStart('\uFEFF');
                using (var sr = new StringReader(xaml))
                using (var xr = XmlReader.Create(sr))
                    window = (Window)XamlReader.Load(xr);
            }
            else throw new Exception();
        }
        catch
        {
            window = new Window
            {
                Title = "\u53cd\u626b\u76d8 \u00b7 \u8bbe\u7f6e",
                Width = 500, Height = 380,
                WindowStartupLocation = WindowStartupLocation.CenterScreen,
                ResizeMode = ResizeMode.CanMinimize,
                Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F5F6FA")),
                FontFamily = new FontFamily("Microsoft YaHei UI")
            };
        }

        // Find controls
        CheckBox chkAutoStart = window.FindName("ChkAutoStart") as CheckBox;
        CheckBox chkShowOverlay = window.FindName("ChkShowOverlay") as CheckBox;
        Button btnAddChar = window.FindName("BtnAddCharacter") as Button;
        Button btnAddReply = window.FindName("BtnAddReply") as Button;
        Button btnSave = window.FindName("BtnSave") as Button;
        BtnStartStop = window.FindName("BtnStartStop") as Button;
        StatusText = window.FindName("StatusText") as TextBlock;

        // Load checkbox state
        if (chkAutoStart != null) chkAutoStart.IsChecked = Settings_AutoStart;
        if (chkShowOverlay != null) chkShowOverlay.IsChecked = Settings_ShowOverlay;

        // Initial button state
        RefreshButtonState();

        // Status refresh timer
        StatusTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        StatusTimer.Tick += (s, e) => RefreshButtonState();
        StatusTimer.Start();

        // ===== Start/Stop =====
        if (BtnStartStop != null)
        {
            BtnStartStop.Click += (s, e) =>
            {
                bool running = IsServiceRunning();
                if (running) DoStopAll();
                else DoStartAll();
            };
        }

        // ===== Add Character =====
        if (btnAddChar != null)
        {
            btnAddChar.Click += (s, e) =>
            {
                var fd = new Microsoft.Win32.OpenFileDialog
                {
                    Title = "\u9009\u62e9\u89d2\u8272\u56fe\u7247",
                    Filter = "\u56fe\u7247\u6587\u4ef6|*.png;*.jpg;*.jpeg;*.gif;*.bmp|\u6240\u6709\u6587\u4ef6|*.*",
                    Multiselect = false
                };
                if (fd.ShowDialog() != true) return;

                // Name dialog
                var nd = new Window
                {
                    Title = "\u547d\u540d\u89d2\u8272", Width = 350, Height = 180,
                    WindowStartupLocation = WindowStartupLocation.CenterOwner,
                    Owner = window, ResizeMode = ResizeMode.NoResize,
                    Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F5F6FA")),
                    FontFamily = new FontFamily("Microsoft YaHei UI")
                };
                var nsp = new StackPanel { Margin = new Thickness(20, 15, 20, 15) };
                nsp.Children.Add(new TextBlock { Text = "\u8f93\u5165\u89d2\u8272\u540d\u79f0\uff1a", FontSize = 13, Margin = new Thickness(0, 0, 0, 8) });
                var ntb = new TextBox { FontSize = 13, Height = 28, Margin = new Thickness(0, 0, 0, 12) };
                nsp.Children.Add(ntb);
                var nbp = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
                var nbc = new Button { Content = "\u53d6\u6d88", Width = 60, Height = 30, Margin = new Thickness(0, 0, 8, 0) };
                nbc.Click += (s2, e2) => { nd.DialogResult = false; nd.Close(); };
                var nbok = new Button { Content = "\u786e\u5b9a", Width = 60, Height = 30 };
                nbok.Click += (s2, e2) => { nd.DialogResult = true; nd.Close(); };
                nbp.Children.Add(nbc); nbp.Children.Add(nbok); nsp.Children.Add(nbp);
                nd.Content = nsp;

                if (nd.ShowDialog() == true && !string.IsNullOrWhiteSpace(ntb.Text))
                {
                    string cn = ntb.Text.Trim();
                    string ext = Path.GetExtension(fd.FileName);
                    string safeBase = string.Join("_", cn.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries));
                    if (string.IsNullOrWhiteSpace(safeBase)) safeBase = "character";
                    safeBase = safeBase.Replace(" ", "_");
                    if (!Directory.Exists(CharactersDir)) Directory.CreateDirectory(CharactersDir);
                    string safe = safeBase + ext;
                    string dest = Path.Combine(CharactersDir, safe);
                    int suffix = 1;
                    while (File.Exists(dest))
                    {
                        safe = safeBase + "_" + suffix + ext;
                        dest = Path.Combine(CharactersDir, safe);
                        suffix++;
                    }
                    try
                    {
                        File.Copy(fd.FileName, dest, true);
                        // Update characterNames
                        UpdateUiJson("characterNames", safe, cn);
                        SetStatus("\u5df2\u6dfb\u52a0\u89d2\u8272\uff1a" + cn);
                    }
                    catch (Exception ex) { SetStatus("\u6dfb\u52a0\u5931\u8d25\uff1a" + ex.Message); }
                }
            };
        }

        // ===== Add Reply (per-character) =====
        if (btnAddReply != null)
        {
            btnAddReply.Click += (s, e) =>
            {
                // Load characters
                var chars = new List<Tuple<string, string>>();
                var names = LoadUiJsonDict("characterNames");
                if (Directory.Exists(CharactersDir))
                {
                    foreach (var f in Directory.GetFiles(CharactersDir))
                    {
                        string ext = Path.GetExtension(f).ToLower();
                        if (ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".gif" || ext == ".bmp")
                        {
                            string fn = Path.GetFileName(f);
                            string display = names.ContainsKey(fn) ? names[fn] : Path.GetFileNameWithoutExtension(fn);
                            chars.Add(new Tuple<string, string>(fn, display));
                        }
                    }
                }
                if (chars.Count == 0) { SetStatus("\u8bf7\u5148\u6dfb\u52a0\u89d2\u8272\u56fe\u7247"); return; }

                // Select character
                var sd = new Window
                {
                    Title = "\u9009\u62e9\u89d2\u8272", Width = 350, Height = 320,
                    WindowStartupLocation = WindowStartupLocation.CenterOwner,
                    Owner = window, ResizeMode = ResizeMode.NoResize,
                    Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F5F6FA")),
                    FontFamily = new FontFamily("Microsoft YaHei UI")
                };
                var ssp = new StackPanel { Margin = new Thickness(20, 15, 20, 15) };
                ssp.Children.Add(new TextBlock { Text = "\u9009\u62e9\u8981\u8bbe\u7f6e\u53f0\u8bcd\u7684\u89d2\u8272\uff1a", FontSize = 13, Margin = new Thickness(0, 0, 0, 10) });
                var lb = new ListBox { FontSize = 13, Height = 180, Margin = new Thickness(0, 0, 0, 12) };
                foreach (var ch in chars) lb.Items.Add(ch.Item2);
                lb.SelectedIndex = 0;
                ssp.Children.Add(lb);
                var sbp = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
                var sbc = new Button { Content = "\u53d6\u6d88", Width = 60, Height = 30, Margin = new Thickness(0, 0, 8, 0) };
                sbc.Click += (s2, e2) => { sd.DialogResult = false; sd.Close(); };
                var sbok = new Button { Content = "\u4e0b\u4e00\u6b65", Width = 60, Height = 30 };
                string selFile = null;
                sbok.Click += (s2, e2) =>
                {
                    if (lb.SelectedIndex >= 0 && lb.SelectedIndex < chars.Count)
                    { selFile = chars[lb.SelectedIndex].Item1; sd.DialogResult = true; }
                    sd.Close();
                };
                sbp.Children.Add(sbc); sbp.Children.Add(sbok); ssp.Children.Add(sbp);
                sd.Content = ssp;

                if (sd.ShowDialog() != true || selFile == null) return;

                // Load existing lines
                var allLines = new Dictionary<string, object>();
                try
                {
                    if (File.Exists(OverlayUiFile))
                    {
                        string uiJson = File.ReadAllText(OverlayUiFile, Encoding.UTF8).TrimStart('\uFEFF');
                        var uiDict = Json.Deserialize<Dictionary<string, object>>(uiJson);
                        if (uiDict != null && uiDict.ContainsKey("characterLines"))
                        {
                            allLines = Json.Deserialize<Dictionary<string, object>>(Json.Serialize(uiDict["characterLines"]))
                                ?? new Dictionary<string, object>();
                        }
                    }
                }
                catch { }
                string existing = "";
                if (allLines.ContainsKey(selFile))
                {
                    try
                    {
                        var arr = Json.Deserialize<object[]>(Json.Serialize(allLines[selFile]));
                        if (arr != null) existing = string.Join("\r\n", arr.Where(o => o != null).Select(o => o.ToString()));
                    }
                    catch { }
                }

                // Edit dialog
                var ed = new Window
                {
                    Title = "\u8bbe\u7f6e\u53f0\u8bcd - " + selFile, Width = 400, Height = 320,
                    WindowStartupLocation = WindowStartupLocation.CenterOwner,
                    Owner = window, ResizeMode = ResizeMode.NoResize,
                    Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F5F6FA")),
                    FontFamily = new FontFamily("Microsoft YaHei UI")
                };
                var esp = new StackPanel { Margin = new Thickness(20, 15, 20, 15) };
                esp.Children.Add(new TextBlock { Text = "\u6bcf\u884c\u4e00\u53e5\u53f0\u8bcd\uff0c\u70b9\u51fb\u60ac\u6d6e\u7a97\u65f6\u968f\u673a\u663e\u793a\uff1a", FontSize = 12, Foreground = new SolidColorBrush(Colors.Gray), Margin = new Thickness(0, 0, 0, 8) });
                var etb = new TextBox { FontSize = 13, Height = 140, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 0, 0, 12), Text = existing };
                esp.Children.Add(etb);
                var ebp = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
                var ebc = new Button { Content = "\u53d6\u6d88", Width = 60, Height = 30, Margin = new Thickness(0, 0, 8, 0) };
                ebc.Click += (s2, e2) => { ed.DialogResult = false; ed.Close(); };
                var ebok = new Button { Content = "\u4fdd\u5b58", Width = 60, Height = 30 };
                ebok.Click += (s2, e2) => { ed.DialogResult = true; ed.Close(); };
                ebp.Children.Add(ebc); ebp.Children.Add(ebok); esp.Children.Add(ebp);
                ed.Content = esp;

                if (ed.ShowDialog() == true)
                {
                    string text = etb.Text.Trim();
                    try
                    {
                        var lines = text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
                        UpdateUiJson("characterLines", selFile, lines);
                        SetStatus("\u5df2\u4fdd\u5b58\u53f0\u8bcd\uff0c\u5207\u6362\u89d2\u8272\u540e\u751f\u6548");
                    }
                    catch { SetStatus("\u4fdd\u5b58\u5931\u8d25"); }
                }
            };
        }

        // ===== Save =====
        if (btnSave != null)
        {
            btnSave.Click += (s, e) =>
            {
                Settings_AutoStart = chkAutoStart != null && chkAutoStart.IsChecked == true;
                Settings_ShowOverlay = chkShowOverlay != null && chkShowOverlay.IsChecked == true;
                Settings_FirstRun = true;
                SaveAllSettings();

                // Handle auto-start toggle
                try
                {
                    string script = Settings_AutoStart ? InstallScript : UninstallScript;
                    var p = Process.Start(new ProcessStartInfo
                    {
                        FileName = "powershell.exe",
                        Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"",
                        Verb = "RunAs",
                        WindowStyle = ProcessWindowStyle.Hidden,
                        CreateNoWindow = true
                    });
                    if (p != null) p.WaitForExit(5000);
                }
                catch { }

                SetStatus(Settings_AutoStart ? "\u5df2\u542f\u7528\u5f00\u673a\u81ea\u542f\u52a8" : "\u5df2\u5173\u95ed\u5f00\u673a\u81ea\u542f\u52a8");
            };
        }

        window.Closed += (s, e) =>
        {
            if (StatusTimer != null) { StatusTimer.Stop(); StatusTimer = null; }
            BtnStartStop = null;
            StatusText = null;
            SettingsWindow = null;
        };

        SettingsWindow = window;
        window.Show();
        window.Activate();
    }

    static void ReloadCheckboxes()
    {
        if (SettingsWindow == null) return;
        var ca = SettingsWindow.FindName("ChkAutoStart") as CheckBox;
        var co = SettingsWindow.FindName("ChkShowOverlay") as CheckBox;
        if (ca != null) ca.IsChecked = Settings_AutoStart;
        if (co != null) co.IsChecked = Settings_ShowOverlay;
        RefreshButtonState();
    }

    static void SetStatus(string msg)
    {
        if (StatusText != null)
        {
            StatusText.Dispatcher.Invoke(new Action(() => StatusText.Text = msg));
        }
    }

    // ==================== UI Helpers ====================

    static void UpdateUiJson(string section, string key, object value)
    {
        try
        {
            if (!File.Exists(OverlayUiFile)) return;
            string json = File.ReadAllText(OverlayUiFile, Encoding.UTF8).TrimStart('\uFEFF');
            var dict = Json.Deserialize<Dictionary<string, object>>(json);
            if (dict == null) return;
            var subDict = dict.ContainsKey(section)
                ? Json.Deserialize<Dictionary<string, object>>(Json.Serialize(dict[section]))
                : new Dictionary<string, object>();
            if (subDict == null) subDict = new Dictionary<string, object>();
            subDict[key] = value;
            dict[section] = subDict;
            File.WriteAllText(OverlayUiFile, Json.Serialize(dict), Encoding.UTF8);
        }
        catch { }
    }

    static Dictionary<string, string> LoadUiJsonDict(string section)
    {
        var result = new Dictionary<string, string>();
        try
        {
            if (!File.Exists(OverlayUiFile)) return result;
            string json = File.ReadAllText(OverlayUiFile, Encoding.UTF8).TrimStart('\uFEFF');
            var dict = Json.Deserialize<Dictionary<string, object>>(json);
            if (dict == null || !dict.ContainsKey(section)) return result;
            var sub = Json.Deserialize<Dictionary<string, object>>(Json.Serialize(dict[section]));
            if (sub != null) foreach (var kv in sub) result[kv.Key] = kv.Value != null ? kv.Value.ToString() : "";
        }
        catch { }
        return result;
    }

    static T FindCtrl<T>(DependencyObject parent, string name) where T : DependencyObject
    {
        if (parent == null) return null;
        var fe = parent as FrameworkElement;
        if (fe != null && fe.Name == name) return parent as T;
        int count = VisualTreeHelper.GetChildrenCount(parent);
        for (int i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            var result = FindCtrl<T>(child, name);
            if (result != null) return result;
        }
        return null;
    }
}
