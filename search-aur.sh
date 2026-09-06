#!/usr/bin/env bash
#
# search-aur.sh — busca en el metadata completo de AUR (packages-meta-ext-v1)
# con filtros combinables, score de riesgo de seguridad y deteccion de
# typosquatting (nombres que imitan a paquetes populares).
#
# Uso: ./search-aur.sh [opciones] [N]

set -euo pipefail

N=100
QUERY=""
MIN_VOTES=0
MIN_POP=0
OUTDATED_ONLY=0
ORPHANS_ONLY=0
MAINTAINER=""
LICENSE=""
SORT="popularity"
REVERSE=0

HTTP_ONLY=0
IP_ONLY=0
SHORT_ONLY=0
NOLICENSE=0
SPIKE_ONLY=0
RISKY_KW=0
RISK_MIN=0
TYPO_ONLY=0
TYPO_DIST=1
TYPO_MAX_VOTES=200
TYPO_SCAN=3000

usage() {
    cat <<EOF
Uso: $0 [opciones] [N]

Busca en el metadata de AUR con filtros combinables y lista los
primeros N resultados (default 100) segun el orden elegido.
Sobre cada resultado se muestra un "risk" (0 = sin senales); con
--risk se excluyen los de riesgo menor.

Busqueda general:
  -q <regex>   buscar en nombre + descripcion + keywords (regex, insensible a mayus)
  -v <n>       votos minimos (NumVotes >= n)
  -p <x>       popularidad minima (ej. 0.5)
  -s <campo>   ordenar por: name | popularity (default) | votes | modified
  -r           invertir el orden

Seguridad (metadata):
  -o           solo desactualizados (OutOfDate != null)
  -u           solo huerfanos (sin maintainer)
  -m <user>    solo de un maintainer (subcadena)
  -l <texto>   filtrar por licencia (subcadena)
  -i           solo con URL http:// (sin cifrar)
  -x           solo con URL apuntando a una IP directa
  --short      solo con URL a acortador/pastebin
  --nolicense  solo sin licencia declarada
  -c           solo paquetes recientes con popularidad alta (spike)
  -k           solo con keywords de riesgo (keygen, crack, wallet, ...)
  --risk <n>   risk score minimo (0-10), ademas se muestra la columna risk

Typosquatting (requiere python3):
  -y           solo paquetes con nombre similar a uno popular (sospechoso)
  -d <n>       distancia de edicion maxima (default 1; 2 para mas alcance)
  -w <n>       votos maximos para considerarse sospechoso (default 200)
  --typo-scan <n>  tamano del barrido de candidatos con -y (default 3000)

Otros:
  -h           esta ayuda

Ejemplos:
  $0 -q git -v 500 20
  $0 -k -y --risk 3 -v 10 20
  $0 -o -i -x -s modified 50
EOF
}

# --- Parser manual (soporta opciones largas y N posicional) ---
POSARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -q|--query)        QUERY="$2"; shift 2 ;;
        -v|--min-votes)    MIN_VOTES="$2"; shift 2 ;;
        -p|--min-pop)      MIN_POP="$2"; shift 2 ;;
        -o)                OUTDATED_ONLY=1; shift ;;
        -u)                ORPHANS_ONLY=1; shift ;;
        -m|--maintainer)   MAINTAINER="$2"; shift 2 ;;
        -l|--license)      LICENSE="$2"; shift 2 ;;
        -s|--sort)         SORT="$2"; shift 2 ;;
        -r|--reverse)      REVERSE=1; shift ;;
        -i|--http)         HTTP_ONLY=1; shift ;;
        -x|--ip)           IP_ONLY=1; shift ;;
        --short)           SHORT_ONLY=1; shift ;;
        --nolicense)       NOLICENSE=1; shift ;;
        -c|--spike)        SPIKE_ONLY=1; shift ;;
        -k|--risky)        RISKY_KW=1; shift ;;
        --risk)            RISK_MIN="$2"; shift 2 ;;
        -d|--typo-dist)    TYPO_DIST="$2"; shift 2 ;;
        -w|--typo-votes)   TYPO_MAX_VOTES="$2"; shift 2 ;;
        --typo-scan)       TYPO_SCAN="$2"; shift 2 ;;
        -y|--typo-only)    TYPO_ONLY=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; POSARGS+=("$@"); break ;;
        -*) echo "[-] Opcion desconocida: $1" >&2; exit 1 ;;
        *)  POSARGS+=("$1"); shift ;;
    esac
done

for a in "${POSARGS[@]}"; do
    if [[ "$a" =~ ^[0-9]+$ ]]; then
        N="$a"
        break
    fi
done

# --- Validaciones ---
case "$SORT" in
    name|popularity|votes|modified) ;;
    *) echo "[-] Orden invalido: $SORT (usa name|popularity|votes|modified)" >&2; exit 1 ;;
