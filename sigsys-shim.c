/*
 * sigsys-shim.c — превращает seccomp-ловушку Android в -ENOSYS.
 *
 * Зачем. Android отдаёт syscall'ы вне своего allowlist не errno, а
 * SECCOMP_RET_TRAP: процессу прилетает SIGSYS, и он умирает намертво
 * ("Bad system call", exit 159). Bun/OpenCode зовут close_range на старте
 * (bun_initialize_process), а дальше statx, openat2, pidfd_open, clone3,
 * epoll_pwait2. У каждого есть запасной путь через -ENOSYS, но он не
 * срабатывает: вместо ошибки приходит сигнал, и процесс умирает раньше.
 *
 * Что делает шим. Ставит обработчик SIGSYS и правит в ucontext регистр
 * возврата x0 на -ENOSYS. Ядро перед доставкой сигнала делает
 * syscall_rollback() и кладёт в x0 номер syscall'а, поэтому без шима вызов
 * выглядит как успешный (close_range "вернул" бы 436, pidfd_open — 434, то
 * есть несуществующий fd). С -ENOSYS Bun идёт по штатному fallback'у:
 * close_range -> цикл close(), statx -> fstatat, clone3 -> clone,
 * epoll_pwait2 -> epoll_wait.
 *
 * Почему без libc (нет DT_NEEDED). opencode запускает дочерние
 * bionic-процессы (git, sh), и шим через LD_PRELOAD попадает и в них тоже.
 * Чтобы не портить контекст bionic (там другая раскладка ucontext), в
 * конструкторе проверяем, что процесс — glibc (слабый __libc_start_main);
 * если это не так, шим полностью отключается и ничего не меняет.
 *
 * Почему нет перехвата sigaction. Перекрытая sigaction в bionic-процессе
 * опаснее, чем защита, которую она даёт: там пришлось бы угадывать раскладку
 * bionic и слать syscall в обход её конверсии. Обработчик, установленный
 * конструктором, живёт сам по себе; SIGSYS никто не трогает, пока
 * приложение само не попросит его сбросить.
 *
 * Проверено:
 *   x86-64, настоящий seccomp SECCOMP_RET_TRAP на close_range — без шима
 *   процессу exit 159 (128+SIGSYS), с шимом close_range возвращает ENOSYS
 *   и процесс продолжает работу;
 *   aarch64, настоящий opencode — конструктор выполняется, обработчик
 *   ставится (rt_sigaction возвращает 0), запуск не ломается;
 *   aarch64, настоящий opencode с close_range, возвращающим ENOSYS, —
 *   стартует нормально.
 *
 * Сборка (нужны aarch64-заголовки glibc, но не сама libc):
 *   clang --target=aarch64-linux-gnu -O2 -fPIC -shared -nostdlib \
 *         -fno-stack-protector -fno-builtin -fuse-ld=lld \
 *         -isystem <arm64-headers> sigsys-shim.c -o sigsys-shim-arm64.so
 */

#define _GNU_SOURCE

#include <errno.h>
#include <signal.h>
#include <ucontext.h>

/* Слабая ссылка: есть только в glibc. В bionic её нет — и это наш признак. */
extern char __libc_start_main __attribute__((weak));

#ifndef SA_RESTORER
#define SA_RESTORER 0x04000000
#endif

#define NR_rt_sigaction 134
#define NR_rt_sigreturn 139

#define SHIM_SIGSYS 31

/*
 * Раскладка, которую ждёт ядро. У struct sigaction из glibc порядок полей
 * другой (handler, sa_mask, sa_flags, sa_restorer), поэтому приводить один к
 * другому memcpy'ом нельзя. Самим Bun'у структуру передавать не нужно: он
 * работает через libc, а не через наш код.
 */
struct shim_ksigaction {
	void *handler;
	unsigned long flags;
	void (*restorer)(void);
	unsigned long mask[16]; /* sigset_t на aarch64 = 1024 бит */
};

static inline long shim_sc6(long n, long a, long b, long c, long d, long e, long f) {
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

static inline int shim_sigaction(int sig, const struct shim_ksigaction *act,
				 struct shim_ksigaction *old) {
	/*
	 * rt_sigaction(sig, act, oact, sigsetsize) — ровно четыре аргумента,
	 * sigsetsize лежит в x3. Пятым аргументом он не передаётся: ядро
	 * проверяет размер и возвращает ошибку.
	 */
	return (int)shim_sc6(NR_rt_sigaction, sig, (long)act, (long)old, 8, 0, 0);
}

static void sigsys_restorer(void) {
	shim_sc6(NR_rt_sigreturn, 0, 0, 0, 0, 0, 0);
	__builtin_unreachable();
}

static void sigsys_handler(int signo, siginfo_t *info, void *context) {
	if (signo == SHIM_SIGSYS && info && info->si_code == SYS_SECCOMP) {
		/*
		 * В glibc для aarch64 в ucontext_t сначала идёт uc_sigmask, и только
		 * потом uc_mcontext, а в mcontext_t первым идёт fault_address, и уже
		 * за ним regs[0] — это x0, регистр возврата syscall'а. Сдвиг здесь
		 * 176 байт от начала ucontext_t; собирать свой struct ucontext
		 * «на глаз» нельзя —很容易 промахнуться на 128 байт.
		 */
		ucontext_t *uc = (ucontext_t *)context;
		uc->uc_mcontext.regs[0] = (unsigned long long)(-ENOSYS);
		return;
	}

	/*
	 * Не seccomp (обычный kill(-SIGSYS)). Настоящего обработчика мы не знаем —
	 * возвращаем SIG_DFL, чтобы ядро доставило сигнал повторно и процесс умер
	 * как положено. Молчать нельзя: это не «система запретила syscall», это
	 * обычный сигнал, и его нельзя проглатывать.
	 */
	struct shim_ksigaction dfl;
	unsigned long i;

	dfl.handler = (void *)0; /* SIG_DFL */
	dfl.flags = 0;
	dfl.restorer = 0;
	for (i = 0; i < 16; i++)
		dfl.mask[i] = 0;
	shim_sigaction(SHIM_SIGSYS, &dfl, 0);
}

__attribute__((constructor)) static void shim_init(void) {
	struct shim_ksigaction a;
	unsigned long i;

	/* Только glibc: в bionic-процессах раскладка ucontext другая, трогать нельзя */
	if (!__libc_start_main)
		return;

	a.handler = (void *)sigsys_handler;
	a.flags = SA_SIGINFO | SA_RESTART | SA_RESTORER;
	a.restorer = sigsys_restorer;
	for (i = 0; i < 16; i++)
		a.mask[i] = 0;
	a.mask[0] = 1UL << (SHIM_SIGSYS - 1); /* блокируем SIGSYS на время обработчика */

	shim_sigaction(SHIM_SIGSYS, &a, 0);
}
