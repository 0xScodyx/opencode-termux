#!/usr/bin/env bash
# opencode-termux.sh — установка opencode в Termux (Android, aarch64) "по-человечески".
#
# Почему не работает `curl -fsSL https://opencode.ai/v2/install | bash`:
#   1) бинарь opencode — это ET_EXEC (non-PIE) ELF, а Android >= 5 требует PIE,
#      поэтому bionic-linker (/system/bin/linker64) его отвергает;
#   2) в нём зашит интерпретатор /lib/ld-linux-aarch64.so.1, которого в Android нет;
#   3) Termux — это bionic, а opencode собран под glibc.
#
# Решение: ставим glibc из репозитория glibc-repo/glibc-runner и меняем в бинаре
# PT_INTERP на $PREFIX/glibc/lib/ld-linux-aarch64.so.1. Ядро само грузит
# glibc-загрузчик, поэтому /proc/self/exe остаётся правильным (это важно: Bun
# ищет свой встроенный payload по /proc/self/exe в секции .bun, и при запуске
# через `grun` TUI ломается). Нативных syscall'ов Android не блокирует, поэтому
# opencode работает напрямую, без proot/waydroid/chroot.
#
# ВАЖНО: патчить бинарь через patchelf нельзя. patchelf пересобирает LOAD-сегменты
# и сдвигает базу образа (проверено: 0x200000 -> 0x1e0000). Для non-PIE ET_EXEC
# с зашитыми абсолютными адресами это мгновенный SIGSEGV, причём на глаз это
# незаметно — readelf показывает секцию .bun на месте, а программа падает.
# Поэтому ниже своя хирургическая правка: строка интерпретатора пишется поверх
# .interp + .note (их суммарно 96 байт), а у PT_INTERP расширяется p_filesz.
# Сегменты, vaddr и все смещения файла остаются нетронутыми.
# Проверено на aarch64: после такой правки `opencode --version` -> v2.0.22, exit 0,
# а после patchelf 0.18/0.19.2 -> Segmentation fault (exit 139).
#
# Использование:
#   bash opencode-termux.sh                 # latest, native
#   bash opencode-termux.sh -v 2.0.22       # конкретная версия
#   bash opencode-termux.sh --method proot  # fallback: glibc-окружение целиком
#   bash opencode-termux.sh --uninstall

set -euo pipefail

APP=opencode
REQ_VERSION=""
METHOD=native
FORCE=0
UNINSTALL=0
SKIP_SUM=0
KEEP_TMP=0
DIAG=0

RED=""; GRN=""; YLW=""; DIM=""; BLD=""; NC=""
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'
  BLD=$'\033[1m'; NC=$'\033[0m'
fi

log()  { printf '%s\n' "${DIM}==>${NC} $*"; }
ok()   { printf '%s\n' "${GRN}✓${NC} $*"; }
warn() { printf '%s\n' "${YLW}!${NC} $*" >&2; }
die()  { printf '%s\n' "${RED}✗${NC} $*" >&2; exit 1; }
step() { printf '\n%s\n' "${BLD}▸ $*${NC}"; }

usage() {
  cat <<EOF
${BLD}opencode installer for Termux / Android aarch64${NC}

  bash opencode-termux.sh [options]

  -v, --version <ver>   установить конкретную версию (например 2.0.22)
  -m, --method <m>      native (по умолчанию) | proot (fallback)
  -f, --force           переустановить, даже если такая версия уже стоит
      --skip-checksum   не проверять sha512 tarball
      --keep-tmp        не удалять временные файлы
      --uninstall       удалить opencode и обёртки
      --diag            собрать диагностику и найти заблокированный syscall
  -h, --help            эта справка
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -v|--version) REQ_VERSION="${2:?--version требует аргумент}"; REQ_VERSION="${REQ_VERSION#v}"; shift 2 ;;
    -m|--method)  METHOD="${2:?--method требует аргумент}"; shift 2 ;;
    -f|--force)   FORCE=1; shift ;;
    --skip-checksum) SKIP_SUM=1; shift ;;
    --keep-tmp)   KEEP_TMP=1; shift ;;
    --uninstall)  UNINSTALL=1; shift ;;
    --diag)       DIAG=1; shift ;;
    *) die "Неизвестная опция: $1 (см. --help)" ;;
  esac
done

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME="${HOME:-$PREFIX/../home}"
BIN_DIR="$PREFIX/bin"
OC_HOME="$HOME/.opencode"
REAL_BIN="$OC_HOME/libexec/$APP"
LIBEXEC_DIR="$OC_HOME/libexec"
SHIM_DIR="$OC_HOME/bin"
NPM_SCOPE="@opencode"
REGISTRY="https://registry.npmjs.org"
UPDATE_API="https://opencode.ai/update/api/latest/cli/npm"
TARGET="linux-arm64"   # glibc-сборка: нужен только libc.so.6 (GLIBC_2.17)

