using System;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace Locman7
{
    static class Program
    {
        /// <summary>Сообщение «покажи окно» для уже запущенной копии.</summary>
        public static readonly int ShowMessage = RegisterWindowMessage("Locman7.Show");

        [STAThread]
        static void Main(string[] args)
        {
            bool first;
            using (var mutex = new Mutex(true, "Locman7.Single", out first))
            {
                if (!first)
                {
                    PostMessage((IntPtr)0xffff, ShowMessage, IntPtr.Zero, IntPtr.Zero); // HWND_BROADCAST
                    return;
                }
                // Windows 7 по умолчанию договаривается о старом TLS — включаем TLS 1.2 явно.
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | (SecurityProtocolType)12288; // + TLS 1.3, где есть
                ServicePointManager.DefaultConnectionLimit = 256;
                ServicePointManager.Expect100Continue = false;
                System.Windows.Forms.Application.EnableVisualStyles();
                System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);
                var settings = Settings.Load();
                var hidden = Array.IndexOf(args, "--tray") >= 0 || settings.StartMinimized;
                System.Windows.Forms.Application.Run(new MainForm(hidden));
            }
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int RegisterWindowMessage(string name);

        [DllImport("user32.dll")]
        static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr w, IntPtr l);
    }
}
