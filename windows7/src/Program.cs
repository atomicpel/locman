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
            var restarted = Array.IndexOf(args, "--restarted") >= 0;
            var mutex = new Mutex(true, "Locman7.Single", out first);
            // Перезапуск с правами администратора: ждём, пока старая копия закроется.
            for (var i = 0; !first && restarted && i < 50; i++)
            {
                Thread.Sleep(200);
                try { first = mutex.WaitOne(0); } catch (AbandonedMutexException) { first = true; }
            }
            using (mutex)
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
                if (settings.Theme == "light") Theme.Light();
                var hidden = Array.IndexOf(args, "--tray") >= 0 || settings.StartMinimized;
                var form = new MainForm(hidden && !restarted, Array.IndexOf(args, "--connect") >= 0);
                form._mutexRelease = () => { try { mutex.ReleaseMutex(); } catch { } };
                System.Windows.Forms.Application.Run(form);
            }
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int RegisterWindowMessage(string name);

        [DllImport("user32.dll")]
        static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr w, IntPtr l);
    }
}
