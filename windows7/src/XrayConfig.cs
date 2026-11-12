using System;
using System.Collections.Generic;
using System.Linq;

namespace Locman7
{
    /// <summary>Конфиг Xray: выход на узел (как в Dart-версии) и два вида целиком —
    /// для подключения и для пакетной проверки многих узлов одним процессом.</summary>
    static class XrayConfig
    {
        static Dictionary<string, object> D(params object[] kv)
        {
            var d = new Dictionary<string, object>();
            for (var i = 0; i < kv.Length; i += 2)
                if (kv[i + 1] != null) d[(string)kv[i]] = kv[i + 1];
            return d;
        }

        public static Dictionary<string, object> Outbound(Node n, string tag)
        {
            object settings;
            string protocol;
            switch (n.Protocol)
            {
                case Proto.Vless:
                    protocol = "vless";
                    settings = D("vnext", new object[] { D("address", n.Address, "port", n.Port, "users", new object[] {
                        D("id", n.Secret, "encryption", n.Nb("encryption") ?? "none", "flow", n.Nb("flow")) }) });
                    break;
                case Proto.Vmess:
                    protocol = "vmess";
                    int aid;
                    int.TryParse(n.Get("aid"), out aid);
                    settings = D("vnext", new object[] { D("address", n.Address, "port", n.Port, "users", new object[] {
                        D("id", n.Secret, "alterId", aid, "security", n.Nb("scy") ?? "auto") }) });
                    break;
                case Proto.Trojan:
                    protocol = "trojan";
                    settings = D("servers", new object[] { D("address", n.Address, "port", n.Port, "password", n.Secret) });
                    break;
                case Proto.Shadowsocks:
                    return D("tag", tag, "protocol", "shadowsocks",
                        "settings", D("servers", new object[] { D("address", n.Address, "port", n.Port, "method", n.Get("method"), "password", n.Secret) }),
                        "streamSettings", D("network", "tcp"));
                default:
                    protocol = "hysteria";
                    settings = D("version", 2, "address", n.Address, "port", n.Port);
                    break;
            }
            return D("tag", tag, "protocol", protocol, "settings", settings, "streamSettings", Stream(n));
        }

        static Dictionary<string, object> Stream(Node n)
        {
            var hysteria = n.Protocol == Proto.Hysteria2;
            var network = hysteria ? "hysteria" : n.Transport;
            var security = hysteria ? "tls" : n.Security.Length > 0 ? n.Security : (n.Protocol == Proto.Trojan ? "tls" : "none");
            var sni = n.Nb("sni") ?? n.Nb("peer") ?? n.Nb("host");
            var path = n.Nb("path");
            var host = n.Nb("host");
            var s = D("network", network, "security", security);
            if (security == "tls")
            {
                var alpn = n.Nb("alpn") ?? (hysteria ? "h3" : null);
                s["tlsSettings"] = D("serverName", sni,
                    "fingerprint", hysteria ? null : n.Nb("fp") ?? "chrome",
                    "alpn", alpn?.Split(',').Select(x => (object)x.Trim()).ToArray(),
                    "pinnedPeerCertSha256", n.Nb("pcs") ?? n.Nb("pinSHA256"));
            }
            else if (security == "reality")
            {
                s["realitySettings"] = D("serverName", sni ?? "", "fingerprint", n.Nb("fp") ?? "chrome",
                    "publicKey", n.Get("pbk"), "shortId", n.Get("sid"), "spiderX", n.Nb("spx"), "mldsa65Verify", n.Nb("pqv"));
            }
            switch (network)
            {
                case "hysteria":
                    s["hysteriaSettings"] = D("version", 2, "auth", n.Secret);
                    var obfsType = n.Nb("obfs") ?? "salamander";
                    var obfs = obfsType == "salamander" ? n.Nb("obfs-password") : null;
                    var hop = n.Nb("mport");
                    if (obfs != null || hop != null)
                    {
                        var udp = new List<object>();
                        if (obfs != null) udp.Add(D("type", "salamander", "settings", D("password", obfs)));
                        if (hop != null) udp.Add(D("type", "udphop", "settings", D("mode", "intervallocal,intervalremote", "remotePorts", hop)));
                        s["finalmask"] = D("udp", udp.ToArray());
                    }
                    break;
                case "ws":
                    s["wsSettings"] = D("path", path, "host", host);
                    break;
                case "httpupgrade":
                    s["httpupgradeSettings"] = D("path", path, "host", host);
                    break;
                case "xhttp":
                case "splithttp":
                    object extra = null;
                    if (n.Nb("extra") != null)
                    {
                        try { extra = Json.Parse(n.Get("extra")) as Dictionary<string, object>; } catch { }
                    }
                    s["xhttpSettings"] = D("path", path, "host", host, "mode", n.Nb("mode"), "extra", extra);
                    break;
                case "grpc":
                    s["grpcSettings"] = D("serviceName", n.Nb("serviceName") ?? path ?? "",
                        "multiMode", n.Get("mode") == "multi" ? (object)true : null, "authority", n.Nb("authority"));
                    break;
                case "tcp":
                case "raw":
                    if (n.Get("headerType") == "http")
                    {
                        var hosts = (host ?? "").Split(',').Where(x => x.Trim().Length > 0).Select(x => (object)x.Trim()).ToArray();
                        var request = D("path", new object[] { path ?? "/" }, "headers", D("Host", hosts));
                        s["tcpSettings"] = D("header", D("type", "http", "request", request));
                    }
                    break;
            }
            return s;
        }

