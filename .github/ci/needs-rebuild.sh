#!/bin/bash
# Does the scheduled run have anything new to publish?
#
#   .github/ci/needs-rebuild.sh <image>
#
# Writes to $GITHUB_OUTPUT:
#   build        true or false
#
# A push or a manual run always builds. A SCHEDULED run builds only when there is something to
# apply, because every image published as :latest restarts every server running it (FluxOS
# compares each app's tag digest every six hours and soft-redeploys onto a new one, with no
# warning in game), and a rebuild of unchanged inputs still gets a new digest.
#
# This image is built ON a third-party base, sknnr/enshrouded-dedicated-server, pinned by digest
# in the Dockerfile ("moving the base is a deliberate change, tested on a real server, never a
# side effect of a rebuild"), and the Dockerfile does not apt-get upgrade it: Wine is a pinned
# tarball, the game is Wine-run and tested against exactly that userland. So there is no
# "urgent security update" rule here: a rebuild would not apply one, and the base cannot move
# by itself. Security fixes for the base arrive when someone bumps the pin. The one rule:
#
#   pending       commits on main since the published :latest (its org.opencontainers.image.revision
#                 label) that touch the image inputs: the Dockerfile, VERSION, and every path a
#                 COPY/ADD takes. README, tests and .github changes do not count. A published image
#                 with no revision label counts as pending (one extra rebuild, after which it is
#                 labelled). Needs the full git history (actions/checkout fetch-depth: 0).
#   otherwise     nothing: :latest stays, and no server restarts
set -euo pipefail

image="${1:?image}"
out="${GITHUB_OUTPUT:-/dev/stdout}"

if [ "${GITHUB_EVENT_NAME:-}" != "schedule" ]; then
  echo "build=true" >>"${out}"
  echo "a ${GITHUB_EVENT_NAME:-manual} run: building"
  exit 0
fi

# A label of the published image (one platform, or the amd64 entry of a multi-platform one).
published_label() {
  docker buildx imagetools inspect "${image}:latest" --format '{{json .Image}}' 2>/dev/null \
    | jq -r --arg k "$1" 'if has("config") then . else ([to_entries[] | select(.key | test("amd64")) | .value][0] // {}) end
                          | .config.Labels[$k] // empty' || true
}

head_sha="$(git rev-parse HEAD)"
revision="$(published_label org.opencontainers.image.revision)"
pending=false
inputs=(Dockerfile VERSION)
while read -r line; do
  read -ra words <<<"${line}"
  words=("${words[@]:1}")
  sources=()
  for w in "${words[@]}"; do
    [[ "${w}" == --* ]] || sources+=("${w}")
  done
  unset 'sources[${#sources[@]}-1]'
  inputs+=("${sources[@]}")
# (A COPY continued with a trailing backslash is joined first.)
done < <(sed -e ':a' -e '/\\$/{N;s/\\\n/ /;ba}' Dockerfile | grep -E '^(COPY|ADD)[[:space:]]' | grep -v -- '--from=' || true)
if [ -z "${revision}" ]; then
  pending=true
  echo "the published image records no revision (built before this check): pending"
elif [ "${revision}" = "${head_sha}" ]; then
  echo "the published image was built from HEAD (${head_sha:0:12})"
elif ! git cat-file -e "${revision}^{commit}" 2>/dev/null; then
  pending=true
  echo "the published revision ${revision:0:12} is not in this checkout's history: pending"
else
  ahead="$(git rev-list --count "${revision}..${head_sha}" -- "${inputs[@]}")"
  if [ "${ahead}" -gt 0 ]; then
    pending=true
    echo "${ahead} commit(s) since the published ${revision:0:12} touch the image inputs (${inputs[*]})"
  else
    echo "no commit since the published ${revision:0:12} touches the image inputs (${inputs[*]})"
  fi
fi
echo "pending=${pending}"

if [ "${pending}" = true ]; then
  echo "build=true" >>"${out}"
else
  echo "nothing new: ${image}:latest stays as it is, and no server restarts"
  echo "build=false" >>"${out}"
fi
