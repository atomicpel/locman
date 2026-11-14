using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace Locman7
{
    /// <summary>Запуск: Locman7.Tests.exe [папка] — пишет туда конфиги ядра для проверки «xray run -test».</summary>
    static class Tests
    {
        static int _fails, _ok;

        static void Check(bool cond, string what)
        {
            if (cond) { _ok++; return; }
            _fails++;
            Console.WriteLine("ОШИБКА: " + what);
        }

        const string Reality = "vless://11111111-2222-3333-4444-555555555555@95.163.1.2:443?security=reality&sni=ok.ru&pbk=BaYoB6tN_3kSOGsv3p-ylsk2fpONXdqRa2DjgDBJMi8&sid=12&fp=chrome&type=tcp&flow=xtls-rprx-vision#%D0%9C%D0%BE%D1%81%D0%BA%D0%B2%D0%B0";
        const string Xhttp = "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?security=tls&sni=a.com&type=xhttp&path=%2Fx&mode=auto#X";
        const string Ws = "vless://11111111-2222-3333-4444-555555555555@1.2.3.5:443?security=tls&sni=a.com&type=ws&path=%2Fw&host=a.com#WS";
        const string Trojan = "trojan://pw@5.6.7.8:443?security=tls&sni=b.com&type=grpc&serviceName=g#T";
        const string Hy2 = "hysteria2://secret@9.9.9.9:443?sni=h.com&obfs=salamander&obfs-password=pp#H";

        static int Main(string[] args)
        {
            var dir = args.Length > 0 ? args[0] : ".";
            Directory.CreateDirectory(dir);

            // Разбор ссылок
            var r = LinkParser.Parse(Reality, "s");
            Check(r != null && r.Name == "Москва" && r.Security == "reality" && r.Get("pbk") == "BaYoB6tN_3kSOGsv3p-ylsk2fpONXdqRa2DjgDBJMi8", "VLESS Reality");
            Check(r != null && r.SecurityIssue == null && r.Label == "VLESS Reality", "Reality безопасен");
            var vm = "vmess://" + Convert.ToBase64String(Encoding.UTF8.GetBytes(
                "{\"add\":\"1.2.3.4\",\"port\":\"443\",\"id\":\"11111111-2222-3333-4444-555555555555\",\"net\":\"ws\",\"tls\":\"tls\",\"ps\":\"Рига\"}"));
            var v = LinkParser.Parse(vm, "s");
            Check(v != null && v.Name == "Рига" && v.Transport == "ws", "VMess");
            var ss = LinkParser.Parse("ss://" + Convert.ToBase64String(Encoding.UTF8.GetBytes("aes-256-gcm:pw")) + "@1.2.3.4:8388#S", "s");
            Check(ss != null && ss.Get("method") == "aes-256-gcm" && ss.SecurityIssue == null, "Shadowsocks");
            Check(LinkParser.Parse("ss://" + Convert.ToBase64String(Encoding.UTF8.GetBytes("rc4-md5:pw")) + "@1.2.3.4:8388#S", "s") == null,
                "устаревшее шифрование SS не добавляется");
            Check(LinkParser.Parse("vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?security=reality&sni=a.ru#nokey", "s") == null,
                "Reality без ключа не добавляется");
            Check(LinkParser.Parse("vless://id@1.2.3.4:443?security=none#x", "s")?.SecurityIssue == "без шифрования", "VLESS без шифрования");
            Check(LinkParser.Parse("trojan://pw@1.2.3.4:443?security=tls&allowInsecure=1#x", "s")?.SecurityIssue != null, "без проверки сертификата");
            var h = LinkParser.Parse(Hy2, "s");
            Check(h != null && h.Protocol == Proto.Hysteria2 && h.Get("obfs-password") == "pp", "Hysteria2");

            // Подписки: base64 и веб-страница с ключами
            var b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(Reality + "\n" + Trojan + "\n" + Reality));
            Check(Subscription.Parse(b64, "s").Count == 2, "подписка base64 без повторов");
            var html = "<!DOCTYPE html><html><body><div>ключ:<br/><code>" + Trojan.Replace("&", "&amp;") + "</code></div></body></html>";
            Check(Subscription.Parse(html, "s").Count == 1, "ключи со страницы");

            // Бережные пачки: в одной пачке нет двух узлов с тем же SNI и подсетью
            var same = Enumerable.Range(1, 6).Select(i => LinkParser.Parse(
                "vless://11111111-2222-3333-4444-55555555555" + i + "@45.0.0." + i + ":443?security=reality&sni=ok.ru&pbk=BaYoB6tN_3kSOGsv3p-ylsk2fpONXdqRa2DjgDBJMi8#n" + i, "s")).ToList();
            var batches = Engine.GentleBatches(same, 20);
            Check(batches.All(b => b.Select(n => n.GentleKey).Distinct().Count() == b.Count), "в пачке разные SNI+подсеть");
            Check(batches.Count == 6, "шесть узлов одного SNI и подсети — шесть пачек");
            var mixed = new[] { Reality, Xhttp, Trojan, Hy2 }.Select(l => LinkParser.Parse(l, "s")).ToList();
            Check(Engine.GentleBatches(mixed, 20).Count == 1, "разные серверы — одна пачка");

            // Маршруты TUN
            var routes = Routes.PublicIpv4();
            Check(routes.Count == 51 && routes[0] == "1.0.0.0/8" && !routes.Any(x => x.StartsWith("10.") || x.StartsWith("192.168.")),
                "маршруты TUN без локальной сети");

            // Ссылка «Поделиться» с телефона
            Check(Share.Unpack("текст locman://import?data=H4sIAGS89moC_yvLSS0uttLXL3XIsDIxMVauAAA0kApCEQAAAA конец")
                .SequenceEqual(new[] { "vless://u@h:443#x" }), "ссылка «Поделиться» с телефона");

            // Резервная копия: туда и обратно
            var s1 = new Settings();
            s1.Mine.Add(new Source { Id = "mine-1", Title = "ключи", Keys = Reality, Mine = true });
            s1.Mine.Add(new Source { Id = "mine-2", Title = "sub", Mirrors = new[] { "https://example.com/s" }, Mine = true });
            var copy = Backup.Make(s1);
            var s2 = new Settings();
            Check(Backup.Restore(s2, copy) == 2 && s2.Mine.Any(m => m.Keys == Reality), "резервная копия");

            // Конфиги ядра — проверит xray.exe run -test
            var nodes = new[] { Reality, Xhttp, Ws, Trojan, Hy2, vm }.Select(l => LinkParser.Parse(l, "s")).ToList();
            Check(nodes.All(n => n != null), "все узлы для конфигов разобрались");
            File.WriteAllText(Path.Combine(dir, "batch.json"), XrayConfig.Batch(nodes, nodes.Select((_, i) => 20000 + i).ToList()));
            File.WriteAllText(Path.Combine(dir, "connect.json"), XrayConfig.Connect(nodes[0], 10808, 10809, true, false, 10810));
            File.WriteAllText(Path.Combine(dir, "tun.json"), XrayConfig.Connect(nodes[1], 10808, 10809, true, true, 10810));

            Console.WriteLine($"Проверок: {_ok + _fails}, ошибок: {_fails}");
            return _fails == 0 ? 0 : 1;
        }
    }
}
