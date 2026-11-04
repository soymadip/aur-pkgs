#!/usr/bin/env bash
set -uo pipefail

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN not set}"
ASSIGNEE="${GITHUB_REPOSITORY_OWNER:-soymadip}"

GH_API="https://api.github.com"
GL_API="https://gitlab.com/api/v4"

vcs_suffix_re='(-git|-hg|-bzr|-svn)$'
overall_status=0

find_open_update_issues() {
	local pkg="$1"
	local page=1
	local response
	local issue_count

	while :; do
		if ! response=$(curl -fsS \
			-H "Authorization: Bearer $TOKEN" \
			-H "Accept: application/vnd.github+json" \
			"$GH_API/repos/$REPO/issues?state=open&per_page=100&page=$page"); then
			echo "[WARN] failed to list open issues while checking $pkg" >&2
			return 1
		fi

		if ! jq -e 'type == "array"' >/dev/null <<<"$response"; then
			echo "[WARN] GitHub returned an invalid issue list while checking $pkg" >&2
			return 1
		fi

		jq -c --arg pkg "$pkg" '.[] |
			select(.pull_request == null and
				(.title == ("Update available: " + $pkg) or
				 (.title | startswith("Update available: " + $pkg + " ")) or
				 (.title | startswith("Update available: " + $pkg + "("))))' <<<"$response"

		issue_count=$(jq 'length' <<<"$response")
		((issue_count < 100)) && break
		((page++))
	done
}

close_update_issue() {
	local issue_number="$1"
	local reason="$2"
	local comment_body="$3"

	curl -fsS -X POST \
		-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
		"$GH_API/repos/$REPO/issues/$issue_number/comments" \
		-d "$(jq -n --arg b "$comment_body" '{body: $b}')" >/dev/null &&
	curl -fsS -X PATCH \
		-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
		"$GH_API/repos/$REPO/issues/$issue_number" \
		-d "$(jq -n --arg reason "$reason" '{state: "closed", state_reason: $reason}')" >/dev/null
}

# Prepare Step Summary Header
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	echo "## Upstream Version Check Results" >>"$GITHUB_STEP_SUMMARY"
	echo "| Package | Status | Local Version | Upstream Version | Action |" >>"$GITHUB_STEP_SUMMARY"
	echo "| :--- | :--- | :--- | :--- | :--- |" >>"$GITHUB_STEP_SUMMARY"
fi

