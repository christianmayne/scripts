#!/usr/bin/env bash
#
# sync-site-to-local.sh - pull a live WordPress site's themes/plugins/
# mu-plugins (+ optionally uploads) and database down into a Local Site.
#
# Two stages, run in two different shells, for any site:
#
#   fetch    Run from WSL. SSHes to the server (via a Host alias from
#            ~/.ssh/config), tars up the wanted wp-content subfolders ON
#            THE SERVER and streams that one archive down (fast - avoids
#            per-file SSH overhead over thousands of small plugin/theme
#            files), extracts it, exports the database, then copies just
#            those subfolders into the Local site.
#
#   install  Run from THAT SITE'S OWN Site Shell in Local (right-click the
#            site -> Open Site Shell), not from WSL. That's the only place
#            `wp` is reliably pointed at the right local database, so this
#            stage has to run there. Imports the dump, rewrites URLs, and
#            (unless skipped) adds local-only wp-config overrides once.
#
# Run with -h/--help, or "fetch -h" / "install -h", for full usage.
#
set -euo pipefail

PROG="$(basename "$0")"

# Which wp-content subfolders fetch grabs by default. uploads is opt-in
# (--with-uploads) since it's usually the biggest and least essential for dev.
DEFAULT_DIRS=(themes plugins mu-plugins)

print_global_help() {
  cat <<EOF
$PROG - pull a live WordPress site into a Local Site

Usage:
  $PROG fetch   [options]    (run from WSL)
  $PROG install [options]    (run from the site's Local Site Shell)
  $PROG -h | --help

Run '$PROG fetch --help' or '$PROG install --help' for that stage's options.
EOF
}

print_fetch_help() {
  cat <<EOF
$PROG fetch - download themes/plugins/mu-plugins + a database dump from a
live site, fast: zipped up on the server first, pulled down as one file.

Required:
  --ssh-host <alias>      Host alias from ~/.ssh/config (e.g. jolt-folkquiz)
  --remote-path <path>    WordPress root on the server (where wp-cli runs)
  --local-path <path>     The Local Site's web root, e.g.
                           "/mnt/c/Users/you/Local Sites/sitename/app/public"

Optional:
  --with-uploads          Also grab wp-content/uploads (skipped by default -
                           usually the biggest, least essential dir for dev)
  --stage-dir <path>      Where to stage the download (default:
                           ~/site-syncs/<ssh-host>/<timestamp>)
  --exclude <pattern>     Extra tar --exclude pattern, repeatable (e.g. a
                           particular plugin's own cache folder)
  --skip-db               Only pull files, don't export/download the database
  --dry-run               List what would be archived on the server, download nothing

Example:
  $PROG fetch \\
    --ssh-host jolt-folkquiz \\
    --remote-path /home/CPANELUSER/public_html \\
    --local-path "/mnt/c/Users/christian/Local Sites/folkquiz/app/public" \\
    --with-uploads
EOF
}

print_install_help() {
  cat <<EOF
$PROG install - import a fetched database dump and fix up a Local site

Required:
  --dump <path>           Path to the db.sql.gz produced by 'fetch'
  --live-url <url>        The live site's URL, e.g. https://folkquiz.com
  --local-url <url>       The Local site's URL, e.g. http://folkquiz.local

Optional:
  --wp-path <path>        Run wp-cli against this path instead of the
                           current directory (default: .)
  --skip-wp-config        Don't add the local wp-config overrides
  --skip-search-replace   Don't rewrite URLs in the database

Notes:
  Must be run from that site's own Local Site Shell (Local -> right-click
  the site -> Open Site Shell), so wp-cli is pointed at the right database.

Example:
  $PROG install \\
    --dump ~/site-syncs/jolt-folkquiz/20260916-101500/db.sql.gz \\
    --live-url https://folkquiz.com \\
    --local-url http://folkquiz.local
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
cmd="${1:-}"
[ -n "$cmd" ] && shift || true

case "$cmd" in
  -h|--help|"")
    print_global_help
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
if [ "$cmd" = "fetch" ]; then

  ssh_host=""; remote_path=""; local_path=""; stage_dir=""
  extra_excludes=(); with_uploads=0; skip_db=0; dry_run=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) print_fetch_help; exit 0 ;;
      --ssh-host) ssh_host="$2"; shift 2 ;;
      --remote-path) remote_path="${2%/}"; shift 2 ;;
      --local-path) local_path="${2%/}"; shift 2 ;;
      --stage-dir) stage_dir="${2%/}"; shift 2 ;;
      --exclude) extra_excludes+=("$2"); shift 2 ;;
      --with-uploads) with_uploads=1; shift ;;
      --skip-db) skip_db=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      *) die "Unknown option '$1' (see '$PROG fetch --help')" ;;
    esac
  done

  [ -n "$ssh_host" ]    || die "--ssh-host is required"
  [ -n "$remote_path" ] || die "--remote-path is required"
  [ -n "$local_path" ]  || die "--local-path is required"

  [ -z "$stage_dir" ] && stage_dir="$HOME/site-syncs/$ssh_host/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$stage_dir"

  dirs=("${DEFAULT_DIRS[@]}")
  [ "$with_uploads" -eq 1 ] && dirs+=(uploads)

  # Build the remote tar command as a single string: --ignore-failed-read
  # means a dir that doesn't exist on this particular site (e.g. no
  # mu-plugins) is skipped rather than failing the whole archive.
  remote_cmd="cd '$remote_path/wp-content' && tar --ignore-failed-read -czf -"
  for e in "${extra_excludes[@]:-}"; do
    [ -n "$e" ] && remote_cmd="$remote_cmd --exclude='$e'"
  done
  for d in "${dirs[@]}"; do
    remote_cmd="$remote_cmd $d"
  done

  if [ "$dry_run" -eq 1 ]; then
    echo "==> Would archive on $ssh_host: ${dirs[*]}"
    echo "==> Remote command: $remote_cmd"
    ssh "$ssh_host" "cd '$remote_path/wp-content' && ls -la ${dirs[*]}"
    exit 0
  fi

  echo "==> Archiving ${dirs[*]} on $ssh_host and streaming it down"
  ssh "$ssh_host" "$remote_cmd" > "$stage_dir/wp-content.tar.gz"

  echo "==> Extracting"
  mkdir -p "$stage_dir/wp-content"
  tar xzf "$stage_dir/wp-content.tar.gz" -C "$stage_dir/wp-content"

  if [ "$skip_db" -eq 0 ]; then
    echo "==> Exporting the database from $ssh_host"
    ssh "$ssh_host" "wp --path=$remote_path db export -" | gzip > "$stage_dir/db.sql.gz"
  else
    echo "==> Skipping database export (--skip-db)"
  fi

  echo "==> Copying into the Local site (only the fetched subfolders)"
  for d in "${dirs[@]}"; do
    [ -d "$stage_dir/wp-content/$d" ] || continue
    mkdir -p "$local_path/wp-content/$d"
    rsync -a --delete "$stage_dir/wp-content/$d/" "$local_path/wp-content/$d/"
  done

  echo
  echo "Fetch done. Staged at: $stage_dir"
  if [ "$skip_db" -eq 0 ]; then
    echo
    echo "Next: open that site's Site Shell in Local, then run:"
    echo "  ./$PROG install --dump \"$stage_dir/db.sql.gz\" --live-url <live-url> --local-url <local-url>"
  fi