        /// <summary>Подключение: локальные входы SOCKS и HTTP только на 127.0.0.1 (их берёт системный прокси).</summary>
        public static string Connect(Node n, int socksPort, int httpPort, bool directRu)
        {
            var rules = new List<object> {
                D("type", "field", "ip", new object[] { "geoip:private" }, "outboundTag", "direct"),
            };
            if (directRu)
            {
                rules.Add(D("type", "field", "domain", new object[] { "domain:ru", "domain:su", "domain:xn--p1ai", "domain:xn--d1acj3b",
                    "domain:yandex.net", "domain:yandex.com", "domain:vk.com", "domain:userapi.com", "domain:mail.ru",
                    "domain:gosuslugi.ru", "domain:sber.ru", "domain:tbank.ru" }, "outboundTag", "direct"));
                rules.Add(D("type", "field", "ip", new object[] { "geoip:ru" }, "outboundTag", "direct"));
            }
            var sniff = D("enabled", true, "destOverride", new object[] { "http", "tls", "quic" }, "routeOnly", true);
            var config = D(
                "log", D("loglevel", "warning"),
                "inbounds", new object[] {
                    D("tag", "socks", "listen", "127.0.0.1", "port", socksPort, "protocol", "socks",
                        "settings", D("auth", "noauth", "udp", true), "sniffing", sniff),
                    D("tag", "http", "listen", "127.0.0.1", "port", httpPort, "protocol", "http", "sniffing", sniff),
                },
                "outbounds", new object[] {
                    Outbound(n, "proxy"),
                    D("tag", "direct", "protocol", "freedom"),
                    D("tag", "block", "protocol", "blackhole"),
                },
                "routing", D("domainStrategy", "AsIs", "rules", rules.ToArray()));
            return Json.Write(config);
        }

        /// <summary>Пакетная проверка: у каждого узла свой HTTP-вход на 127.0.0.1, все — в одном процессе Xray.</summary>
        public static string Batch(IList<Node> nodes, IList<int> ports)
        {
            var inbounds = new List<object>();
            var outbounds = new List<object>();
            var rules = new List<object>();
            for (var i = 0; i < nodes.Count; i++)
            {
                inbounds.Add(D("tag", "in" + i, "listen", "127.0.0.1", "port", ports[i], "protocol", "http"));
                outbounds.Add(Outbound(nodes[i], "out" + i));
                rules.Add(D("type", "field", "inboundTag", new object[] { "in" + i }, "outboundTag", "out" + i));
            }
            outbounds.Add(D("tag", "block", "protocol", "blackhole"));
            return Json.Write(D("log", D("loglevel", "none"), "inbounds", inbounds.ToArray(), "outbounds", outbounds.ToArray(),
                "routing", D("rules", rules.ToArray())));
        }
    }
}
