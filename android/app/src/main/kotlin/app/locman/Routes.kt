package app.locman

/** Маршруты VPN: весь IPv4, кроме частных, служебных и групповых подсетей. */
object Routes {
    private val excluded = listOf(
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3",
    )

    private fun parse(cidr: String): Pair<Long, Int> {
        val (ip, len) = cidr.split('/')
        val n = ip.split('.').fold(0L) { acc, part -> (acc shl 8) or part.toLong() }
        return n to len.toInt()
    }

    private fun format(n: Long): String = listOf(24, 16, 8, 0).joinToString(".") { ((n shr it) and 0xFF).toString() }

    /** Разбиваем 0.0.0.0/0 на префиксы, не задевающие исключённые сети. */
    fun publicIpv4(): List<Pair<String, Int>> {
        val ex = excluded.map(::parse)
        val out = mutableListOf<Pair<String, Int>>()
        fun overlaps(start: Long, len: Int, e: Pair<Long, Int>): Boolean {
            val l = minOf(len, e.second)
            val mask = if (l == 0) 0L else (0xFFFFFFFFL shl (32 - l)) and 0xFFFFFFFFL
            return (start and mask) == (e.first and mask)
        }
        fun walk(start: Long, len: Int) {
            val hits = ex.filter { overlaps(start, len, it) }
            when {
                hits.isEmpty() -> out += format(start) to len
                hits.any { it.second <= len } -> Unit // целиком исключённая сеть
                else -> {
                    walk(start, len + 1)
                    walk(start or (1L shl (31 - len)), len + 1)
                }
            }
        }
        walk(0L, 0)
        return out
    }
}