shopt -s nullglob
for pkgbuild in pkgs/*/PKGBUILD; do
	pkgdir=$(dirname "$pkgbuild")
	pkgdirname=$(basename "$pkgdir")

	if [[ "$pkgdirname" =~ $vcs_suffix_re ]]; then
		echo "[SKIP] $pkgdirname: VCS package, no discrete release to track"
		[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⏭️ Skipped | N/A | N/A | VCS package |" >>"$GITHUB_STEP_SUMMARY"
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
		[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⚠️ Error | N/A | N/A | Failed to source PKGBUILD |" >>"$GITHUB_STEP_SUMMARY"
		overall_status=1
		continue
	fi

	pkgname=$(sed -n '1p' <<<"$vars")
	curver=$(sed -n '2p' <<<"$vars")
	url=$(sed -n '3p' <<<"$vars")

	if [[ -z "$url" ]]; then
		echo "[WARN] $pkgdirname: no \$url resolved from PKGBUILD, skipping"
		[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⚠️ Error | \`$curver\` | N/A | Missing \`\$url\` |" >>"$GITHUB_STEP_SUMMARY"
		continue
	fi

	clean_url="${url%/}"
	clean_url="${clean_url%.git}"

	host="" owner_repo="" custom_domain=""
	if [[ "$clean_url" =~ github\.com/([^/]+/[^/]+) ]]; then
		host="github"
		owner_repo="${BASH_REMATCH[1]}"
	elif [[ "$clean_url" =~ gitlab\.com/([^/]+/[^/]+) ]]; then
		host="gitlab"
		owner_repo="${BASH_REMATCH[1]}"
	elif [[ "$clean_url" =~ https?://([^/]+)/([^/]+/[^/]+) ]]; then
		host="gitea"
		custom_domain="${BASH_REMATCH[1]}"
		owner_repo="${BASH_REMATCH[2]}"
	else
		echo "[SKIP] $pkgdirname: \$url ($url) could not be parsed"
		[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⏭️ Skipped | \`$curver\` | N/A | Unrecognized host |" >>"$GITHUB_STEP_SUMMARY"
		continue
	fi

	latest=""
	latest_url=""

	case "$host" in
	github)
		resp=$(curl -s -w '\n%{http_code}' \
			-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
			"$GH_API/repos/$owner_repo/releases/latest")
		code=$(tail -n1 <<<"$resp")
		body=$(sed '$d' <<<"$resp")
		if [[ "$code" == "200" ]]; then
			latest=$(jq -r '.tag_name // empty' <<<"$body")
		elif [[ "$code" == "404" ]]; then
			tags=$(curl -s -H "Authorization: Bearer $TOKEN" "$GH_API/repos/$owner_repo/tags?per_page=1")
			latest=$(jq -r '.[0].name // empty' <<<"$tags")
		else
			echo "[WARN] $pkgdirname: GitHub API error ($code) checking $owner_repo"
			[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⚠️ Error | \`$curver\` | N/A | API Error HTTP $code |" >>"$GITHUB_STEP_SUMMARY"
			overall_status=1
			continue
		fi
		if [[ -n "$latest" ]]; then
			latest_url="https://github.com/$owner_repo/releases/tag/$latest"
		fi
		;;

	gitlab)
		enc_repo=$(sed 's/\//%2F/g' <<<"$owner_repo")
		resp=$(curl -s -w '\n%{http_code}' "$GL_API/projects/$enc_repo/releases?per_page=1")
		code=$(tail -n1 <<<"$resp")
		body=$(sed '$d' <<<"$resp")
		if [[ "$code" == "200" ]]; then
			latest=$(jq -r '.[0].tag_name // empty' <<<"$body")
		fi
		if [[ -z "$latest" || "$latest" == "null" ]]; then
			tags=$(curl -s "$GL_API/projects/$enc_repo/repository/tags?per_page=1")
			latest=$(jq -r '.[0].name // empty' <<<"$tags")
		fi
		if [[ -n "$latest" && "$latest" != "null" ]]; then
			latest_url="https://gitlab.com/$owner_repo/-/releases/$latest"
		fi
		;;

	gitea)
		resp=$(curl -s -w '\n%{http_code}' "https://$custom_domain/api/v1/repos/$owner_repo/releases?per_page=1")
		code=$(tail -n1 <<<"$resp")
		body=$(sed '$d' <<<"$resp")
		if [[ "$code" == "200" ]]; then
			latest=$(jq -r '.[0].tag_name // empty' <<<"$body")
		fi
		if [[ -z "$latest" || "$latest" == "null" ]]; then
			tags=$(curl -s "https://$custom_domain/api/v1/repos/$owner_repo/tags?per_page=1")
			latest=$(jq -r '.[0].name // empty' <<<"$tags")
		fi
		if [[ -n "$latest" && "$latest" != "null" ]]; then
			latest_url="https://$custom_domain/$owner_repo/releases/tag/$latest"
		fi
		;;
	esac

	if [[ -z "$latest" || "$latest" == "null" ]]; then
		echo "[WARN] $pkgdirname: no releases or tags found upstream ($owner_repo), skipping"
		[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ⚠️ Warning | \`$curver\` | N/A | No tags/releases found |" >>"$GITHUB_STEP_SUMMARY"
		continue
	fi

	clean_cur="${curver#*:}"
	clean_cur="${clean_cur#v}"
	clean_latest="${latest#v}"

	is_up_to_date=0
	if command -v vercmp >/dev/null 2>&1; then
		if (($(vercmp "$clean_latest" "$clean_cur") <= 0)); then
			is_up_to_date=1
		fi
	else
		if [[ "$clean_cur" == "$clean_latest" ]]; then
			is_up_to_date=1
		fi
	fi

	if ((is_up_to_date == 1)); then
		echo "[OK] $pkgdirname: up to date ($curver)"

		# Close every open update issue for this package since it is up to date.
		closed_issue_count=0
		existing_issues=$(find_open_update_issues "$pkgdirname") || overall_status=1
		while IFS= read -r existing_issue; do
			[[ -z "$existing_issue" ]] && continue
			existing_number=$(jq -r '.number' <<<"$existing_issue")
			echo "  -> closing resolved issue #$existing_number..."
			comment_body="Package \`$pkgdirname\` has been updated to \`$curver\`. Closing issue."
			if ! close_update_issue "$existing_number" completed "$comment_body"; then
				echo "[WARN] failed to close issue #$existing_number" >&2
				overall_status=1
			else
				((closed_issue_count++))
			fi
		done <<<"$existing_issues"

		action="None"
		((closed_issue_count > 0)) && action="Closed $closed_issue_count issue(s)"
		[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | ✅ Up to date | \`$curver\` | \`$latest\` | $action |" >>"$GITHUB_STEP_SUMMARY"
		continue
	fi

	echo "[OUTDATED] $pkgdirname: current=$curver latest=$latest"

	title="Update available: $pkgdirname"

	# Find existing open issue for this package
	existing_issue=$(find_open_update_issues "$pkgdirname" | head -n1)

	if [[ -n "$existing_issue" ]]; then
		existing_issue_number=$(jq -r '.number' <<<"$existing_issue")
		existing_issue_body=$(jq -r '.body // ""' <<<"$existing_issue")
		existing_issue_title=$(jq -r '.title // ""' <<<"$existing_issue")

		# If open issue already exists for this package version, skip creating a duplicate
		if [[ "$existing_issue_body" == *"$latest"* || "$existing_issue_title" == *"$latest"* ]]; then
			echo "  -> open issue #$existing_issue_number already exists for version $latest. Skipping creation."
			[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | 🚀 Outdated | \`$curver\` | \`$latest\` | Issue #$existing_issue_number already open |" >>"$GITHUB_STEP_SUMMARY"
			continue
		fi

		# Issue exists but is for an older upstream version, close it before opening a new one
		echo "  -> closing previous issue #$existing_issue_number for older version..."
		comment_body="Closing this issue as a newer upstream release (\`$latest\`) was detected."

		if ! close_update_issue "$existing_issue_number" not_planned "$comment_body"; then
			echo "[WARN] failed to close issue #$existing_issue_number" >&2
			overall_status=1
		fi
	fi

	# Build body with direct link to the release page and @mention trigger
	issue_body=$(
		cat <<EOF
**$pkgdirname** is out of date.

- Current \`pkgver\`: \`$curver\`
- Latest upstream ($host): [\`$latest\`]($latest_url)
- Upstream repo: $clean_url

---
_cc @$ASSIGNEE — opened automatically by CI._
EOF
	)

	# Create payload with assignees field
	payload=$(jq -n \
		--arg title "$title" \
		--arg body "$issue_body" \
		--arg assignee "$ASSIGNEE" \
		'{title: $title, body: $body, assignees: [$assignee]}')

	create_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
		-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
		"$GH_API/repos/$REPO/issues" -d "$payload")

	if [[ "$create_code" == "201" ]]; then
		echo "  -> opened new assigned issue"
		[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | 🚀 Outdated | \`$curver\` | \`$latest\` | Opened & assigned issue |" >>"$GITHUB_STEP_SUMMARY"
	else
		echo "  -> [WARN] failed to open issue (HTTP $create_code)"
		[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "| \`$pkgdirname\` | 🚀 Outdated | \`$curver\` | \`$latest\` | Issue creation failed |" >>"$GITHUB_STEP_SUMMARY"
		overall_status=1
	fi
done

exit "$overall_status"
