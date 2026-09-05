#!/usr/bin/env bash
#
# scan-pkgbuild.sh — escaneo estatico del PKGBUILD, scripts y artefactos AUR
# en busca de inyeccion de codigo malicioso. Aborta (exit != 0) si detecta
# patrones de red flag. Se ejecuta DENTRO del contenedor, ANTES de makepkg.
# Escanea: PKGBUILD + *.install + *.patch + *.sh
#
# Uso: scan-pkgbuild.sh <directorio-del-paquete>
#
# Bloqueo automatico: cualquier patron "duro" aborta el build. Los patrones
# "blandos" solo imprimen aviso (el autor del PKGBUILD puede usarlos de forma
# legitima, p.ej. npm run build en build()).

set -euo pipefail

PKGDIR="${1:?uso: scan-pkgbuild.sh <directorio-del-paquete>}"
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

echo "[scan] Analizando: ${FILES[*]}"

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
)

HARD_MATCHES=0
SOFT_MATCHES=0

for p in "${HARD_PATTERNS[@]}"; do
    if grep -nE "$p" "$CONCAT" >/dev/null 2>&1; then
        HARD_MATCHES=1
        echo "[scan][BLOQUEO] Patron duro detectado: ${p}"
        grep -nE "$p" "$CONCAT"
    fi
done

for p in "${SOFT_PATTERNS[@]}"; do
    if grep -nE "$p" "$CONCAT" >/dev/null 2>&1; then
        SOFT_MATCHES=1
        echo "[scan][aviso] Patron blando detectado: ${p}"
        grep -nE "$p" "$CONCAT"
    fi
done

if (( HARD_MATCHES == 1 )); then
    echo
    echo "[scan][✗] SE BLOQUEA el build: patrones de alto riesgo en el paquete."
    echo "[scan] No se compilara. Revisa el PKGBUILD manualmente antes de continuar."
    exit 1
fi

if (( SOFT_MATCHES == 1 )); then
    echo "[scan][~] Se avisaron patrones blandos; no bloquean pero requieren revision."
else
    echo "[scan][✓] Sin patrones de inyeccion de alto riesgo."
fi

exit 0