#!/bin/sh

mkdir -p "$HOME/.irods"
echo '{"irods_host": "swcacti1.unm.edu", "irods_port": 1247, "irods_user_name": "$IPLANT_USER", "irods_zone_name": "swcactiZone"}' | envsubst > "$HOME/.irods/irods_environment.json"

echo "export PATH=$PATH:/opt/conda/bin" >> ~/.bashrc

if [ -f "/data-store/swcactiZone/home/$IPLANT_USER/.gitconfig" ]; then
  cp "/data-store/swcactiZone/home/$IPLANT_USER/.gitconfig" "$HOME/"
fi

if [ -d "/data-store/swcactiZone/home/$IPLANT_USER/.ssh" ]; then
  cp -r "/data-store/swcactiZone/home/$IPLANT_USER/.ssh" "$HOME/"
fi

# Optional user init hook. The "User init script" app parameter reaches us as
# `--init-script <basename>`, so that parameter's "Argument option" field must
# be set to --init-script in the DE; leave it empty and only the bare value is
# passed, which this deliberately still accepts since this image declares no
# CMD, so argv is empty unless the DE supplied a parameter. VICE_INIT_SCRIPT
# does the same when testing outside the DE. A hook is capped at a flat two
# minutes, deliberately not configurable: the cap protects startup, and a knob
# to raise it would just be a knob to defeat it.
INIT_LOG="$HOME/.vice-init.log"
INIT_SCRIPT="${VICE_INIT_SCRIPT:-}"
hook=""

echo "run.sh args: $*" >> "$INIT_LOG"

# Shift one at a time. `shift 2` is a trap here: a parameter left blank in the
# DE arrives as a bare trailing --init-script, and shifting past the end is a
# no-op that spins forever.
while [ $# -gt 0 ]; do
  case "$1" in
    --init-script) INIT_SCRIPT="${2:-}" ;;
    *) [ -n "$INIT_SCRIPT" ] || INIT_SCRIPT="$1" ;;
  esac
  shift
done

if [ -n "$INIT_SCRIPT" ]; then
  # The CSI driver stages whichever file the user selects at this fixed path,
  # regardless of which directory in the data store it was picked from.
  hook="$HOME/data-store/data/input/$(basename "$INIT_SCRIPT")"
  if [ -f "$hook" ] && [ -r "$hook" ]; then
    echo "Running user init hook: $hook (log $INIT_LOG)"
    # `bash "$hook"` rather than `"$hook"`: the executable bit does not
    # survive the data store. A child process rather than sourcing: a sourced
    # hook could clobber this script.
    timeout --kill-after=10 120 bash "$hook" >> "$INIT_LOG" 2>&1
    status=$?
    case "$status" in
      0) ;;
      124|137) echo "init hook: timed out after 120s and was killed, continuing with defaults" | tee -a "$INIT_LOG" ;;
      *) echo "init hook: exited $status, continuing with defaults" | tee -a "$INIT_LOG" ;;
    esac
  else
    echo "init hook: no script staged at $hook" >> "$INIT_LOG"
  fi
fi

# Land in $HOME regardless of the container's actual working directory. The
# DE/K8s pod spec can (and does) override the image's own WORKDIR, so this is
# the only place that reliably lands the session in ~ either way.
cd "$HOME" || true

gomplate -f /nginx.conf.tmpl -o /etc/nginx/nginx.conf
# Drop privileges to rstudio user to run the services
sudo supervisord -c /etc/supervisor/supervisord.conf -n
