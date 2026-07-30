#!/usr/bin/env bash
set -uo pipefail

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN not set}"

GH_API="https://api.github.com"
GL_API="https://gitlab.com/api/v4"

vcs_suffix_re='(-git|-hg|-bzr|-svn)$'
overall_status=0

# Prepare Step Summary Header
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "## Upstream Version Check Results" >> "$GITHUB_STEP_SUMMARY"
  echo "| Package | Status | Local Version | Upstream Version | Action |" >> "$GITHUB_STEP_SUMMARY"
  echo "| :--- | :--- | :--- | :--- | :--- |" >> "$GITHUB_STEP_SUMMARY"
fi

shopt -s nullglob
for pkgbuild in pkgs/*/PKGBUILD; do
  pkgdir=$(dirname "$pkgbuild")
  pkgdirname=$(basename "$pkgdir")

  if [[ "$pkgdirname" =~ $vcs_suffix_re ]]; then
    echo "[SKIP] $pkgdirname: VCS package, no discrete release to track"
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⏭️ Skipped | N/A | N/A | VCS package |" >> "$GITHUB_STEP_SUMMARY"
    continue
  fi

  # Safely source PKGBUILD and handle array-based pkgname
  vars=$(bash -c "
    set -e
    source '$pkgbuild' >/dev/null 2>&1
    p_name=\$(declare -p pkgname 2>/dev/null)
    if [[ \$p_name =~ '^declare -a' ]]; then
      p_out=\"\${pkgname[*]}\"
    else
      p_out=\"\$pkgname\"
    fi
    printf '%s\n' \"\$p_out\" \"\$pkgver\" \"\$url\"
  " 2>/dev/null)

  if [[ -z "$vars" ]]; then
    echo "[WARN] $pkgdirname: failed to source PKGBUILD, skipping"
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⚠️ Error | N/A | N/A | Failed to source PKGBUILD |" >> "$GITHUB_STEP_SUMMARY"
    overall_status=1
    continue
  fi

  pkgname=$(sed -n '1p' <<< "$vars")
  curver=$(sed -n '2p' <<< "$vars")
  url=$(sed -n '3p' <<< "$vars")

  if [[ -z "$url" ]]; then
    echo "[WARN] $pkgdirname: no \$url resolved from PKGBUILD, skipping"
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⚠️ Error | \`$curver\` | N/A | Missing \`\$url\` |" >> "$GITHUB_STEP_SUMMARY"
    continue
  fi

  clean_url="${url%/}"
  clean_url="${clean_url%.git}"

  host="" owner_repo="" custom_domain=""
  if [[ "$clean_url" =~ github\.com/([^/]+/[^/]+) ]]; then
    host="github"; owner_repo="${BASH_REMATCH[1]}"
  elif [[ "$clean_url" =~ gitlab\.com/([^/]+/[^/]+) ]]; then
    host="gitlab"; owner_repo="${BASH_REMATCH[1]}"
  elif [[ "$clean_url" =~ https?://([^/]+)/([^/]+/[^/]+) ]]; then
    host="gitea"; custom_domain="${BASH_REMATCH[1]}"; owner_repo="${BASH_REMATCH[2]}"
  else
    echo "[SKIP] $pkgdirname: \$url ($url) could not be parsed"
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⏭️ Skipped | \`$curver\` | N/A | Unrecognized host |" >> "$GITHUB_STEP_SUMMARY"
    continue
  fi

  latest=""
  case "$host" in
    github)
      resp=$(curl -s -w '\n%{http_code}' \
        -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
        "$GH_API/repos/$owner_repo/releases/latest")
      code=$(tail -n1 <<< "$resp"); body=$(sed '$d' <<< "$resp")
      if [[ "$code" == "200" ]]; then
        latest=$(jq -r '.tag_name // empty' <<< "$body")
      elif [[ "$code" == "404" ]]; then
        tags=$(curl -s -H "Authorization: Bearer $TOKEN" "$GH_API/repos/$owner_repo/tags?per_page=1")
        latest=$(jq -r '.[0].name // empty' <<< "$tags")
      else
        echo "[WARN] $pkgdirname: GitHub API error ($code) checking $owner_repo"
        [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⚠️ Error | \`$curver\` | N/A | API Error HTTP $code |" >> "$GITHUB_STEP_SUMMARY"
        overall_status=1
        continue
      fi
      ;;
    gitlab)
      enc_repo=$(sed 's/\//%2F/g' <<< "$owner_repo")
      resp=$(curl -s -w '\n%{http_code}' "$GL_API/projects/$enc_repo/releases?per_page=1")
      code=$(tail -n1 <<< "$resp"); body=$(sed '$d' <<< "$resp")
      if [[ "$code" == "200" ]]; then
        latest=$(jq -r '.[0].tag_name // empty' <<< "$body")
      fi
      if [[ -z "$latest" || "$latest" == "null" ]]; then
        tags=$(curl -s "$GL_API/projects/$enc_repo/repository/tags?per_page=1")
        latest=$(jq -r '.[0].name // empty' <<< "$tags")
      fi
      ;;
    gitea)
      resp=$(curl -s -w '\n%{http_code}' "https://$custom_domain/api/v1/repos/$owner_repo/releases?per_page=1")
      code=$(tail -n1 <<< "$resp"); body=$(sed '$d' <<< "$resp")
      if [[ "$code" == "200" ]]; then
        latest=$(jq -r '.[0].tag_name // empty' <<< "$body")
      fi
      if [[ -z "$latest" || "$latest" == "null" ]]; then
        tags=$(curl -s "https://$custom_domain/api/v1/repos/$owner_repo/tags?per_page=1")
        latest=$(jq -r '.[0].name // empty' <<< "$tags")
      fi
      ;;
  esac

  if [[ -z "$latest" || "$latest" == "null" ]]; then
    echo "[WARN] $pkgdirname: no releases or tags found upstream ($owner_repo), skipping"
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⚠️ Warning | \`$curver\` | N/A | No tags/releases found |" >> "$GITHUB_STEP_SUMMARY"
    continue
  fi

  clean_cur="${curver#*:}"
  clean_cur="${clean_cur#v}"
  clean_latest="${latest#v}"

  is_up_to_date=0
  if command -v vercmp >/dev/null 2>&1; then
    if (( $(vercmp "$clean_latest" "$clean_cur") <= 0 )); then
      is_up_to_date=1
    fi
  else
    if [[ "$clean_cur" == "$clean_latest" ]]; then
      is_up_to_date=1
    fi
  fi

  if (( is_up_to_date == 1 )); then
    echo "[OK] $pkgdirname: up to date ($curver)"
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | Up to date | \`$curver\` | \`$latest\` | None |" >> "$GITHUB_STEP_SUMMARY"
    continue
  fi

  echo "[OUTDATED] $pkgdirname: current=$curver latest=$latest"

  title="Update available: $pkgdirname"
  existing=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    "$GH_API/repos/$REPO/issues?state=open&per_page=100" \
    | jq -r --arg t "$title" '.[] | select(.title == $t) | .html_url' | head -n1)

  if [[ -n "$existing" ]]; then
    echo "  -> issue already open: $existing"
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | 🚀 Outdated | \`$curver\` | \`$latest\` | Issue open |" >> "$GITHUB_STEP_SUMMARY"
    continue
  fi

  issue_body=$(cat <<EOF
**$pkgdirname** is out of date.

- Current \`pkgver\`: \`$curver\`
- Latest upstream ($host): [\`$latest\`](https://$custom_domain${custom_domain:+$host.com}/$owner_repo)
- Upstream repo: $clean_url

_Opened automatically by the check-updates workflow._
EOF
)

  payload=$(jq -n --arg title "$title" --arg body "$issue_body" '{title: $title, body: $body}')
  create_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    "$GH_API/repos/$REPO/issues" -d "$payload")

  if [[ "$create_code" == "201" ]]; then
    echo "  -> opened new issue"
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | 🚀 Outdated | \`$curver\` | \`$latest\` | Opened issue |" >> "$GITHUB_STEP_SUMMARY"
  else
    echo "  -> [WARN] failed to open issue (HTTP $create_code)"
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | 🚀 Outdated | \`$curver\` | \`$latest\` | Issue creation failed |" >> "$GITHUB_STEP_SUMMARY"
    overall_status=1
  fi
done

exit "$overall_status"
