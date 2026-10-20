package hev.sockstun;

/** JNI-обёртка hev-socks5-tunnel 2.18 (собирается с PKGNAME=hev/sockstun, CLSNAME=TProxyService). */
public final class TProxyService {
    private TProxyService() {}

    public static native boolean TProxyStartService(String configPath, int fd);

    public static native boolean TProxyStopService();

    public static native boolean TProxyIsRunning();

    public static native long[] TProxyGetStats();
}
