#!/usr/bin/env bash
#
# build-omarchy-aur.sh — compila un paquete AUR dentro de un contenedor
# Docker con Arch Linux (base-devel) y deposita el .pkg.tar.zst en el host,
# en el mismo directorio donde vive este script (build-omarchy-aur).
#
# Uso:
#   ./build-omarchy-aur.sh                build normal (con red)
#   ISOLATE=1 ./build-omarchy-aur.sh      2 fases; la compilacion va SIN red
#
# La firma GPG de los paquetes esta pendiente (por hacer).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="omarchy-aur-builder:latest"
SUDO=""
PREP_CID=""
PREP_IMAGE=""

# ---------------------------------------------------------------------------
# Docker: arranca el daemon si hace falta y resuelve el acceso al socket
# (si el usuario no esta en el grupo docker, cae a 'sudo docker').
# ---------------------------------------------------------------------------
if ! docker info >/dev/null 2>&1; then
    echo "[-] El daemon de Docker no responde; intento arrancarlo..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet docker || sudo systemctl start docker || true
        sleep 2
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "[-] Sin acceso al socket; usare 'sudo docker' (agrega tu usuario al grupo docker para evitarlo)."
        SUDO=sudo
    fi
fi

docker_cmd() {
    if [[ -n "$SUDO" ]]; then
        sudo docker "$@"
    else
        docker "$@"
    fi
}

docker_exists() {
    docker_cmd image inspect "$1" >/dev/null 2>&1
}

cleanup() {
    [[ -n "$PREP_CID" ]] && docker_cmd rm -f "$PREP_CID" >/dev/null 2>&1 || true
    [[ -n "$PREP_IMAGE" ]] && docker_cmd rmi -f "$PREP_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pedir y normalizar la URL del paquete.
# ---------------------------------------------------------------------------
read -rp "[?] URL o nombre del paquete AUR: " INPUT
INPUT="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$INPUT")"
[[ -n "$INPUT" ]] || { echo "[-] Entrada vacia."; exit 1; }

pkgname_from_url() {
    local raw="$1"
    if [[ "$raw" =~ ^[a-zA-Z0-9@._+-]+$ ]]; then
        echo "$raw"
        return
    fi
    raw="${raw%/}"
    echo "$(basename "${raw%.git}")"
}

PKGNAME="$(pkgname_from_url "$INPUT")"
if [[ ! "$PKGNAME" =~ ^[a-zA-Z0-9@._+-]+$ ]]; then
    echo "[-] No pude extraer un nombre de paquete valido de: $INPUT"
    exit 1
fi
echo "[?] Paquete objetivo: $PKGNAME"

# ---------------------------------------------------------------------------
# Imagen de build (solo una vez).
# ---------------------------------------------------------------------------
if ! docker_exists "$IMAGE"; then
    echo "[*] Construyendo imagen $IMAGE (primera ejecucion; tarda algo)..."
    docker_cmd build -t "$IMAGE" "$SCRIPT_DIR"
fi

# ---------------------------------------------------------------------------
# Bloque comun: clonar/actualizar el paquete y darle dueño al usuario build.
# ---------------------------------------------------------------------------
inner_clone() {
    cat <<'EOF_MARK'
set -euo pipefail
cd /res
if [[ -d "__PKGNAME__" ]]; then
    git -C "__PKGNAME__" pull --ff-only >/dev/null 2>&1 || true
else
    git clone "https://aur.archlinux.org/__PKGNAME__.git"
fi
chown -R build:build "/res/__PKGNAME__"
EOF_MARK
}

inner_presync() {
    cat <<'EOF_MARK'
pacman -Syu --noconfirm >/dev/null
EOF_MARK
}

inner_build() {
    cat <<'EOF_MARK'
/usr/local/bin/scan-pkgbuild.sh "/res/__PKGNAME__"
cd "/res/__PKGNAME__"
runuser -u build -- makepkg -s --noconfirm --nocheck
EOF_MARK
}

inner_prepare() {
    cat <<'EOF_MARK'
/usr/local/bin/scan-pkgbuild.sh "/res/__PKGNAME__"
cd "/res/__PKGNAME__"
runuser -u build -- makepkg -s -o --noconfirm
EOF_MARK
}

