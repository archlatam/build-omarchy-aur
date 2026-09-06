#!/usr/bin/env bash
#
# scan-pkgbuild.sh — escaneo estatico del PKGBUILD, scripts y artefactos AUR
# en busca de inyeccion de codigo malicioso. Aborta (exit != 0) si detecta
# patrones de red flag. Se ejecuta DENTRO del contenedor, ANTES de makepkg.
# Escanea: PKGBUILD + *.install + *.patch + *.sh
#
# Uso: scan-pkgbuild.sh <directorio-del-paquete> [--json]
#
# Bloqueo automatico: cualquier patron "duro" aborta el build. Los patrones
# "blandos" solo imprimen aviso (el autor del PKGBUILD puede usarlos de forma
# legitima, p.ej. npm run build en build()).

set -euo pipefail

PKGDIR=""
JSON_OUTPUT=0

for arg in "$@"; do
    case "$arg" in
        --json) JSON_OUTPUT=1 ;;
        *) PKGDIR="$arg" ;;
    esac
done

: "${PKGDIR:?uso: scan-pkgbuild.sh <directorio-del-paquete> [--json]}"
[[ -d "$PKGDIR" ]] || { echo "[-] No existe el directorio: $PKGDIR"; exit 1; }

# Archivos a escanear
FILES=()
[[ -f "$PKGDIR/PKGBUILD" ]] && FILES+=("$PKGDIR/PKGBUILD")
for f in "$PKGDIR"/*.install; do
    [[ -f "$f" ]] && FILES+=("$f")
done
for f in "$PKGDIR"/*.patch; do
    [[ -f "$f" ]] && FILES+=("$f")
done
for f in "$PKGDIR"/*.sh; do
    [[ -f "$f" ]] && FILES+=("$f")
done

if (( ${#FILES[@]} == 0 )); then
    echo "[-] No hay PKGBUILD/*.install/*.patch en $PKGDIR"
    exit 1
fi

echo "[scan] Analizando: ${FILES[*]}" >&2

# Se combinaran todos los archivos en un unico stream para el grep.
CONCAT="$(mktemp)"
trap 'rm -f "$CONCAT"' EXIT
for f in "${FILES[@]}"; do
    {
        echo "===== FILE: $f ====="
        cat "$f"
    } >> "$CONCAT"
done

# ==== Patrones duros: abortan el build si aparecen. ====
HARD_PATTERNS=(
    # pipas de descarga a interprete: curl/wget ... | (sh|bash|python|node)
    '\b(curl|wget|fetch)\b[^|]*\|\s*\b(sh|bash|python[0-9.]*|node)\b'
    '\b(curl|wget)\b.*(--insecure|-k\b)'
    '\b(curl|wget)\b.*--no-check-certificate'
    # decode / reconstruccion de cadenas ofuscadas
    'base64[[:space:]]+(-d|--decode|-D)'
    '\bxxd[[:space:]]+-r'
    '\bopenssl\b.*\b(enc|dgst)\b[[:space:]]'
    # evaluadores de codigo embebido
    '\beval[[:space:]]+'
    '\bbash[[:space:]]+-c[[:space:]]+'
    '\bsh[[:space:]]+-c[[:space:]]+'
    '\bpython[0-9.]*\b[[:space:]]+-c[[:space:]]+'
    '\bnode[[:space:]]+-e[[:space:]]+'
    '\bperl[[:space:]]+-e[[:space:]]+'
    '\benv[[:space:]]+(-i)?[[:space:]]*bash[[:space:]]+-c'
    # descarga de un script y ejecucion inmediata/local
    '\b(curl|wget)\b.*-o[[:space:]]+[^[:space:]]*\.(sh|py|js|pl)'
    '(^|/)\.[a-z_]*/.+\.(sh|py|js)[[:space:]]+$'
    # canales de exfiltracion / shell remota
    '\bnc[[:space:]]+-e'
    '>\s*/dev/tcp/|>\s*/dev/udp/'
    '\bmkfifo\b'
    # escritura/reemplazo de arranque y privilegios
    '>\s*/etc/passwd|>\s*/etc/shadow|>\s*/etc/sudoers'
    'usermod[[:space:]]+(-a|-g)[[:space:]]+[^[:space:]]*(sudo|wheel)'
    # secuestro de PATH / LD_PRELOAD
    'LD_PRELOAD|DYLD_INSERT_LIBRARIES'
    # lectura de datos sensibles del entorno
    '~/.ssh|[a-zA-Z_]+\$HOME[^;]*\.ssh|\$HOME[^;]*/.?bash_history|\$HOME[^;]*/.gnupg'
    'cat[[:space:]]+~/\.ssh|/.ssh/(id_rsa|authorized_keys)'
    # NUEVO: URLs a acortadores o pastebins como fuente (source=()) — vector
    # clasico para redirigir descargas sin que el PKGBUILD delate el destino real
    'source=.*\b(bit\.ly|tinyurl\.com|is\.gd|t\.co|pastebin\.com/raw|hastebin\.com)\b'
    # NUEVO: fuente apuntando directo a una IP en vez de un dominio
    'source=.*https?://[0-9]{1,3}(\.[0-9]{1,3}){3}'
)