esac
[[ "$TYPO_DIST" =~ ^[0-9]+$ ]] || { echo "[-] -d/--typo-dist debe ser un entero >= 0" >&2; exit 1; }
[[ "$TYPO_MAX_VOTES" =~ ^[0-9]+$ ]] || { echo "[-] -w/--typo-votes debe ser un entero >= 0" >&2; exit 1; }
[[ "$TYPO_SCAN" =~ ^[0-9]+$ ]] || { echo "[-] --typo-scan debe ser un entero >= 0" >&2; exit 1; }
[[ "$RISK_MIN"  =~ ^[0-9]+$ ]] || { echo "[-] --risk debe ser un entero >= 0" >&2; exit 1; }

# Direccion por defecto: popularity/votes/modified descendente (top N),
# name ascendente. -r lo invierte.
if [[ "$SORT" == "name" ]]; then
    EFFECTIVE_REV="$REVERSE"
else
    EFFECTIVE_REV=$(( 1 - REVERSE ))
fi

# Con -y el barrido de typos usa una ventana amplia de candidatos (top
# TYPO_SCAN por popularidad con < TYPO_MAX_VOTES votos); sin -y se corta
# en el N pedido como siempre.
if (( TYPO_ONLY == 1 )); then
    LIMIT="$TYPO_SCAN"
else
    LIMIT="$N"
fi

TMPFILE="$(mktemp --suffix=.json.gz)"
trap 'rm -f "$TMPFILE"' EXIT

echo "Descargando metadata de AUR..." >&2
curl -fsS https://aur.archlinux.org/packages-meta-ext-v1.json.gz -o "$TMPFILE"

if (( TYPO_ONLY == 1 )); then
    echo "Resultados (scan $LIMIT, filtros: query='$QUERY' votos>=$MIN_VOTES pop>=$MIN_POP outd=$OUTDATED_ONLY orphans=$ORPHANS_ONLY maint='$MAINTAINER' lic='$LICENSE' http=$HTTP_ONLY ip=$IP_ONLY short=$SHORT_ONLY nolicense=$NOLICENSE spike=$SPIKE_ONLY risky=$RISKY_KW risk>=$RISK_MIN):" >&2
else
    echo "Resultados (max=$N filtros: query='$QUERY' votos>=$MIN_VOTES pop>=$MIN_POP outd=$OUTDATED_ONLY orphans=$ORPHANS_ONLY maint='$MAINTAINER' lic='$LICENSE' http=$HTTP_ONLY ip=$IP_ONLY short=$SHORT_ONLY nolicense=$NOLICENSE spike=$SPIKE_ONLY risky=$RISKY_KW risk>=$RISK_MIN):" >&2
fi

