#!/usr/bin/env bash
# =============================================================================
# Verifica delle GitHub Action usate nei workflow
#   ERRORE  : action non fissata a uno SHA completo
#             repository dell'action archiviato (non piu' mantenuto)
#             SHA non trovato nel repository dell'action
#             runtime Node.js deprecato (node12, node16, node20)
#   AVVISO  : esiste una versione major piu' recente di quella usata
# Richiede la GitHub CLI autenticata (in CI: GH_TOKEN=${{ github.token }}).
# Uso: .github/scripts/check-actions.sh [file workflow...]
# =============================================================================
set -uo pipefail

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=(.github/workflows/*.yml)
fi

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
errors=0
warnings=0

err()  { echo "::error title=Action non conforme::$1"; errors=$((errors + 1)); }
warn() { echo "::warning title=Action obsoleta::$1"; warnings=$((warnings + 1)); }

{
  echo "### Verifica delle action"
  echo
  echo "| Action | Versione | Runtime | Ultima release | Esito |"
  echo "|---|---|---|---|---|"
} >> "$summary"

# Estrae le righe "uses: owner/repo[/path]@ref  # vX" (senza duplicati)
mapfile -t entries < <(
  grep -hE '^[[:space:]-]*uses:' "${files[@]}" \
    | sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/[[:space:]]+$//' \
    | sort -u
)

for entry in "${entries[@]}"; do
  spec="${entry%%[[:space:]]*}"                       # owner/repo/path@ref
  comment=$(sed -nE 's/.*#[[:space:]]*(.*)$/\1/p' <<< "$entry")

  # Action locali o immagini Docker: fuori dallo scope di questo controllo
  case "$spec" in ./*|docker://*) continue ;; esac

  action="${spec%@*}"
  ref="${spec#*@}"
  repo=$(cut -d/ -f1-2 <<< "$action")
  subpath=$(cut -d/ -f3- -s <<< "$action")
  result="OK"

  if ! [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    err "$action@$ref non e' fissata a uno SHA completo (un tag puo' essere spostato)"
    result="non fissata"
  fi

  if [ "$(gh api "repos/$repo" --jq .archived 2>/dev/null)" = "true" ]; then
    err "$repo e' archiviato: l'action non e' piu' mantenuta"
    result="archiviata"
  fi

  # Legge action.yml (o action.yaml) alla versione esatta usata
  manifest=""
  for name in action.yml action.yaml; do
    manifest=$(gh api "repos/$repo/contents/${subpath:+$subpath/}$name?ref=$ref" \
      --jq .content 2>/dev/null | base64 -d 2>/dev/null) && [ -n "$manifest" ] && break
  done

  runtime="?"
  if [ -z "$manifest" ]; then
    err "$action@$ref: SHA o percorso non trovati nel repository dell'action"
    result="non trovata"
  else
    runtime=$(grep -m1 -E '^[[:space:]]+using:' <<< "$manifest" \
      | sed -E "s/.*using:[[:space:]]*['\"]?([^'\" ]+).*/\1/")
    case "$runtime" in
      node12|node16|node20)
        err "$action ($comment) usa il runtime deprecato $runtime: aggiornare a una versione node24"
        result="runtime deprecato"
        ;;
    esac
  fi

  latest=$(gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null || echo "-")
  current_major=$(grep -oE '^v?[0-9]+' <<< "$comment" | tr -d v)
  latest_major=$(grep -oE '^v?[0-9]+' <<< "$latest" | tr -d v)
  if [ -n "$current_major" ] && [ -n "$latest_major" ] && [ "$latest_major" -gt "$current_major" ]; then
    warn "$action: usata $comment, disponibile $latest"
    [ "$result" = "OK" ] && result="aggiornabile"
  fi

  echo "| \`$action\` | ${comment:--} | $runtime | $latest | $result |" >> "$summary"
  printf '%-45s %-10s %-10s %-12s %s\n' "$action" "${comment:--}" "$runtime" "$latest" "$result"
done

echo
echo "Errori: $errors - Avvisi: $warnings"
{ echo; echo "**Errori:** $errors - **Avvisi:** $warnings"; } >> "$summary"
[ "$errors" -eq 0 ]
