#!/usr/bin/env zsh
set -euo pipefail
setopt null_glob

repo_root=/srv/larsoyd
src_root=$repo_root/src
manifest_root=$repo_root/manifests
state_root=$repo_root/state/pkg-refresh
log_root=$repo_root/logs/pkg-refresh
repo_root_dir=$repo_root/repo
default_repo_name=larsoyd
arch=$(uname -m)

typeset -ga manifests

log() {
  print -- "==> $*"
}

warn() {
  print -u2 -- "==> WARN: $*"
}

die() {
  print -u2 -- "==> ERROR: $*"
  exit 1
}

timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

build_id_utc() {
  date -u +%Y%m%dT%H%M%SZ
}

discover_manifests() {
  manifests=("$manifest_root"/*.zsh(N))
}

load_manifest() {
  local manifest=$1

  unset PROJECT_ID ENABLED WORKTREE UPSTREAM_REMOTE UPSTREAM_BRANCH LOCAL_BRANCH REPO_NAME
  source "$manifest"

  : ${PROJECT_ID:?manifest missing PROJECT_ID: $manifest}
  : ${ENABLED:=1}
  : ${WORKTREE:=${manifest:h}}
  : ${UPSTREAM_REMOTE:=upstream}
  : ${UPSTREAM_BRANCH:=main}
  : ${LOCAL_BRANCH:=larsoyd/main}
  : ${REPO_NAME:=$default_repo_name}
}

packagelist_for_worktree() {
  local line
  local -a out=()

  while IFS= read -r line; do
    [[ -n $line ]] || continue
    [[ $line = /* ]] || line="$WORKTREE/$line"
    out+=("$line")
  done < <(cd "$WORKTREE" && makepkg --packagelist)

  print -rC1 -- $out
}

stage_latest_artifacts() {
  local project_id=$1
  shift

  local pool_dir="$repo_root_dir/pool/$arch"
  local latest_file="$state_root/$project_id/latest-packages"
  local pkg sig

  mkdir -p "$pool_dir" "$state_root/$project_id"
  : > "$latest_file"

  for pkg in "$@"; do
    [[ -f $pkg ]] || die "$project_id: missing built artifact: $pkg"

    install -m 644 "$pkg" "$pool_dir/${pkg:t}"
    print -r -- "$pool_dir/${pkg:t}" >> "$latest_file"

    sig="$pkg.sig"
    if [[ -f $sig ]]; then
      install -m 644 "$sig" "$pool_dir/${sig:t}"
    fi
  done
}

compose_repo() {
  local lockfile="$state_root/publish.lock"
  local build_id build_dir manifest latest_file pkg_path link_path sig_path
  local -a repo_pkgfiles=()

  mkdir -p "$state_root" "$repo_root_dir/builds"

  exec {publish_fd}> "$lockfile"
  flock "$publish_fd"

  build_id=$(build_id_utc)
  build_dir="$repo_root_dir/builds/$build_id/$arch"
  mkdir -p "$build_dir"

  discover_manifests

  for manifest in "${manifests[@]}"; do
    load_manifest "$manifest"
    (( ENABLED )) || continue

    latest_file="$state_root/$PROJECT_ID/latest-packages"
    [[ -f $latest_file ]] || continue

    while IFS= read -r pkg_path; do
      [[ -n $pkg_path ]] || continue
      [[ -e $pkg_path ]] || die "$PROJECT_ID: staged package missing from pool: $pkg_path"

      link_path="$build_dir/${pkg_path:t}"
      ln -sfn "../../../pool/$arch/${pkg_path:t}" "$link_path"
      [[ -e $link_path ]] || die "$PROJECT_ID: broken repo symlink: $link_path"

      case "$pkg_path" in
        (*.pkg.tar.*)
          repo_pkgfiles+=("$link_path")
          ;;
      esac

      sig_path="$pkg_path.sig"
      if [[ -e $sig_path ]]; then
        ln -sfn "../../../pool/$arch/${sig_path:t}" "$build_dir/${sig_path:t}"
      fi
    done < "$latest_file"
  done

  (( ${#repo_pkgfiles} > 0 )) || die "no package files available to compose $default_repo_name"

  repo-add "$build_dir/$default_repo_name.db.tar.zst" "${repo_pkgfiles[@]}"
  ln -sfn "builds/$build_id" "$repo_root_dir/current"

  print -r -- "$build_id"
}

refresh_project() {
  local manifest=$1
  local state_dir log_dir lockfile logfile
  local local_before upstream_head last_upstream last_local
  local -a pkgfiles
  local pkg new_build_id

  load_manifest "$manifest"
  (( ENABLED )) || return 0

  state_dir="$state_root/$PROJECT_ID"
  log_dir="$log_root/$PROJECT_ID"

  mkdir -p "$state_dir" "$log_dir"

  lockfile="$state_dir/refresh.lock"
  exec {project_fd}> "$lockfile"
  flock -n "$project_fd" || die "$PROJECT_ID: another refresh is already active"

  logfile="$log_dir/$(timestamp_utc).log"
  ln -sfn "$logfile" "$log_dir/last.log"

  {
    log "$PROJECT_ID: started at $(date -Is)"
    cd "$WORKTREE"

    git diff --quiet && git diff --cached --quiet || \
      die "$PROJECT_ID: working tree is dirty; regenerate .SRCINFO and commit or discard tracked changes first"

    if [[ $(git branch --show-current) != "$LOCAL_BRANCH" ]]; then
      git switch "$LOCAL_BRANCH"
    fi

    local_before=$(git rev-parse HEAD)

    git fetch --prune "$UPSTREAM_REMOTE"
    upstream_head=$(git rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")

    last_upstream=$(< "$state_dir/last-success-upstream" 2>/dev/null || true)
    last_local=$(< "$state_dir/last-success-local" 2>/dev/null || true)

    if [[ "$upstream_head" == "$last_upstream" && "$local_before" == "$last_local" ]]; then
      log "$PROJECT_ID: no upstream or local packaging changes"
      return 0
    fi

    log "$PROJECT_ID: rebasing $LOCAL_BRANCH onto $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
    if ! git rebase "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
      git rebase --abort || true
      die "$PROJECT_ID: rebase failed"
    fi

    log "$PROJECT_ID: cleaning repo"
    pkgctl repo clean

    pkgfiles=("${(@f)$(packagelist_for_worktree)}")
    (( ${#pkgfiles} > 0 )) || die "$PROJECT_ID: makepkg --packagelist returned no expected artifacts"

    log "$PROJECT_ID: building in clean chroot"
    pkgctl build

    for pkg in "${pkgfiles[@]}"; do
      [[ -f $pkg ]] || die "$PROJECT_ID: expected artifact missing: $pkg"
    done

    stage_latest_artifacts "$PROJECT_ID" "${pkgfiles[@]}"
    new_build_id=$(compose_repo)

    print -r -- "$upstream_head" > "$state_dir/last-success-upstream"
    print -r -- "$(git rev-parse HEAD)" > "$state_dir/last-success-local"

    log "$PROJECT_ID: published into repo build $new_build_id"
    log "$PROJECT_ID: current repo -> $(readlink -f "$repo_root_dir/current")"
  } > >(tee -a "$logfile") 2>&1
}

should_run_project() {
  local project_id=$1
  shift

  (( $# == 0 )) && return 0

  local wanted
  for wanted in "$@"; do
    [[ "$project_id" == "$wanted" ]] && return 0
  done

  return 1
}

list_projects() {
  local manifest

  discover_manifests
  (( ${#manifests} > 0 )) || die "no manifests found under $src_root"

  for manifest in "${manifests[@]}"; do
    load_manifest "$manifest"
    print -- "$PROJECT_ID"
  done
}

main() {
  local cmd=${1:-refresh}
  shift || true

  mkdir -p "$state_root" "$log_root" "$repo_root_dir/pool/$arch" "$repo_root_dir/builds"

  case "$cmd" in
    list)
      list_projects
      return 0
      ;;
    refresh)
      ;;
    *)
      set -- "$cmd" "$@"
      ;;
  esac

  discover_manifests
  (( ${#manifests} > 0 )) || die "no manifests found under $src_root"

  local manifest ran=0
  for manifest in "${manifests[@]}"; do
    load_manifest "$manifest"
    (( ENABLED )) || continue
    should_run_project "$PROJECT_ID" "$@" || continue
    refresh_project "$manifest"
    ran=1
  done

  (( ran )) || die "no matching enabled projects found"
}

main "$@"