# --- Programa jq: defs de riesgos + filtros + orden + corte ---
JQPROG=$(cat <<'JQEOF'
def utxt: (.URL // "");
def searchtext: (.Name + " " + (.Description // "") + " " + ((.Keywords // []) | join(" ")));
def has_ip: (utxt | test("[0-9]{1,3}(\\.[0-9]{1,3}){3}"));
def is_short: (utxt | test("bit\\.ly|tinyurl\\.com|is\\.gd|t\\.co|pastebin\\.com|hastebin\\.com"));
def risky_kw: (searchtext | ascii_downcase
    | test("keygen|crack|activator|wallet|miner|stealer|backdoor|trojan|keylog|phish|\\brat\\b|cracked|bypass|cheat|license-key"));

def risk:
    (if ((.Maintainer // "") == "") then 1 else 0 end)
    + (if .OutOfDate != null then 1 else 0 end)
    + (if (utxt | test("^http://")) then 1 else 0 end)
    + (if has_ip then 2 else 0 end)
    + (if is_short then 2 else 0 end)
    + (if ((.License // []) | length) == 0 then 1 else 0 end)
    + (if (.FirstSubmitted > (now - $recent)) then 1 else 0 end);

def matches:
    (($q == "") or (searchtext | test($q; "i")))
    and (.NumVotes >= $v)
    and (.Popularity >= $p)
    and (($outdated == 0) or (.OutOfDate != null))
    and (($orphans == 0) or ((.Maintainer // "") == ""))
    and (($m == "") or ((.Maintainer // "") | contains($m)))
    and (($l == "") or ((((.License // []) | if type == "array" then join(" ") else . end) | contains($l))))
    and (($http == 0) or (utxt | test("^http://")))
    and (($ip == 0) or has_ip)
    and (($short == 0) or is_short)
    and (($nolic == 0) or (((.License // []) | length) == 0))
    and (($spike == 0) or ((.FirstSubmitted > (now - $recent)) and (.Popularity >= 1.0)))
    and (($risky == 0) or risky_kw)
    and (risk >= $riskmin)
    and (($typonly == 0) or (.NumVotes < $w));

def sortkey:
    (if $s == "name" then .Name
     elif $s == "votes" then .NumVotes
     elif $s == "modified" then .LastModified
     else .Popularity end);

map(select(matches))
| sort_by(sortkey)
| (if $rev == 1 then reverse else . end)
| .[:$limit][]
| {Name, Version, Popularity, NumVotes, OutOfDate, Maintainer, Description, risk: risk}
JQEOF
)

# --- Deteccion de typosquatting (python3, opcional) ---
PYSCRIPT=$(cat <<'PYEOF'
import json, sys

DIST = int(sys.argv[1])
ONLY = sys.argv[2] == "1"
MAX_VOTES = int(sys.argv[3])
OUTPUT_LIMIT = int(sys.argv[4])
MIN_LEN = 4

SFX = {"git", "bin", "static", "latest", "nightly", "svn", "hg", "bzr", "cvs", "meta", "nox"}

def norm(name):
    parts = name.lower().split("-")
    while parts and parts[-1] in SFX:
        parts.pop()
    return "-".join(parts)

REFS = [
    "1password", "alacritty", "android-studio", "anki", "audacity", "bitwarden",
    "blender", "brave", "btop", "cargo", "chromium", "discord", "docker",
    "eclipse", "emacs", "ffmpeg", "firefox", "fish", "ghostty", "gimp", "git",
    "github-cli", "go", "golang", "google-chrome", "heroic", "htop", "hyprland",
    "inkscape", "intellij", "jdk", "java", "keepassxc", "kitty", "krita",
    "kubectl", "libreoffice", "lutris", "mpv", "neovim", "nodejs", "npm",
    "notion", "obs-studio", "obsidian", "openjdk", "opera", "pip", "pnpm",
    "podman", "pycharm", "python", "python3", "qemu", "rust", "signal",
    "slack", "spotify", "starship", "steam", "sublime-text", "sway",
    "telegram", "teams", "tmux", "vim", "virtualbox", "vivaldi", "vlc",
    "vmware", "vscode", "waybar", "wezterm", "whatsapp", "wine", "yarn", "zsh",
]

def lev(a, b):
    if len(a) < len(b):
        return lev(b, a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]

printed = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    n = norm(obj.get("Name", ""))
    typo = None
    if n not in REFS and len(n) >= MIN_LEN and int(obj.get("NumVotes") or 0) < MAX_VOTES:
        best, bd = None, DIST + 1
        for r in REFS:
            d = lev(n, r)
            if d < bd:
                bd, best = d, r
        if bd <= DIST:
            typo = best
    obj["typo_of"] = typo
    if not ONLY or typo is not None:
        print(json.dumps(obj, indent=2, ensure_ascii=False))
        printed += 1
        if ONLY and printed >= OUTPUT_LIMIT:
            break
if ONLY and printed == 0:
    print("[-] No se detectaron posibles typosquats en el barrido "
          "(prueba -d 2 o -w %d)" % MAX_VOTES, file=sys.stderr)
PYEOF
)

if command -v python3 >/dev/null 2>&1; then
    gunzip -c "$TMPFILE" | jq -c \
        --argjson limit "$LIMIT" \
        --arg q "$QUERY" \
        --argjson v "${MIN_VOTES:-0}" \
        --argjson p "${MIN_POP:-0}" \
        --argjson outdated "$OUTDATED_ONLY" \
        --argjson orphans "$ORPHANS_ONLY" \
        --arg m "$MAINTAINER" \
        --arg l "$LICENSE" \
        --arg s "$SORT" \
        --argjson rev "$EFFECTIVE_REV" \
        --argjson http "$HTTP_ONLY" \
        --argjson ip "$IP_ONLY" \
        --argjson short "$SHORT_ONLY" \
        --argjson nolic "$NOLICENSE" \
        --argjson spike "$SPIKE_ONLY" \
        --argjson risky "$RISKY_KW" \
        --argjson riskmin "${RISK_MIN:-0}" \
        --argjson recent $((60 * 86400)) \
        --argjson typonly "$TYPO_ONLY" \
        --argjson w "$TYPO_MAX_VOTES" \
        "$JQPROG" \
        | python3 -c "$PYSCRIPT" "$TYPO_DIST" "$TYPO_ONLY" "$TYPO_MAX_VOTES" "$N"
else
    if (( TYPO_ONLY == 1 )); then
        echo "[-] -y/--typo-only requiere python3 (no esta instalado)" >&2
        exit 1
    fi
    echo "[~] aviso: python3 no disponible; se omite la deteccion de typosquatting" >&2
    gunzip -c "$TMPFILE" | jq -c \
        --argjson limit "$LIMIT" \
        --arg q "$QUERY" \
        --argjson v "${MIN_VOTES:-0}" \
        --argjson p "${MIN_POP:-0}" \
        --argjson outdated "$OUTDATED_ONLY" \
        --argjson orphans "$ORPHANS_ONLY" \
        --arg m "$MAINTAINER" \
        --arg l "$LICENSE" \
        --arg s "$SORT" \
        --argjson rev "$EFFECTIVE_REV" \
        --argjson http "$HTTP_ONLY" \
        --argjson ip "$IP_ONLY" \
        --argjson short "$SHORT_ONLY" \
        --argjson nolic "$NOLICENSE" \
        --argjson spike "$SPIKE_ONLY" \
        --argjson risky "$RISKY_KW" \
        --argjson riskmin "${RISK_MIN:-0}" \
        --argjson recent $((60 * 86400)) \
        --argjson typonly "$TYPO_ONLY" \
        --argjson w "$TYPO_MAX_VOTES" \
        "$JQPROG"
fi