# ---------------------------------------------------------------------------
elif [ "$cmd" = "install" ]; then

  dump=""; live_url=""; local_url=""; wp_path="."
  skip_wp_config=0; skip_search_replace=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) print_install_help; exit 0 ;;
      --dump) dump="$2"; shift 2 ;;
      --live-url) live_url="$2"; shift 2 ;;
      --local-url) local_url="$2"; shift 2 ;;
      --wp-path) wp_path="${2%/}"; shift 2 ;;
      --skip-wp-config) skip_wp_config=1; shift ;;
      --skip-search-replace) skip_search_replace=1; shift ;;
      *) die "Unknown option '$1' (see '$PROG install --help')" ;;
    esac
  done

  [ -n "$dump" ]      || die "--dump is required"
  [ -f "$dump" ]      || die "No such file: $dump"
  [ -n "$live_url" ]  || die "--live-url is required"
  [ -n "$local_url" ] || die "--local-url is required"

  cd "$wp_path"

  echo "==> Importing database"
  gunzip -c "$dump" | wp db import -

  if [ "$skip_search_replace" -eq 0 ]; then
    echo "==> Rewriting URLs ($live_url -> $local_url)"
    wp search-replace "$live_url" "$local_url" --all-tables --skip-columns=guid
  fi

  if [ "$skip_wp_config" -eq 0 ]; then
    echo "==> Local-only wp-config tweaks"
    marker="local overrides (added by sync script)"
    if ! grep -qF "$marker" wp-config.php 2>/dev/null; then
      php -r '
        $marker = "// local overrides (added by sync script)";
        $extra  = "\n" . $marker . "\n"
                . "define(\"WP_ENVIRONMENT_TYPE\", \"local\");\n"
                . "define(\"DISABLE_WP_CRON\", true);\n";
        $path = "wp-config.php";
        $content = file_get_contents($path);
        $content = preg_replace(
          "/\/\*\s*That.s all, stop editing.*/s",
          $extra . "\n$0",
          $content,
          1
        );
        file_put_contents($path, $content);
      '
      echo "    added WP_ENVIRONMENT_TYPE + DISABLE_WP_CRON to wp-config.php"
    else
      echo "    already present, skipping"
    fi
  fi

  echo "==> Flushing cache"
  wp cache flush

  echo
  echo "Done. Site should now be live at $local_url"

else
  die "Unknown command '$cmd' (expected 'fetch' or 'install', see '$PROG --help')"
fi