/*
 * sigsys-wrap.c — тестовая обёртка: ставит seccomp-фильтр с SECCOMP_RET_TRAP
 * и запускает программу. Нужна, чтобы доказать, что шим чинит ровно то, что
 * делает Android: ловушку seccomp вместо errno.
 *
 * Использование:
 *   sigsys-wrap [-p shim.so] [-t 436,434] prog [args...]
 *     -p path   добавить path в LD_PRELOAD дочернего процесса
 *     -t list   номера syscall'ов, на которые ловушка (по умолчанию 436)
 *
 * Собрано без libc (freestanding, -nostdlib): нужен только aarch64-компилятор.
 * Гоняется через qemu-aarch64 -L <sysroot>.
 */

#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <ucontext.h>

#define MAX_TRAP 32
#define MAX_ENV 256

#define NR_write 64
#define NR_prctl 157
#define NR_execve 221
#define NR_exit_group 94
#define PR_SET_NO_NEW_PRIVS 38
#define PR_SET_SECCOMP 22
#define SECCOMP_MODE_FILTER 2

struct k_sigaction {
	void *handler;
	unsigned long flags;
	void (*restorer)(void);
	unsigned long mask[16];
};

static inline long sc6(long n, long a, long b, long c, long d, long e, long f) {
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;
	register long x4 __asm__("x4") = e;
	register long x5 __asm__("x5") = f;
	__asm__ volatile("svc 0"
			 : "+r"(x0)
			 : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x8)
			 : "memory", "cc");
	return x0;
}

static unsigned long trap[MAX_TRAP];
static size_t trap_len;

static void put(const char *s) {
	size_t n = 0;
	while (s[n])
		n++;
	sc6(NR_write, 2, (long)s, n, 0, 0, 0);
}

static void put_num(long v) {
	char b[24];
	int i = (int)sizeof b;

	b[--i] = '\n';
	if (v < 0) {
		b[--i] = '-';
		v = -v;
	}
	do {
		b[--i] = (char)('0' + (v % 10));
		v /= 10;
	} while (v);
	put(b + i);
}

/* Разбор списка "436,434" без libc */
static void add_trap(const char *s) {
	while (*s && trap_len < MAX_TRAP) {
		long v = 0;
		while (*s >= '0' && *s <= '9')
			v = v * 10 + (*s++ - '0');
		if (v)
			trap[trap_len++] = (unsigned long)v;
		if (*s == ',')
			s++;
		else if (*s)
			break;
	}
}

/*
 * Собственный environ: нам нужно добавить ровно один элемент, поэтому
 * перекладываем указатели в статический массив.
 */
static char *env_new[MAX_ENV + 2];
static char ldbuf[512];

static char *cat(const char *a, const char *b) {
	size_t i = 0, j;

	for (j = 0; a[j] && i + 1 < sizeof ldbuf; j++)
		ldbuf[i++] = a[j];
	for (j = 0; b[j] && i + 1 < sizeof ldbuf; j++)
		ldbuf[i++] = b[j];
	ldbuf[i] = 0;
	return ldbuf;
}

__attribute__((noreturn)) static void fail(const char *why, long rc) {
	put("sigsys-wrap: ");
	put(why);
	put(" = ");
	put_num(rc);
	sc6(NR_exit_group, 1, 0, 0, 0, 0, 0);
	__builtin_unreachable();
}

/*
 * При входе в процесс все регистры обнулены: argc лежит на стеке, а не в x0.
 * Прочитать sp прямо в C нельзя — компилятель сделает это уже после пролога
 * кадра. Поэтому вход отдельный и naked: он сохраняет sp до всего остального.
 */
__attribute__((naked, noreturn)) void _start(void) {
	/* sp кладём в x0 — это обычный первый аргумент, его C-код точно прочитает */
	__asm__ volatile("mov x0, sp\n\tb sigsys_main");
}

/* noinline+used: на неё ссылается только inline-asm из _start */
__attribute__((noinline, used)) static void sigsys_main(long *sp) {
	int argc = (int)sp[0];
	char **argv = (char **)&sp[1];
	char **envp = argv + argc + 1;
	struct sock_filter filter[MAX_TRAP * 2 + 2];
	struct sock_fprog prog;
	const char *preload = 0;
	long rc;
	int i, n = 0, argi = 1;

	while (argi < argc && argv[argi][0] == '-' && argv[argi][1]) {
		if (argv[argi][1] == 'p' && !argv[argi][2] && argi + 1 < argc)
			preload = argv[++argi];
		else if (argv[argi][1] == 't' && !argv[argi][2] && argi + 1 < argc)
			add_trap(argv[++argi]);
		else
			break;
		argi++;
	}
	if (argi >= argc)
		fail("нужна программа", 2);
	if (!trap_len)
		add_trap("436"); /* close_range */

	/*
	 * Схема фильтра (jt/jf относительно следующей инструкции):
	 *   0: LD  arch
	 *   1: JEQ AARCH64, jt=0, jf=<до ALLOW>   — чужая архитектура: пропускаем всё
	 *   2: LD  nr
	 *   3: JEQ nr0, jt=<до TRAP>, jf=0
	 *   4: JEQ nr1, jt=<до TRAP>, jf=0
	 *   ...
	 *   N: RET ALLOW
	 * N+1: RET TRAP
	 */
	filter[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
	filter[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_AARCH64, 0,
						   (unsigned char)(trap_len + 1));
	filter[n++] = (struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
	for (i = 0; i < (int)trap_len; i++)
		filter[n++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (uint32_t)trap[i],
							  (unsigned char)(trap_len - i), 0);
	filter[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
	filter[n++] = (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP);
	/*
	 * ВНИМАНИЕ: под qemu-user этот харнесс бесполезен. prctl уходит в ядро
	 * хоста, а там seccomp-фильтр проверяется на ARCH-самой-задачи: фильтр с
	 * AUDIT_ARCH_AARCH64 на x86-64 хосте отвергается с EPERM. Ловушку,
	 * неотличимую от android'овской, можно поставить только на настоящем
	 * aarch64 или на хосте той же архитектуры (см. sigsys-x86-test).
	 */

	prog.len = (unsigned short)n;
	prog.filter = filter;

	if (sc6(NR_prctl, PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0, 0) < 0)
		fail("PR_SET_NO_NEW_PRIVS", -1);
	if (sc6(NR_prctl, PR_SET_SECCOMP, SECCOMP_MODE_FILTER, (long)&prog, 0, 0, 0) < 0)
		fail("PR_SET_SECCOMP (фильтр не встал: не aarch64?)", -1);

	if (preload) {
		int k = 0;
		for (i = 0; envp[i] && k < MAX_ENV; i++)
			env_new[k++] = envp[i];
		env_new[k++] = cat("LD_PRELOAD=", preload);
		env_new[k] = 0;
		envp = env_new;
		put("sigsys-wrap: LD_PRELOAD=");
		put(preload);
		put("\n");
	}

	put("sigsys-wrap: SECCOMP_RET_TRAP на ");
	for (i = 0; i < (int)trap_len; i++)
		put_num((long)trap[i]);
	put(" -> ");
	put(argv[argi]);
	put("\n");

	rc = sc6(NR_execve, (long)argv[argi], (long)(argv + argi), (long)envp, 0, 0, 0);
	fail("execve", rc);
}