WORK=""
cleanup() { [ -n "$WORK" ] && [ "$KEEP_TMP" -eq 0 ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Нет команды '$1'. Установите: pkg install $2"; }

# ── ELF: чтение и замена PT_INTERP без перестройки сегментов ───────────────────
# patchelf здесь неприменим: он пересобирает LOAD-сегменты и сдвигает базу образа,
# что ломает non-PIE ET_EXEC (SIGSEGV). Ниже — точечная правка байтов.
#
# le8 N        — 8 байт little-endian (для записи в p_offset/p_filesz/p_memsz)
# rd_le off w  — прочитать w байт LE по смещению off
# elf_interp F — напечатать строку PT_INTERP
# elf_set_interp F PATH — заменить строку интерпретатора

le8() { local n=$1 i; for i in 1 2 3 4 5 6 7 8; do printf "\\$(printf '%03o' $((n % 256)))"; n=$((n / 256)); done; }

rd_le() {
  local off=$1 w=$2 i byte n=0
  for ((i = 0; i < w; i++)); do
    byte=$(od -An -tu1 -N1 -j "$((off + i))" "$ELF_FILE" | tr -d ' ')
    n=$((n + byte * 256 ** i))
  done
  printf '%s' "$n"
}

rd_hex() { od -An -tx1 -N4 -j "$1" "$ELF_FILE" | tr -d ' \n'; }

# находит PT_INTERP и отдаёт его смещение в phdr-таблице (или пусто)
elf_find_phdr() { # $1 = тип сегмента (03000000 = INTERP, 04000000 = NOTE)
  local base type i
  ELF_FILE="$1"
  local phoff phentsize phnum
  phoff=$(rd_le 0x20 8); phentsize=$(rd_le 0x36 2); phnum=$(rd_le 0x38 2)
  i=0
  while [ "$i" -lt "$phnum" ]; do
    base=$((phoff + i * phentsize))
    type=$(rd_hex "$base")
    if [ "$type" = "$2" ]; then
      printf '%s' "$base"; return 0
    fi
    i=$((i + 1))
  done
  return 1
}

elf_interp() {
  local f="$1" phdr off
  ELF_FILE="$f"
  phdr=$(elf_find_phdr "$f" 03000000) || return 1
  off=$(rd_le $((phdr + 8)) 8)
  dd if="$f" bs=1 skip="$off" count=200 status=none | tr '\0' '\n' | LC_ALL=C sed -n '1p'
}

elf_set_interp() { # $1 = файл, $2 = новый путь к загрузчику
  local f="$1" new="$2" buf size phdr
  ELF_FILE="$f"
  buf="$WORK/interp.buf"
  mkdir -p "$WORK"

  size=$(wc -c < "$f")
  [ "$(rd_hex 0)" = "7f454c46" ] || die "не ELF"
  [ "$(od -An -tx1 -N1 -j4 "$f" | tr -d ' ')" = "02" ] || die "поддерживается только ELF64"
  [ "$(od -An -tx1 -N1 -j5 "$f" | tr -d ' ')" = "01" ] || die "поддерживается только little-endian"

  phdr=$(elf_find_phdr "$f" 03000000) || die "в бинаре нет PT_INTERP"
  local off fsz need pad
  off=$(rd_le $((phdr + 8)) 8)
  fsz=$(rd_le $((phdr + 32)) 8)

  # граница: конец последнего NOTE-сегмента, идущего за .interp.
  # ровно там кончается свободное место до .dynsym (проверено на 2.0.22: 96 байт).
  local avail notes i base phoff phentsize phnum
  phoff=$(rd_le 0x20 8); phentsize=$(rd_le 0x36 2); phnum=$(rd_le 0x38 2)
  avail=$((off + fsz)); notes=""
  i=0
  while [ "$i" -lt "$phnum" ]; do
    base=$((phoff + i * phentsize))
    if [ "$(rd_hex "$base")" = "04000000" ]; then
      local noff nsz end
      noff=$(rd_le $((base + 8)) 8); nsz=$(rd_le $((base + 32)) 8)
      # NOTE с нулевым размером (уже затёртый) места не даёт
      if [ $((noff + nsz)) -gt "$avail" ]; then
        notes="$notes $base"; avail=$((noff + nsz))
      fi
    fi
    i=$((i + 1))
  done

  need=$(( ${#new} + 1 ))
  [ "$need" -le $((avail - off)) ] \
    || die "новый путь интерпретатора не влезает: нужно $need байт, свободно $((avail - off)).
   Значит PREFIX слишком длинный. Обычно достаточно $PREFIX/glibc/lib/ld-linux-aarch64.so.1"

  pad=$((avail - off))
  { printf '%s\0' "$new"; dd if=/dev/zero bs=1 count=$((pad - need)) 2>/dev/null; } > "$buf"
  dd if="$buf" of="$f" bs=1 seek="$off" conv=notrunc status=none
  le8 "$need" > "$buf"
  dd if="$buf" of="$f" bs=1 seek=$((phdr + 32)) conv=notrunc status=none   # p_filesz
  dd if="$buf" of="$f" bs=1 seek=$((phdr + 40)) conv=notrunc status=none   # p_memsz

  # содержимое NOTE-сегментов затёрто новой строкой — обнуляем их размеры,
  # иначе readelf/file будут пытаться разобрать мусор
  for base in $notes; do
    le8 0 > "$buf"
    dd if="$buf" of="$f" bs=1 seek=$((base + 32)) conv=notrunc status=none
    dd if="$buf" of="$f" bs=1 seek=$((base + 40)) conv=notrunc status=none
  done
  rm -f "$buf"

  [ "$(wc -c < "$f")" -eq "$size" ] || die "размер бинаря изменился — патч неудачен"
  ok "PT_INTERP: offset=$off, p_filesz $fsz -> $need, свободно было $((avail - off)) байт"
}

GLIBC_DIR="$PREFIX/glibc"
LOADER=""

find_loader() {
  local c
  for c in \
    "$GLIBC_DIR/lib/ld-linux-aarch64.so.1" \
    "$GLIBC_DIR/lib64/ld-linux-aarch64.so.1" \
    "$GLIBC_DIR/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1" \
    "$GLIBC_DIR/bin/ld.so"; do
    [ -f "$c" ] && { LOADER="$c"; return 0; }
  done
  return 1
}

# ── 1. Диагностика ────────────────────────────────────────────────────────────
# Задача: сказать, что именно ломает opencode на этом устройстве. Самая частая
# причина — Android seccomp (SIGSYS). Диагностика ставит strace, смотрит, какой
# syscall был последним перед смертью, и печатает всё одним блоком, удобным
# для отправки (в issue или в чат).
if [ "$DIAG" -eq 1 ]; then
  step "Диагностика окружения"
  printf 'Android      : %s (SDK %s)\n' \
    "$(getprop ro.build.version.release 2>/dev/null || echo '?')" \
    "$(getprop ro.build.version.sdk 2>/dev/null || echo '?')"
  printf 'Ядро        : %s\n' "$(uname -r)"
  printf 'Архитектура : %s\n' "$(uname -m)"
  printf 'Termux      : %s\n' "$(dpkg -s termux 2>/dev/null | awk '/^Version:/{print $2}' || echo '?')"
  printf 'PREFIX      : %s\n' "$PREFIX"

  LOADER=""
  find_loader && printf 'glibc       : %s\n' "$LOADER" || printf 'glibc       : НЕ НАЙДЕН (pkg install glibc-repo glibc-runner)\n'
  if [ -n "$LOADER" ]; then
    "$LOADER" --version 2>/dev/null | head -1 | sed 's/^/glibc версия: /' || true
    printf 'библиотеки  : %s\n' "$(ls "$GLIBC_DIR/lib" 2>/dev/null | tr '\n' ' ' | cut -c1-120)"
  fi

  if [ -f "$REAL_BIN" ]; then
    printf 'opencode    : %s (%s)\n' "$(du -h "$REAL_BIN" | cut -f1)" "$REAL_BIN"
    printf 'интерпретатор: %s\n' "$(elf_interp "$REAL_BIN" 2>/dev/null || echo '?')"
  else
    printf 'opencode    : не установлен\n'
    printf '              (установить: bash %s)\n' "${BASH_SOURCE[0]:-$0}"
  fi

  if [ ! -x "$REAL_BIN" ]; then
    cat <<EOF

${DIM}Проверить glibc и окружение, opencode пока не установлен — см. блок выше.${NC}
EOF
    exit 0
  fi

  step "Ищу заблокированный syscall"
  if ! command -v strace >/dev/null 2>&1; then
    log "Ставлю strace"
    pkg install -y strace >/dev/null 2>&1 || apt install -y strace >/dev/null 2>&1 || true
  fi

  TRACE="$PREFIX/tmp/opencode-diag.strace"
  rm -f "$TRACE"
  if command -v strace >/dev/null 2>&1; then
    # -E задаёт переменные окружения только самому opencode. Через env нельзя:
    # strace — это bionic-бинарь, и glibc-путь в его окружении заставил бы
    # Android-linker искать glibc-овский libc.so (текстовый скрипт) — ровно та
    # ошибка "CANNOT LINK EXECUTABLE ... has bad ELF magic", что была у друга.
    strace -f -o "$TRACE" \
      -E LD_LIBRARY_PATH="$(dirname "$LOADER")" \
      -E TMPDIR="${TMPDIR:-$PREFIX/tmp}" \
      -E LD_PRELOAD= \
      "$REAL_BIN" --version >/dev/null 2>&1 || true
    printf '\n%s\n' "--- последние вызовы перед смертью (strace) ---"
    if [ -s "$TRACE" ]; then
      tail -6 "$TRACE" | sed 's/^/  /'
    else
      printf '  (strace ничего не записал — попробуй запустить opencode руками под strace)\n'
    fi
    printf '\n%s\n' "--- вердикт ---"
    if grep -q 'killed by SIGSYS' "$TRACE" 2>/dev/null; then
      last="$(grep -B1 'killed by SIGSYS' "$TRACE" | head -1 | sed 's/^[0-9]* //; s/(.*//')"
      printf '  Android seccomp убил процесс на syscall: %s\n' "${last:-неизвестно}"
      cat <<'EOF'

  Что делать:
    • opencode --standalone     приватный сервер вместо фонового сервиса
    • opencode mini             минимальный интерфейс
    • bash ~/.opencode/install-termux.sh --method proot
    • отправь этот блок в issue: https://github.com/0xScodyx/opencode-termux/issues
EOF
    elif grep -q 'killed by SIGSEGV' "$TRACE" 2>/dev/null; then
      printf '  Процесс упал с SIGSEGV — бинарь собран не под glibc или сломана правка интерпретатора.\n'
    elif [ -s "$TRACE" ]; then
      printf '  SIGSYS не detected — смотри последние вызовы выше.\n'
    fi
    printf '\nПолный лог: %s\n' "$TRACE"
  else
    printf 'strace не установился. Поставь вручную:\n  pkg install strace\n'
    printf 'затем: strace -f -o %s -E LD_LIBRARY_PATH=%s %s --version\n' \
      "$TRACE" "$(dirname "$LOADER")" "$REAL_BIN"
  fi
  exit 0
fi

# ── 2. Uninstall ──────────────────────────────────────────────────────────────
if [ "$UNINSTALL" -eq 1 ]; then
  step "Удаление opencode"
  rm -f "$BIN_DIR/$APP" "$BIN_DIR/opencode2" "$SHIM_DIR/$APP" "$SHIM_DIR/opencode2" \
        "$REAL_BIN" "$OC_HOME/install-termux.sh"
  rmdir "$LIBEXEC_DIR" "$SHIM_DIR" 2>/dev/null || true
  ok "Удалено (каталог $OC_HOME оставлен: rm -rf $OC_HOME)"
  exit 0
fi

# ── 1b. Проверки окружения ─────────────────────────────────────────────────────
step "Проверка окружения"

if [ ! -d "$PREFIX" ] || ! printf '%s' "$PREFIX" | grep -q 'termux'; then
  die "Это не Termux (PREFIX=$PREFIX). Скрипт рассчитан на Termux / Android aarch64."
fi

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) ok "Архитектура: aarch64" ;;
  *) die "Архитектура $ARCH не поддерживается: opencode публикует сборки только под aarch64.
   На x86_64/Android-x86 ставьте x86_64-устройство или proot-окружение." ;;
esac

need_cmd curl curl
need_cmd tar  tar
need_cmd dd   coreutils   # точечная запись байтов в ELF
need_cmd od   coreutils   # чтение байтов
need_cmd wc   coreutils
# GNU tar зовёт внешний gzip для -z; в Termux он есть, но на всякий случай проверим
if ! command -v gzip >/dev/null 2>&1; then
  log "Ставлю gzip (нужен tar -z)"
  pkg install -y gzip >/dev/null 2>&1 || true
  command -v gzip >/dev/null 2>&1 || die "Нет gzip, а tar -xzf без него не работает: pkg install gzip"
fi
mkdir -p "$BIN_DIR" "$LIBEXEC_DIR" "$SHIM_DIR"


# ── 3. Зависимости: glibc ────────────────────────────────────────────────────
step "Зависимости (glibc)"

if find_loader && [ -f "$(dirname "$LOADER")/libc.so.6" ]; then
  ok "glibc уже установлен: $LOADER"
else
  if ! dpkg -s glibc-runner >/dev/null 2>&1; then
    log "Подключаю репозиторий glibc-repo"
    pkg install -y glibc-repo >/dev/null 2>&1 || warn "pkg install glibc-repo не отработал, пробую apt"
    apt update -qq >/dev/null 2>&1 || pkg update -y >/dev/null 2>&1 || true
  fi
  log "Ставлю glibc-runner (glibc, собранный под Termux)"
  if ! pkg install -y glibc-runner; then
    apt update -qq >/dev/null 2>&1 || true
    pkg install -y glibc-runner || die "Не удалось поставить glibc-runner.
   Проверьте сеть/репозитории и повторите. Альтернатива: bash opencode-termux.sh --method proot"
  fi
  find_loader || die "glibc установлен, но не найден ld-linux-aarch64.so.1 в $GLIBC_DIR"
  ok "glibc loader: $LOADER"
fi
# библиотеки лежат рядом с загрузчиком (ld.so и libc.so.6 в одном каталоге)
GLIBC_LIB="$(dirname "$LOADER")"
[ -f "$GLIBC_LIB/libc.so.6" ] || warn "Не найден $GLIBC_LIB/libc.so.6 — проверьте пакет glibc-runner"

# ── 4. Метод proot ───────────────────────────────────────────────────────────
if [ "$METHOD" = proot ]; then
  step "Метод proot (glibc-окружение целиком)"
  DISTRO=proot-distro
  need_cmd $DISTRO proot-distro
  $DISTRO list 2>/dev/null | grep -qi 'debian' || $DISTRO install debian
  log "Запускаю официальный установщик внутри Debian"
  $DISTRO login debian -- /bin/bash -c "curl -fsSL https://opencode.ai/v2/install | bash" \
    || die "Установка внутри proot не удалась"
  cat > "$BIN_DIR/$APP" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec $DISTRO login debian -- /root/.opencode/bin/$APP "\$@"
EOF
  chmod 755 "$BIN_DIR/$APP"
  ok "Готово: $BIN_DIR/$APP (proot + Debian)"
  exit 0
fi

# ── 5. Версия и tarball ───────────────────────────────────────────────────────
step "Определяю версию"

if [ -z "$REQ_VERSION" ]; then
  meta="$(curl -fsSL "$UPDATE_API")" || die "Не удалось получить $UPDATE_API"
  REQ_VERSION="$(printf '%s' "$meta" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
  scope_pkg="$(printf '%s' "$meta" | sed -n 's/.*"package":"\([^"]*\)".*/\1/p')"
  [ -n "$REQ_VERSION" ] || die "Не удалось распарсить версию из ответа API"
  NPM_SCOPE="${scope_pkg%/cli}"
  [ "$NPM_SCOPE" = "$scope_pkg" ] && NPM_SCOPE="@opencode"
fi
ok "Версия: $REQ_VERSION, пакет: $NPM_SCOPE/cli-$TARGET"

PKG_NAME="$NPM_SCOPE/cli-$TARGET"
VER_JSON="$REGISTRY/$NPM_SCOPE%2fcli-$TARGET/$REQ_VERSION"
ver_meta="$(curl -fsSL "$VER_JSON" 2>/dev/null)" || die "Версия $REQ_VERSION недоступна для $TARGET
   (нет сети или такой версии нет: https://www.npmjs.com/package/$PKG_NAME?activeTab=versions)"

TARBALL="$(printf '%s' "$ver_meta" | sed -n 's/.*"tarball":"\([^"]*\)".*/\1/p')"
INTEGRITY="$(printf '%s' "$ver_meta" | sed -n 's/.*"integrity":"\([^"]*\)".*/\1/p')"
SHASUM1="$(printf '%s' "$ver_meta" | sed -n 's/.*"shasum":"\([^"]*\)".*/\1/p')"
[ -n "$TARBALL" ] || die "Не удалось получить ссылку на tarball для $PKG_NAME@$REQ_VERSION"
log "tarball: $TARBALL"

if [ "$FORCE" -eq 0 ] && [ -x "$REAL_BIN" ]; then
  cur="$("$BIN_DIR/$APP" --version 2>/dev/null | sed 's/.* //' | tr -d 'v' || true)"
  if [ "$cur" = "$REQ_VERSION" ]; then
    ok "Уже установлена версия $cur. Используй --force для переустановки."
    exit 0
  fi
  log "Сейчас стоит: ${cur:-unknown}, ставлю: $REQ_VERSION"
fi

# хвосты прошлых неудачных запусков могут съедать сотни мегабайт
STALE_GLOB="${TMPDIR:-$PREFIX/tmp}/opencode-termux.*"
for stale in $STALE_GLOB; do
  [ -d "$stale" ] || continue
  rm -rf "$stale" 2>/dev/null && log "убрал хвост прошлой попытки: $stale"
done

WORK="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/opencode-termux.XXXXXX")"
log "Каталог: $WORK"

# ── 6. Проверка места ─────────────────────────────────────────────────────────
# Раскладка по диску во время установки (пик ~400 МБ):
#   обычный режим:  $WORK/cli.tgz ~86 МБ + $REAL_BIN.tmp ~191 МБ  → пик ~280 МБ
#   потоковый режим: curl | tar сразу в $REAL_BIN.tmp               → пик ~200 МБ
# (правка интерпретатора идёт на месте, второй копии не создаётся — проверено)
MIN_FREE_MB="${OPENCODE_MIN_FREE_MB:-300}"
MIN_FREE_STREAM_MB="${OPENCODE_MIN_FREE_STREAM_MB:-220}"
STREAM=0
work_parent="$(dirname "$WORK")"
avail_mb="$(df -Pk "$work_parent" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024}')"
if [ -n "$avail_mb" ]; then
  if [ "$avail_mb" -lt "$MIN_FREE_STREAM_MB" ]; then
    die "Не хватает места: нужно минимум ~${MIN_FREE_STREAM_MB} МБ, доступно ${avail_mb} МБ ($(df -Ph "$work_parent" | awk 'NR==2 {print $6}')).
   Что можно сделать:
     rm -rf ${TMPDIR:-$PREFIX/tmp}/opencode-termux.*   # хвосты прошлых попыток (до ~300 МБ)
     apt clean; apt autoremove -y                     # если ставил что-то через apt
     pkg uninstall <ненужные-пакеты>
   Или укажи временный каталог на partition с запасом места:
     TMPDIR=/путь/с/местом bash $0"
  elif [ "$avail_mb" -lt "$MIN_FREE_MB" ]; then
    STREAM=1
    warn "Места мало (${avail_mb} МБ) — включаю потоковый режим: качаю без сохранения tarball, сверка checksum пропускается"
  else
    ok "Свободно на диске: ${avail_mb} МБ"
  fi
fi

# ── 7. Скачивание + проверка целостности ──────────────────────────────────────
CURL_PROGRESS=(-fsSL)
[ -t 2 ] && CURL_PROGRESS=(-fL --progress-bar)

# проверка целостности: sha512 из registry, иначе sha1 (dist.shasum).
# openssl/base64 в Termux может не быть, sha1sum — всегда (coreutils).
verify_tarball() {
  [ "$SKIP_SUM" -eq 1 ] && { warn "Проверка контрольной суммы пропущена (--skip-checksum)"; return 0; }
  got=""
  case "$INTEGRITY" in
    sha512-*)
      want="${INTEGRITY#sha512-}"
      if command -v openssl >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
        got="$(openssl dgst -sha512 -binary "$WORK/cli.tgz" | base64 -w0 | tr -d '\n')"
      elif command -v python >/dev/null 2>&1; then
        got="$(python -c 'import base64,hashlib,sys
d=open(sys.argv[1],"rb").read()
sys.stdout.write(base64.b64encode(hashlib.sha512(d).digest()).decode())' "$WORK/cli.tgz")"
      fi
      if [ -n "$got" ]; then
        [ "$got" = "$want" ] || die "sha512 не совпал с npm registry — битый или подменённый tarball"
        ok "sha512 совпал с npm registry"
      else
        verify_sha1
      fi
      ;;
    *) verify_sha1 ;;
  esac
}
verify_sha1() {
  if [ "$SKIP_SUM" -eq 1 ]; then
    warn "Проверка контрольной суммы пропущена (--skip-checksum)"; return 0
  fi
  if [ -n "$SHASUM1" ] && command -v sha1sum >/dev/null 2>&1; then
    got="$(sha1sum "$WORK/cli.tgz" | cut -d' ' -f1)"
    [ "$got" = "$SHASUM1" ] || die "sha1 не совпал с npm registry ($got != $SHASUM1)"
    ok "sha1 совпал с npm registry"
  else
    warn "Нет чем проверить tarball (нужен openssl, python или sha1sum) — пропускаю"
  fi
}

# ── 8. Распаковка сразу в цель + патч интерпретатора ─────────────────────────
# Не распаковываем архив целиком и не делаем лишних копий: нужный файл пишется
# сразу в $REAL_BIN.tmp, а tarball удаляется сразу после распаковки.
step "Скачивание и распаковка (~200 МБ)"

if [ "$STREAM" -eq 1 ]; then
  ok "потоковый режим (tarball на диск не пишется)"
  curl "${CURL_PROGRESS[@]}" "$TARBALL" | tar -xz -O "package/bin/$APP" > "$REAL_BIN.tmp" \
    || { rm -f "$REAL_BIN.tmp"; die "Не удалось скачать/распаковать $TARBALL"; }
else
  curl "${CURL_PROGRESS[@]}" -o "$WORK/cli.tgz" "$TARBALL" \
    || curl -fsSL -o "$WORK/cli.tgz" "$TARBALL" \
    || die "Ошибка загрузки $TARBALL"
  ok "Скачано $(du -m "$WORK/cli.tgz" | cut -f1) МБ, сверяю контрольную сумму"
  verify_tarball
  tar -xzf "$WORK/cli.tgz" -O "package/bin/$APP" > "$REAL_BIN.tmp" \
    || { rm -f "$REAL_BIN.tmp" "$WORK/cli.tgz"; die "Не удалось распаковать $TARBALL"; }
  rm -f "$WORK/cli.tgz"
fi

step "Установка бинаря"

[ -s "$REAL_BIN.tmp" ] || { rm -f "$REAL_BIN.tmp"; die "В архиве нет package/bin/$APP"; }
if [ "$(LC_ALL=C od -An -tx1 -N4 "$REAL_BIN.tmp" | tr -d ' \n')" != "7f454c46" ]; then
  rm -f "$REAL_BIN.tmp"; die "распакованное — не ELF (возможно, tarball обрезан)"
fi
chmod 755 "$REAL_BIN.tmp"
ok "Распаковано $(du -m "$REAL_BIN.tmp" | cut -f1) МБ"

INTERP_OLD="$(elf_interp "$REAL_BIN.tmp" || true)"
log "было: $INTERP_OLD"

elf_set_interp "$REAL_BIN.tmp" "$LOADER" \
  || { rm -f "$REAL_BIN.tmp"; die "не удалось вписать интерпретатор $LOADER"; }

INTERP_NEW="$(elf_interp "$REAL_BIN.tmp" || true)"
[ "$INTERP_NEW" = "$LOADER" ] \
  || { rm -f "$REAL_BIN.tmp"; die "проверка интерпретатора не прошла (в бинаре: '$INTERP_NEW')"; }

# sanity: payload Bun'а (секция .bun) должна остаться на месте
if command -v readelf >/dev/null 2>&1; then
  if ! readelf -SW "$REAL_BIN.tmp" 2>/dev/null | grep -q '\.bun'; then
    warn "Секция .bun не найдена — сообщи об этом, если TUI не запустится"
  fi
fi

mv -f "$REAL_BIN.tmp" "$REAL_BIN"
ok "Бинарь: $REAL_BIN ($(du -h "$REAL_BIN" | cut -f1))"
ok "интерпретатор: $INTERP_NEW"
ok "библиотеки: $GLIBC_LIB (через LD_LIBRARY_PATH в обёртке)"

# ── 9. Обёртка ────────────────────────────────────────────────────────────────
step "Обёртка запуска"

# Обёртка нужна, чтобы: снять LD_PRELOAD от Termux (bionic .so ломает glibc-процесс),
# задать LD_LIBRARY_PATH на glibc и TMPDIR (в Android нет /tmp, а Bun распаковывает
# туда нативный модуль OpenTUI).
#
# `opencode upgrade` внутри заново запускает официальный installer и сносит наш патч,
# поэтому перехватываем его и переустанавливаем этим же скриптом.
SH_BIN="$(command -v sh)"
INSTALLER="$OC_HOME/install-termux.sh"
write_wrapper() {
  cat > "$1" <<EOF
#!$SH_BIN
# $APP launcher для Termux — создан opencode-termux.sh
PREFIX="\${PREFIX:-$PREFIX}"
REAL="\${OPENCODE_REAL:-$REAL_BIN}"
INSTALLER="\${OPENCODE_INSTALLER:-$INSTALLER}"

# встроенный upgrade снёс бы правку интерпретатора — переустанавливаем скриптом
if [ "\${OPENCODE_UPGRADE_HOOK:-1}" != 0 ] && [ "\${1:-}" = upgrade ] && [ -f "\$INSTALLER" ]; then
  shift
  if [ -n "\${1:-}" ]; then exec bash "\$INSTALLER" --force --version "\${1#v}"; fi
  exec bash "\$INSTALLER" --force
fi

# LD_LIBRARY_PATH задаём только для самого opencode (через env), иначе он утёк бы
# в bionic-процессы: Android'овская libc называется libc.so, и Termux-утилиты
# (cat, ls, grep) начали бы падать с "bad ELF magic".
# LD_PRELOAD из bionic .so тоже снимаем — по той же причине.
if [ -z "\${TMPDIR:-}" ]; then TMPDIR="\$PREFIX/tmp"; export TMPDIR; fi
[ -x "\$REAL" ] || { echo "$APP не найден: \$REAL" >&2; exit 127; }

# на Android фоновый сервер может быть убит seccomp (SIGSYS). Опция --standalone
# поднимает приватный сервер без фонового сервиса — обходим проблему.
if [ "\${OPENCODE_STANDALONE:-0}" = 1 ] && [ \$# -eq 0 ]; then set -- --standalone; fi

# не exec, а запуск с проверкой кода: так можно объяснить, что именно убило процесс
env -u LD_PRELOAD LD_LIBRARY_PATH="\$PREFIX/glibc/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" \
    "\$REAL" "\$@"
rc=\$?
if [ "\$rc" -gt 128 ] && [ "\$rc" -le 192 ]; then
  sig=\$((rc - 128))
  case "\$sig" in
    31) sig_name=SIGSYS ;;
    11) sig_name=SIGSEGV ;;
    6)  sig_name=SIGABRT ;;
    4)  sig_name=SIGILL ;;
    *)  sig_name="SIG\$sig" ;;
  esac
  {
    echo
    echo "opencode убит сигналом \$sig_name (exit \$rc)."
    if [ "\$sig" = 31 ]; then
      cat <<'MSG'
Это Android seccomp: система запрещает часть syscall'ов, а opencode их вызывает.
Что попробовать (по порядку):
  1) opencode --standalone      приватный сервер вместо фонового сервиса
  2) opencode mini              минимальный интерфейс, меньше зависимостей
  3) узнать заблокированный syscall:
       pkg install strace
       strace -f -o $PREFIX/tmp/oc.strace opencode serve
       tail -3 $PREFIX/tmp/oc.strace
MSG
    fi
  } >&2
fi
exit "\$rc"
EOF
  chmod 755 "$1"
}

write_wrapper "$BIN_DIR/$APP"
write_wrapper "$SHIM_DIR/$APP"
for d in "$BIN_DIR" "$SHIM_DIR"; do
  printf '#!/bin/sh\nexec "$(dirname "$0")/%s" "$@"\n' "$APP" > "$d/opencode2"
  chmod 755 "$d/opencode2"
done
ok "$BIN_DIR/$APP"
ok "$SHIM_DIR/$APP"

# копия установщика — нужна, чтобы `opencode upgrade` продолжал работать
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  cp -f "${BASH_SOURCE[0]}" "$INSTALLER" 2>/dev/null && chmod 755 "$INSTALLER" \
    && ok "копия установщика: $INSTALLER" \
    || warn "не смог сохранить копию установщика (opencode upgrade будет обычным)"
else
  warn "скрипт запущен не из файла (curl|bash?) — сохраните его: opencode upgrade будет обычным"
fi

# PATH: $PREFIX/bin уже в PATH Termux; ~/.opencode/bin добавляем в rc профиля
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || continue
  if grep -Fq "$SHIM_DIR" "$rc"; then
    log "PATH уже настроен в $(basename "$rc")"
  else
    printf '\n# opencode\nexport PATH="%s:$PATH"\n' "$SHIM_DIR" >> "$rc"
    ok "Добавил $SHIM_DIR в PATH ($(basename "$rc"))"
  fi
done

# ── 10. Проверка запуска ───────────────────────────────────────────────────────
step "Проверка"
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"

signal_name() {
  case "$1" in
    11) echo "SIGSEGV" ;; 31) echo "SIGSYS" ;; 6) echo "SIGABRT" ;; 4) echo "SIGILL" ;;
    9) echo "SIGKILL" ;; 8) echo "SIGFPE" ;; 7) echo "SIGBUS" ;;  *) echo "signal $1" ;;
  esac
}