# ==== Patrones blandos: solo avisan (posible uso legitimo). ====
SOFT_PATTERNS=(
    # permisos SUID/SGID: legitimo en navegadores (chrome-sandbox),
    # revisar que el binario con setuid sea de confianza
    'setuid|setgid|chmod[[:space:]]+[0-7]?4[0-7]{2}'
    # npm/pip instalando desde URL externa no declarada en source=()
    '(npm|yarn|pnpm)[[:space:]]+(install|i)[[:space:]].*(https?://)'
    '(pip|pip3|pipx)[[:space:]]+install[[:space:]].*(https?://|git\+)'
    # ejecucion de scripts de proyecto descargados (necesario a veces, revisar)
    'npm[[:space:]]+run[[:space:]]+(build|start)'
    '\./configure[[:space:]]+.*(--prefix)'
    # NUEVO: checksums desactivados fuera de fuentes VCS (git/hg/svn/bzr).
    # Legítimo para *-git, sospechoso en cualquier otro tipo de paquete.
    "sha(256|384|512)sums=\\('SKIP'\\)|md5sums=\\('SKIP'\\)"
    # NUEVO: llamadas de red dentro de pkgver() — corren ANTES del build(),
    # fuera del control de ISOLATE=1, y son faciles de pasar por alto
    'pkgver\(\)[[:space:]]*\{[^}]*\b(curl|wget|git ls-remote)\b'
)

HARD_MATCHES=0
SOFT_MATCHES=0
declare -a HARD_HITS=()
declare -a SOFT_HITS=()

for p in "${HARD_PATTERNS[@]}"; do
    if grep -nE "$p" "$CONCAT" >/dev/null 2>&1; then
        HARD_MATCHES=1
        HARD_HITS+=("$p")
        if (( JSON_OUTPUT == 0 )); then
            echo "[scan][BLOQUEO] Patron duro detectado: ${p}"
            grep -nE "$p" "$CONCAT"
        fi
    fi
done

for p in "${SOFT_PATTERNS[@]}"; do
    if grep -nE "$p" "$CONCAT" >/dev/null 2>&1; then
        SOFT_MATCHES=1
        SOFT_HITS+=("$p")
        if (( JSON_OUTPUT == 0 )); then
            echo "[scan][aviso] Patron blando detectado: ${p}"
            grep -nE "$p" "$CONCAT"
        fi
    fi
done

# Excepcion: checksums SKIP es normal en paquetes *-git/*-hg/*-svn/*-bzr.
# No lo removemos del reporte, pero no cuenta si el propio pkgname lo declara VCS.
if grep -qE "^pkgname=.*-(git|hg|svn|bzr)" "$CONCAT" 2>/dev/null; then
    :  # nota: se deja constancia via SOFT_HITS igual, revision manual decide
fi

if (( JSON_OUTPUT == 1 )); then
    printf '{"package_dir":"%s","hard_blocked":%s,"soft_warnings":%s,"hard_patterns":[' \
        "$PKGDIR" \
        "$([[ $HARD_MATCHES == 1 ]] && echo true || echo false)" \
        "$([[ $SOFT_MATCHES == 1 ]] && echo true || echo false)"
    for i in "${!HARD_HITS[@]}"; do
        (( i > 0 )) && printf ','
        printf '"%s"' "$(printf '%s' "${HARD_HITS[$i]}" | sed 's/"/\\"/g')"
    done
    printf '],"soft_patterns":['
    for i in "${!SOFT_HITS[@]}"; do
        (( i > 0 )) && printf ','
        printf '"%s"' "$(printf '%s' "${SOFT_HITS[$i]}" | sed 's/"/\\"/g')"
    done
    printf ']}\n'
fi

if (( HARD_MATCHES == 1 )); then
    if (( JSON_OUTPUT == 0 )); then
        echo
        echo "[scan][✗] SE BLOQUEA el build: patrones de alto riesgo en el paquete."
        echo "[scan] No se compilara. Revisa el PKGBUILD manualmente antes de continuar."
    fi
    exit 1
fi

if (( JSON_OUTPUT == 0 )); then
    if (( SOFT_MATCHES == 1 )); then
        echo "[scan][~] Se avisaron patrones blandos; no bloquean pero requieren revision."
    else
        echo "[scan][✓] Sin patrones de inyeccion de alto riesgo."
    fi
fi

exit 0