inner_build_offline() {
    cat <<'EOF_MARK'
/usr/local/bin/scan-pkgbuild.sh "/res/__PKGNAME__"
cd "/res/__PKGNAME__"
runuser -u build -- makepkg -f --noextract --nodeps --noconfirm --nocheck
EOF_MARK
}

# ---------------------------------------------------------------------------
# Ejecutar la construccion.
# ---------------------------------------------------------------------------
ISOLATE="${ISOLATE:-0}"

if [[ "$ISOLATE" == "1" ]]; then
    echo "[*] Modo ISOLATE: fase 1/2 — resuelvo dependencias y descargo fuentes (con red)..."

    PREP_IMAGE="omarchy-aur-builder:prepared-$$"
    PREP_CID="omarchy-aur-prep-$$"

    docker_cmd create --name "$PREP_CID" -v "$SCRIPT_DIR:/res" "$IMAGE" /bin/bash -c "sleep 3600" >/dev/null
    docker_cmd start "$PREP_CID" >/dev/null

    {
        inner_presync
        inner_clone
        inner_prepare
    } | sed "s/__PKGNAME__/$PKGNAME/g" | docker_cmd exec -i "$PREP_CID" /bin/bash -s

    echo "[*] Modo ISOLATE: congelo el contenedor (dependencias) e inicio fase 2/2 SIN red..."
    docker_cmd commit "$PREP_CID" "$PREP_IMAGE" >/dev/null
    docker_cmd rm -f "$PREP_CID" >/dev/null
    PREP_CID=""

    {
        inner_build_offline
    } | sed "s/__PKGNAME__/$PKGNAME/g" | docker_cmd run --rm -i --network=none \
        -v "$SCRIPT_DIR:/res" "$PREP_IMAGE" /bin/bash -s

    docker_cmd rmi "$PREP_IMAGE" >/dev/null 2>&1 || true
    PREP_IMAGE=""
else
    echo "[*] Construyendo en contenedor (con red)..."
    {
        inner_presync
        inner_clone
        inner_build
    } | sed "s/__PKGNAME__/$PKGNAME/g" | docker_cmd run --rm -i \
        -v "$SCRIPT_DIR:/res" "$IMAGE" /bin/bash -s
fi

# ---------------------------------------------------------------------------
# Reporte final: copia el paquete a la raiz del directorio del script y
# confirma que el contenedor ya fue eliminado.
# ---------------------------------------------------------------------------
echo
mapfile -t PKGS < <(find "$SCRIPT_DIR/$PKGNAME" -maxdepth 1 -name '*.pkg.tar.zst' -printf '%f\n' 2>/dev/null | sort -u)
if (( ${#PKGS[@]} == 0 )); then
    echo "[-] (no se generaron .pkg.tar.zst — revisa el log del build)"
    exit 1
fi

echo "[*] Copiando paquete(s) a la raiz de $SCRIPT_DIR ..."
for p in "${PKGS[@]}"; do
    cp -v "$SCRIPT_DIR/$PKGNAME/$p" "$SCRIPT_DIR/$p"
done

# Limpieza: se conserva solo lo trackeado en el repo AUR del paquete
# (PKGBUILD, .SRCINFO, *.install, *.sh, *.patch...). Se eliminan las sobras
# del build: fuentes descargadas, pkg/, src/ y el .pkg.tar.zst duplicado.
echo
if git -C "$SCRIPT_DIR/$PKGNAME" clean -fdx >/dev/null 2>&1; then
    git -C "$SCRIPT_DIR/$PKGNAME" checkout -- . >/dev/null 2>&1 || true
    echo "[*] Limpieza: conservado solo el PKGBUILD y sus archivos de compilacion; resto eliminado."
    git -C "$SCRIPT_DIR/$PKGNAME" ls-files | sed 's/^/    /'
else
    echo "[-] Aviso: no se pudo limpiar automaticamente $SCRIPT_DIR/$PKGNAME (no es un repo git?)."
fi

echo
echo "[*] Contenedor: eliminado (docker run --rm / rm -f del contenedor preparado)."
echo
echo "[*] Paquete(s) listos para instalar en el host:"
for p in "${PKGS[@]}"; do
    echo "    $SCRIPT_DIR/$p"
done
echo
echo "[*] Instalar:"
echo "    sudo pacman -U $SCRIPT_DIR/*.pkg.tar.zst"