run_check() { # $1 = команда для запуска; печатает версию или причину отказа
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then printf '%s' "$out"; return 0; fi
  if [ "$rc" -gt 128 ] && [ "$rc" -le 192 ]; then
    printf 'убит сигналом %s (exit %s), вывод: %s' "$(signal_name $((rc - 128)))" "$rc" "${out:-<пусто>}"
  else
    printf 'exit %s, вывод: %s' "$rc" "${out:-<пусто>}"
  fi
  return 1
}

if ver="$(run_check "$BIN_DIR/$APP" --version)"; then
  ok "запуск успешен: $ver"
else
  warn "Не удалось запустить: $ver"
  cat >&2 <<EOF

${RED}Что делать дальше${NC}
  1) Подробности (скопируй мне вывод):
       $LOADER --list $REAL_BIN | head -3
       LD_LIBRARY_PATH=$GLIBC_LIB $REAL_BIN --version; echo "exit=\$?"
  2) Fallback на glibc-окружение целиком (медленнее, но TUI гарантирован):
       bash $INSTALLER --method proot

${DIM}Частые причины:${NC}
  * SIGSYS — Android seccomp режет syscall'ы (pidfd_open/close_range) на старых ядрах
  * SIGSEGV — бинарь собран не под glibc или сломана правка интерпретатора
  * "error while loading shared libraries" — не установлен glibc:
        pkg install glibc-repo && pkg update && pkg install glibc-runner
  * чёрный экран TUI — не задан TMPDIR: TMPDIR=$PREFIX/tmp $APP
EOF
  exit 1
fi

cat <<EOF

${DIM}$APP $REQ_VERSION готов.${NC}

  cd ~/проект      # открыть каталог
  $APP              # запустить TUI
  $APP auth login   # авторизация

${DIM}Если Android убьёт фоновый сервер (SIGSYS / "invalid system call"):${NC}
  $APP --standalone      # приватный сервер вместо фонового сервиса
  $APP mini              # минимальный интерфейс
  # или навсегда: export OPENCODE_STANDALONE=1

${DIM}Файлы:${NC}
  $REAL_BIN   — настоящий бинарь (интерпретатор переписан на glibc)
  $BIN_DIR/$APP  — обёртка в \$PATH

${DIM}Обновить:${NC}  $APP upgrade            (перехватывается, патч сохраняется)
                   bash $INSTALLER --force   # то же самое вручную
${DIM}Удалить:${NC}   bash $INSTALLER --uninstall
${DIM}Fallback:${NC}  bash $INSTALLER --method proot

EOF