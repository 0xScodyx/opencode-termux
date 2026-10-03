# opencode-termux

Установщик [opencode](https://opencode.ai) в **Termux** на Android/arm64 — без Waydroid, без chroot, без `proot` в штатном режиме.

```bash
pkg install curl
curl -fsSL https://raw.githubusercontent.com/0xScodyx/opencode-termux/main/opencode-termux.sh -o opencode-termux.sh
bash opencode-termux.sh
```

Проверено на opencode **v2.0.22**, Termux aarch64.

---

## Зачем это нужно

Официальный установщик `curl -fsSL https://opencode.ai/v2/install | bash` на Android не работает, и это не баг окружения:

| # | Проблема | Следствие |
|---|----------|-----------|
| 1 | бинарь opencode — `ET_EXEC` (non-PIE) | Android ≥ 5 требует PIE, bionic-linker (`/system/bin/linker64`) его отвергает |
| 2 | в бинаре зашит интерпретатор `/lib/ld-linux-aarch64.so.1` | на Android такого файла нет вообще |
| 3 | opencode собран под glibc, а Termux — это bionic | несовместимые libc |

Частая ошибка на форумах — «бинарь не PIE, Android его не запустит в принципе». Обойти это можно: ядро Android грузит ELF-бинарь, а не bionic, поэтому достаточно подсунуть **настоящий glibc-загрузчик** через `PT_INTERP`. Нативных syscall'ов Android не блокирует, так что opencode работает напрямую.

## Что делает скрипт

1. Ставит `glibc-repo` + `glibc-runner` — glibc, собранный под Termux (`$PREFIX/glibc`).
2. Определяет последнюю версию через `https://opencode.ai/update/api/latest/cli/npm`.
3. Скачивает tarball `@opencode/cli-linux-arm64` с npm и сверяет **sha512** с тем, что отдаёт registry (fallback — sha1 из `dist.shasum`).
4. **Точечно правит `PT_INTERP`** в бинаре: строка интерпретатора записывается поверх `.interp` + `.note`, у сегмента расширяется `p_filesz`. Сегменты, `vaddr` и все смещения файла остаются нетронутыми.
5. Создаёт обёртку в `$PREFIX/bin/opencode`, которая снимает `LD_PRELOAD` (bionic-библиотеки ломают glibc-процесс), выставляет `LD_LIBRARY_PATH` на glibc и `TMPDIR=$PREFIX/tmp` (в Android нет `/tmp`, а Bun распаковывает туда нативный модуль OpenTUI).
6. Перехватывает `opencode upgrade`: встроенный upgrade снёс бы правку интерпретатора, поэтому переустановка идёт этим же скриптом.

### Почему не `patchelf`

`patchelf` для этого бинаря **нельзя использовать**, и это самая интересная находка при разработке.

`patchelf --set-interpreter` пересобирает LOAD-сегменты и сдвигает базу образа:

```
было:   LOAD offset=0x000000  vaddr=0x200000
стало:  LOAD offset=0x000000  vaddr=0x1e0000   ← образ сдвинут на 128 КиБ
```

opencode — non-PIE `ET_EXEC` с зашитыми в код абсолютными адресами, поэтому после такой правки любой обращение к `.rodata`/`.got` уезжает на 0x20000 и процесс падает с `SIGSEGV`.

Хуже всего, что это **почти незаметно**: `readelf -S` по-прежнему показывает секцию `.bun` на месте, размер файла выглядит нормально, `.bun`-payload байт-в-байт идентичен. Бинарь просто не запускается.

Замеры на aarch64 (qemu + Ubuntu arm64):

| вариант | результат |
|---|---|
| примитив из npm | `opencode v2.0.22`, exit 0 |
| после `patchelf` 0.18.0 | `readelf: the PHDR segment is not covered by a LOAD segment` |
| после `patchelf` 0.19.2 | `Segmentation fault`, exit 139 |
| после точечной правки байтов | `opencode v2.0.22`, exit 0 |

После правки `readelf -lW` показывает единственное отличие — `INTERP p_filesz 0x1b → 0x22` и обнулённые `NOTE` (их содержимое затёрто новой строкой). Размер файла не меняется ни на байт.

## Требования

* Termux на **arm64/aarch64** (обычный телефон)
* `curl`, `tar`, `coreutils` (`dd`, `od`, `wc`) — ставятся из репозитория Termux, скрипт проверит сам
* ~300 МБ свободного места (см. ниже)

## Опции

```
-v, --version <ver>   установить конкретную версию (например 2.0.22)
-m, --method <m>      native (по умолчанию) | proot (fallback)
-f, --force           переустановить, даже если такая версия уже стоит
    --skip-checksum   не проверять sha512 tarball
    --keep-tmp        не удалять временные файлы
    --uninstall       удалить opencode и обёртки
-h, --help            справка
```

## Место на диске

Пик потребления — **261 МБ** (измерено, а не прикинуто):

| режим | что происходит | пик |
|---|---|---|
| обычный | tarball 86 МБ + бинарь 191 МБ | ~280 МБ |
| потоковый | `curl \| tar` прямо в цель, tarball не пишется | ~200 МБ |

Если свободно меньше 300 МБ, скрипт сам переключается в потоковый режим (с предупреждением, что сверка checksum пропускается). Если меньше 220 МБ — честно откажется работать и подскажет, что делать. Хвосты прошлых попыток в `$PREFIX/tmp/opencode-termux.*` чистятся автоматически.

Порог можно переопределить: `OPENCODE_MIN_FREE_MB=500 bash opencode-termux.sh`.

## Если что-то пошло не так

### `opencode убит сигналом SIGSYS` / `invalid system call`

Это Android seccomp: система запрещает часть syscall'ов, а Bun их вызывает. Установка при этом успешная — падает только конкретный процесс (обычно фоновый сервер).

```bash
opencode --standalone   # приватный сервер вместо фонового сервиса
opencode mini           # минимальный интерфейс
export OPENCODE_STANDALONE=1   # то же самое постоянно
```

Если не помогло — вычислить конкретный syscall:

```bash
pkg install strace
strace -f -o $PREFIX/tmp/oc.strace opencode serve
tail -3 $PREFIX/tmp/oc.strace
```

### Чёрный экран TUI

```bash
TMPDIR=$PREFIX/tmp opencode
```

`TMPDIR` обёртка выставляет сама, но если запускаешь бинарь напрямую — нужно задать руками.

### `No space left on device`

```bash
rm -rf $PREFIX/tmp/opencode-termux.*   # хвосты прошлых попыток
apt clean; apt autoremove -y
TMPDIR=/путь/с/местом bash opencode-termux.sh   # другая раздел
```

### Fallback: proot

Если seccomp не даёт запустить сервер даже с `--standalone`:

```bash
bash ~/.opencode/install-termux.sh --method proot
```

Ставит proot-distro с Debian и запускает opencode внутри. Работает медленнее и требует заметно больше места, зато TUI гарантирован.

## Обслуживание

```bash
opencode upgrade                    # перехватывается, правка интерпретатора сохраняется
bash ~/.opencode/install-termux.sh --force
bash ~/.opencode/install-termux.sh --uninstall
```

Файлы после установки:

```
$PREFIX/bin/opencode                        обёртка в $PATH
$HOME/.opencode/bin/opencode                ещё одна обёртка, для случая без доступа к $PREFIX/bin
$HOME/.opencode/libexec/opencode            настоящий бинарь
$HOME/.opencode/install-termux.sh           копия установщика (нужна для upgrade)
```

## Как проверялось

Полный сценарий установки прогонялся на настоящем aarch64 через `qemu-aarch64` (Docker + `binfmt_misc`, arm64-образ Ubuntu): установка, распаковка, правка `PT_INTERP`, запуск, распаковка нативного модуля OpenTUI в `TMPDIR`, идемпотентность, `--force`, upgrade-хук, `--uninstall`, потоковый режим.

Ограничение честное: Android seccomp воспроизвести в контейнере нельзя, поэтому поведение под seccomp проверялось на телефоне и корректировалось по его выводу.

## Безопасность

* tarball сверяется с sha512/sha1, которые отдаёт сам npm registry — подмена пакета обнаруживается
* HTTPS везде, где есть выбор
* скрипт не требует root и ничего не пишет вне `$HOME` и `$PREFIX`

## Links

* opencode: https://opencode.ai
* репозиторий скрипта: https://github.com/0xScodyx/opencode-termux
