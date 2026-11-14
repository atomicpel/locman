using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Locman7
{
    /// <summary>JSON без сторонних библиотек (System.Web.Extensions есть в .NET Framework 4.8).</summary>
    static class Json
    {
        static readonly JavaScriptSerializer S = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 256 };

        public static object Parse(string s) => S.DeserializeObject(s);

        public static string Write(object o) => S.Serialize(o);

        public static string Str(object map, string key)
        {
            var d = map as Dictionary<string, object>;
            return d != null && d.TryGetValue(key, out var v) && v != null ? v.ToString() : "";
        }
    }

    enum Proto { Vless, Vmess, Trojan, Shadowsocks, Hysteria2 }

    /// <summary>Узел из подписки (порт Dart-класса ProxyNode, только ссылочные форматы).</summary>
    sealed class Node
    {
        public Proto Protocol;
        public string Name = "", Address = "", Secret = "", Raw = "", SourceId = "";
        public int Port;
        public Dictionary<string, string> P = new Dictionary<string, string>(StringComparer.Ordinal);

        public string Get(string key) => P.TryGetValue(key, out var v) && v != null ? v : "";
        public string Nb(string key) { var v = Get(key).Trim(); return v.Length == 0 ? null : v; }

        public string Security => Get("security").ToLowerInvariant();
        public string Transport { get { var t = Get("type").ToLowerInvariant(); return t.Length == 0 ? "tcp" : t; } }

        string _id;
        public string Id => _id ?? (_id = Util.StableId(Raw.Split('#')[0]));

        /// <summary>Один и тот же сервер в разных подписках — один узел.</summary>
        public string EndpointKey => $"{Protocol}|{Address.ToLowerInvariant()}:{Port}|{Secret}";

        /// <summary>Имя, которое видит фильтр в рукопожатии (SNI).</summary>
        public string SniKey => (Nb("sni") ?? Nb("peer") ?? Nb("host") ?? Address).ToLowerInvariant();

        /// <summary>Подсеть сервера: /24 для IPv4, иначе сам адрес.</summary>
        public string Subnet
        {
            get
            {
                var a = Address.ToLowerInvariant();
                return Regex.IsMatch(a, @"^\d+\.\d+\.\d+\.\d+$") ? a.Substring(0, a.LastIndexOf('.')) : a;
            }
        }

        /// <summary>Узлы с одинаковым ключом нельзя проверять одновременно: фильтр замораживает
        /// узел, к которому почти разом открывается много TLS-соединений с одним SNI.</summary>
        public string GentleKey => SniKey + "@" + Subnet;

        public string Label
        {
            get
            {
                if (Protocol == Proto.Hysteria2) return "Hysteria2";
                if (Protocol == Proto.Shadowsocks) return "Shadowsocks";
                string t;
                if (Security == "reality") t = "Reality";
                else if (Transport == "xhttp" || Transport == "splithttp") t = "XHTTP";
                else if (Transport == "ws") t = "WS";
                else if (Transport == "grpc") t = "gRPC";
                else if (Transport == "httpupgrade") t = "HTTPUpgrade";
                else t = Security == "tls" ? "TLS" : "TCP";
                return (Protocol == Proto.Vless ? "VLESS " : Protocol == Proto.Vmess ? "VMess " : "Trojan ") + t;
            }
        }

        static readonly HashSet<string> Aead = new HashSet<string> {
            "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305",
            "xchacha20-poly1305", "xchacha20-ietf-poly1305",
        };
        static readonly Regex VlessEnc = new Regex(@"^mlkem768x25519plus\.(native|xorpub|random)\.(0rtt|1rtt)(\.[A-Za-z0-9_=-]+)+$");

        /// <summary>Почему узел небезопасен (null — всё в порядке). Такие узлы «Лоцман» не использует.</summary>
        public string SecurityIssue
        {
            get
            {
                if (Get("allowInsecure") == "1" || Get("insecure") == "1") return "без проверки сертификата";
                switch (Protocol)
                {
                    case Proto.Vless:
                        if (Security.Length == 0 || Security == "none")
                            return VlessEnc.IsMatch(Get("encryption").Trim()) ? null : "без шифрования";
                        break;
                    case Proto.Trojan:
                        if (Security == "none") return "без шифрования";
                        break;
                    case Proto.Vmess:
                        var scy = Get("scy").ToLowerInvariant();
                        if (scy == "none" || scy == "zero") return "без шифрования";
                        break;
                    case Proto.Shadowsocks:
                        var m = Get("method").ToLowerInvariant();
                        if (m.Length == 0 || m == "none" || m == "plain") return "без шифрования";
                        if (!Aead.Contains(m) && !m.StartsWith("2022-blake3-")) return "устаревшее шифрование";
                        break;
                }
                return null;
            }
        }
    }

    static class Util
    {
        public static string StableId(string s)
        {
            using (var sha = SHA1.Create())
            {
                var h = sha.ComputeHash(Encoding.UTF8.GetBytes(s));
                return BitConverter.ToString(h, 0, 8).Replace("-", "").ToLowerInvariant();
            }
        }

        public static string Pct(string s)
        {
            try { return Uri.UnescapeDataString(s); } catch { return s; }
        }

        /// <summary>Терпимое base64: url-safe, без '=' в конце, с переносами строк.</summary>
        public static string DecodeBase64(string s)
        {
            var t = Regex.Replace(s ?? "", @"\s+", "").Replace('-', '+').Replace('_', '/');
            if (t.Length == 0 || !Regex.IsMatch(t, "^[A-Za-z0-9+/=]+$")) return null;
            t = t.TrimEnd('=');
            t += new string('=', (4 - t.Length % 4) % 4);
            try { return Encoding.UTF8.GetString(Convert.FromBase64String(t)); } catch { return null; }
        }
    }

    /// <summary>Разбор ссылок vless://, vmess://, trojan://, ss://, hysteria2:// (как в Dart-версии).</summary>
    static class LinkParser
    {
        public static readonly HashSet<string> SsMethods = new HashSet<string> {
            "aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305", "xchacha20-poly1305",
            "xchacha20-ietf-poly1305", "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
            "2022-blake3-chacha20-poly1305", "none", "plain",
        };

        public static Node Parse(string line, string sourceId)
        {
            var raw = (line ?? "").Trim();
            var sep = raw.IndexOf("://", StringComparison.Ordinal);
            if (sep <= 0) return null;
            var scheme = raw.Substring(0, sep).ToLowerInvariant();
            Node n;
            try
            {
                switch (scheme)
                {
                    case "vless": n = UriStyle(raw, Proto.Vless); break;
                    case "trojan": n = UriStyle(raw, Proto.Trojan); break;
                    case "hysteria2": case "hy2": n = UriStyle(raw, Proto.Hysteria2); break;
                    case "vmess": n = Vmess(raw); break;
                    case "ss": n = Shadowsocks(raw); break;
                    default: return null;
                }
            }
            catch { return null; }
            if (n == null || Problem(n) != null) return null;
            n.SourceId = sourceId;
            return n;
        }

        /// <summary>Узел, который ядро не поднимет.</summary>
        public static string Problem(Node n)
        {
            if (n.Security == "reality" && n.Get("pbk").Trim().Length == 0) return "Reality без ключа";
            if (n.Protocol == Proto.Shadowsocks && !SsMethods.Contains(n.Get("method").Trim().ToLowerInvariant())) return "шифрование SS";
            if ((n.Protocol == Proto.Vless || n.Protocol == Proto.Vmess) && n.Secret.Trim().Length == 0) return "нет UUID";
            var a = n.Address;
            if (a == "0.0.0.0" || a.StartsWith("127.") || a.StartsWith("10.") || a.StartsWith("192.168.")) return "локальный адрес";
            return null;
        }

        static (string, string) SplitOnce(string s, char c)
        {
            var i = s.IndexOf(c);
            return i < 0 ? (s, "") : (s.Substring(0, i), s.Substring(i + 1));
        }

        static Node UriStyle(string raw, Proto proto)
        {
            var body = raw.Substring(raw.IndexOf("://", StringComparison.Ordinal) + 3);
            var (beforeFragment, fragment) = SplitOnce(body, '#');
            var (beforeQuery, query) = SplitOnce(beforeFragment, '?');
            var at = beforeQuery.LastIndexOf('@');
            if (at <= 0) return null;
            var secret = Util.Pct(beforeQuery.Substring(0, at));
            var authority = beforeQuery.Substring(at + 1).TrimEnd('/');
            string hop = null;
            if (proto == Proto.Hysteria2)
            {
                var colon = authority.LastIndexOf(':');
                if (colon < 0 || authority.EndsWith("]")) authority += ":443";
                else
                {
                    var ports = authority.Substring(colon + 1);
                    if (!Regex.IsMatch(ports, @"^\d+$"))
                    {
                        hop = ports;
                        authority = authority.Substring(0, colon + 1) + ports.Split(',')[0].Split('-')[0];
                    }
                }
            }
            if (!HostPort(authority, out var host, out var port)) return null;
            var n = new Node { Protocol = proto, Address = host, Port = port, Secret = secret, Raw = raw };
            foreach (var pair in query.Split('&'))
            {
                if (pair.Trim().Length == 0) continue;
                var eq = pair.IndexOf('=');
                var k = Util.Pct(eq < 0 ? pair : pair.Substring(0, eq));
                var v = eq < 0 ? "" : Util.Pct(pair.Substring(eq + 1));
                if (k.Trim().Length > 0) n.P[k] = v;
            }
            if (hop != null && !n.P.ContainsKey("mport")) n.P["mport"] = hop;
            n.Name = DisplayName(fragment, host, port);
            return n;
        }

        static Node Vmess(string raw)
        {
            var body = raw.Substring(raw.IndexOf("://", StringComparison.Ordinal) + 3);
            var (encoded, fragment) = SplitOnce(body, '#');
            var payload = Util.DecodeBase64(encoded);
            if (payload == null) return null;
            if (!(Json.Parse(payload) is Dictionary<string, object> obj)) return null;
            Func<string, string> S = k => { object v; return obj.TryGetValue(k, out v) && v != null ? v.ToString().Trim() : ""; };
            var host = S("add");
            int port;
            if (!int.TryParse(S("port"), out port) || host.Length == 0 || S("id").Length == 0 || port < 1 || port > 65535) return null;
            var tls = S("tls").ToLowerInvariant();
            var n = new Node { Protocol = Proto.Vmess, Address = host, Port = port, Secret = S("id"), Raw = raw };
            n.P["type"] = S("net").Length == 0 ? "tcp" : S("net");
            n.P["security"] = tls == "tls" || tls == "reality" ? tls : "none";
            var keys = new[] { "headerType", "type", "host", "host", "path", "path", "sni", "sni", "alpn", "alpn", "fp", "fp", "aid", "aid", "scy", "scy" };
            for (var i = 0; i < keys.Length; i += 2)
            {
                var v = S(keys[i + 1]);
                if (v.Length > 0 && v != "none") n.P[keys[i]] = v;
            }
            var name = S("ps");
            if (name.Contains("%")) name = Util.Pct(name);
            if (name.Length == 0) name = Util.Pct(fragment).Trim();
            if (name.Length == 0) name = S("remark");
            n.Name = name.Length == 0 ? $"{host}:{port}" : name;
            return n;
        }

        static Node Shadowsocks(string raw)
        {
            var (beforeFragment, fragment) = SplitOnce(raw.Substring(raw.IndexOf("://", StringComparison.Ordinal) + 3), '#');
            var main = beforeFragment.Split('?')[0].TrimEnd('/');
            var at = main.LastIndexOf('@');
            string credentials, hostPort;
            if (at > 0)
            {
                var userInfo = main.Substring(0, at);
                var decoded = Util.DecodeBase64(userInfo);
                credentials = decoded != null && decoded.Contains(":") ? decoded : Util.Pct(userInfo);
                hostPort = main.Substring(at + 1);
            }
            else
            {
                var decoded = Util.DecodeBase64(main);
                if (decoded == null) return null;
                var a = decoded.LastIndexOf('@');
                if (a <= 0) return null;
                credentials = decoded.Substring(0, a);
                hostPort = decoded.Substring(a + 1);
            }
            var colon = credentials.IndexOf(':');
            if (colon < 0 || !HostPort(hostPort, out var host, out var port)) return null;
            var n = new Node
            {
                Protocol = Proto.Shadowsocks, Address = host, Port = port, Secret = credentials.Substring(colon + 1), Raw = raw,
            };
            n.P["method"] = credentials.Substring(0, colon);
            n.Name = DisplayName(fragment, host, port);
            return n;
        }

        static bool HostPort(string s, out string host, out int port)
        {
            host = null;
            port = 0;
            string portStr;
            if (s.StartsWith("["))
            {
                var end = s.IndexOf(']');
                if (end < 0) return false;
                host = s.Substring(1, end - 1);
                portStr = s.Substring(end + 1).TrimStart(':');
            }
            else
            {
                var colon = s.LastIndexOf(':');
                if (colon < 0) return false;
                host = s.Substring(0, colon);
                portStr = s.Substring(colon + 1);
            }
            return host.Trim().Length > 0 && int.TryParse(portStr, out port) && port >= 1 && port <= 65535;
        }

        static string DisplayName(string fragment, string host, int port)
        {
            var spaced = fragment.Contains(" ") || fragment.Contains("%20") ? fragment : fragment.Replace('+', ' ');
            var name = Regex.Replace(Util.Pct(spaced), @"\s+", " ").Trim();
            return name.Length == 0 ? $"{host}:{port}" : name;
        }
    }

    /// <summary>Подписка: список ссылок, base64 или веб-страница с ключами.</summary>
    static class Subscription
    {
        static readonly Regex KeyInText = new Regex(@"(?:vless|vmess|trojan|ss|hysteria2|hy2)://[^\s""'<>]+", RegexOptions.IgnoreCase);

        public static List<Node> Parse(string body, string sourceId)
        {
            var text = (body ?? "").Trim().TrimStart('﻿');
            if (text.StartsWith("<") && text.Substring(0, Math.Min(300, text.Length)).ToLowerInvariant().Contains("<html"))
            {
                var plain = Regex.Replace(text, @"<br\s*/?>", "\n", RegexOptions.IgnoreCase);
                plain = Regex.Replace(plain, "<[^>]+>", " ").Replace("&amp;", "&").Replace("&quot;", "\"").Replace("&#39;", "'");
                text = string.Join("\n", KeyInText.Matches(plain).Cast<Match>().Select(m => m.Value.TrimEnd('.', ',', ';', ')', ']')));
            }
            if (!text.Contains("://"))
            {
                var decoded = Util.DecodeBase64(text);
                if (decoded != null && decoded.Contains("://")) text = decoded;
            }
            var seen = new HashSet<string>();
            var list = new List<Node>();
            foreach (var raw in Regex.Split(text, @"\r?\n"))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                var n = LinkParser.Parse(line, sourceId);
                if (n != null && seen.Add(n.Id)) list.Add(n);
            }
            return list;
        }
    }
}
