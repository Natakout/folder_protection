#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Ricardo Ferreira <rsfneg@gmail.com>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Starts/stops/tests the disposable Nextcloud instances defined in
# docker-compose.nc.yml, one per version, so Folder Protection can be checked
# against each Nextcloud release it declares (or might declare) in
# appinfo/info.xml's <nextcloud min-version=".." max-version=".."/>. See
# build/README.md.
#
#   build/nc-instance.sh up 33          # bring up NC33 + fixtures (first run is slow)
#   build/nc-instance.sh test 33        # unit + integration suites against it
#   build/nc-instance.sh down 33
#   build/nc-instance.sh down --all
#   build/nc-instance.sh ls             # versions, ports, running state
#
# Update VERSIONS/PORTS below to test a version outside this list.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSIONS=(31 32 33 34 35)
PORTS=(8100 8101 8102 8103 8104)

APP=/var/www/html/custom_apps/folder_protection

port_for() {
    local v="$1"
    for i in "${!VERSIONS[@]}"; do
        if [ "${VERSIONS[$i]}" = "$v" ]; then
            echo "${PORTS[$i]}"
            return
        fi
    done
    echo "unknown version: $v (known: ${VERSIONS[*]})" >&2
    exit 2
}

compose() {
    local v="$1"
    shift
    NC_VERSION="$v" NC_PORT="$(port_for "$v")" INFO_XML="$(info_xml_for "$v")" \
        docker compose -p "folderprot-nc$v" -f build/docker-compose.nc.yml "$@"
}

# Where the widened info.xml for a version lives. Under build/ rather than a
# temp dir because the container bind-mounts it by path and restarts with the
# daemon, so it has to outlive a reboot. Git-ignored.
info_xml_for() {
    echo "$PWD/build/.generated/info-nc$1.xml"
}

# Writes appinfo/info.xml with <nextcloud min-version max-version> set to
# exactly $1, and says so when that differs from what the real file declares.
widen_info_xml() {
    local v="$1" out declared lo hi
    out="$(info_xml_for "$v")"
    mkdir -p "$(dirname "$out")"
    sed -E "s#<nextcloud [^>]*/>#<nextcloud min-version=\"$v\" max-version=\"$v\"/>#" appinfo/info.xml > "$out"
    grep -q "min-version=\"$v\" max-version=\"$v\"" "$out" \
        || { echo "could not rewrite the <nextcloud> element of appinfo/info.xml" >&2; exit 1; }

    declared="$(sed -nE 's#.*<nextcloud min-version="([0-9.]+)" max-version="([0-9.]+)".*#\1 \2#p' appinfo/info.xml)"
    if [ -n "$declared" ]; then
        read -r lo hi <<< "$declared"
        if [ "$v" -lt "${lo%%.*}" ] || [ "$v" -gt "${hi%%.*}" ]; then
            echo "NOTE: NC $v is outside the range info.xml declares (${lo}-${hi}); this instance runs it with the range widened to $v so the app can be enabled and tested there" >&2
        fi
    fi
}

up() {
    local v="$1" container pass
    container="folderprot-nc$v-app"
    pass="folderprot-nc$v-verify"
    occ() { docker exec -u www-data "$container" php occ "$@"; }

    local existed=0
    docker inspect "$container" > /dev/null 2>&1 && existed=1

    widen_info_xml "$v"
    compose "$v" up -d
    # A single-file bind mount follows the file's inode. Anything that replaces
    # the widened copy or appinfo/info.xml on the host (git checkout/merge/
    # rebase, an editor's atomic save) leaves a running container looking at
    # the real file instead -- silently, and fatally for a version outside the
    # declared range. Recreating the app container (volumes persist) re-attaches
    # it. Not on the first `up`: nothing is stale yet and it would only race the
    # entrypoint's install.
    if [ "$existed" = 1 ]; then
        compose "$v" up -d --force-recreate --no-deps app
    fi

    # Docker creates the custom_apps/ mountpoint (for the app bind mount
    # below it) as root before the entrypoint runs, and that entrypoint does
    # not reliably chown a custom_apps it finds already existing back to
    # www-data -- seen on NC31 in share_audit_dashboard's matrix, where it left
    # the auto-install's own "is the writable apps path actually writable"
    # check failing permanently. Fix it ourselves, racing the entrypoint's own
    # install attempt with a short retry loop since the directory may not
    # exist yet in the first instant after `up -d` returns.
    for _ in $(seq 1 10); do
        docker exec "$container" chown www-data:root /var/www/html/custom_apps 2> /dev/null && break
        sleep 1
    done

    for _ in $(seq 1 60); do
        if occ status 2> /dev/null | grep -q 'installed: true'; then
            break
        fi
        sleep 5
    done
    # If the entrypoint's own install already gave up before our chown above
    # landed, it will not retry on its own -- do it ourselves.
    if ! occ status 2> /dev/null | grep -q 'installed: true'; then
        occ maintenance:install --database=mysql --database-host=db \
            --database-name=nextcloud --database-user=nextcloud --database-pass=nextcloud \
            --admin-user=ncadmin --admin-pass="$pass"
    fi

    # Bumping info.xml's <version> (every release does) leaves an instance that
    # already exists from an earlier `up` in "requires upgrade": occ then
    # refuses everything but `upgrade` itself, `app:enable` included.
    if occ status 2> /dev/null | grep -q 'needsDbUpgrade: true'; then
        occ upgrade
    fi

    occ app:enable folder_protection
    # Its setup modal blocks every click otherwise.
    occ app:disable firstrunwizard > /dev/null 2>&1 || true

    # Fixtures the integration suite needs: a group folder named `team` and an
    # external storage mounted at /exttest (three tests 404 without them).
    # groupfolders comes from the App Store so it is the build made for this
    # Nextcloud version. If there is none yet (a just-released Nextcloud), say
    # so and carry on: the suites will then show exactly which tests need it.
    #
    # Command output goes into variables and is matched afterwards: piping
    # occ straight into `grep -q` lets grep exit early and SIGPIPE occ, which
    # `pipefail` then reports as "no match" even when there was one.
    local out
    out="$(occ app:install groupfolders 2>&1)" || true
    echo "$out"
    if ! grep -qE 'installed' <<< "$out"; then
        echo "WARNING: groupfolders is not installable on NC $v -- team-folder tests will fail" >&2
    fi
    occ app:enable groupfolders > /dev/null 2>&1 || true
    out="$(occ groupfolders:list 2> /dev/null)" || true
    if ! grep -qw team <<< "$out"; then
        local gfid
        out="$(occ groupfolders:create team 2> /dev/null)" || true
        gfid="$(grep -oE '[0-9]+' <<< "$out" | head -1)" || true
        if [ -n "$gfid" ]; then
            occ groupfolders:group "$gfid" admin read write share delete > /dev/null
        else
            echo "WARNING: could not create the 'team' group folder on NC $v" >&2
        fi
    fi

    docker exec "$container" sh -c 'mkdir -p /tmp/nc-exttest && chown www-data:www-data /tmp/nc-exttest'
    occ app:enable files_external > /dev/null 2>&1 || true
    out="$(occ files_external:list 2> /dev/null)" || true
    if ! grep -q '/exttest' <<< "$out"; then
        occ files_external:create /exttest local null::null -c datadir=/tmp/nc-exttest > /dev/null \
            || echo "WARNING: could not create the /exttest external storage on NC $v" >&2
    fi

    echo "NC $v ready: http://localhost:$(port_for "$v")  (ncadmin / $pass)"
}

# Runs both suites and reports each one's outcome; exits non-zero if either
# failed. The suites run with the plain phpunit that ships in this app's own
# vendor/, against this instance's Nextcloud libraries.
test_version() {
    local v="$1" container pass rc=0
    container="folderprot-nc$v-app"
    pass="folderprot-nc$v-verify"

    echo "=== NC $v: unit ==="
    docker exec -w "$APP" "$container" \
        php vendor/bin/phpunit -c phpunit.xml --do-not-cache-result || rc=1

    echo "=== NC $v: integration ==="
    docker exec -w "$APP" \
        -e FP_TEST_PASSWORD="$pass" -e FP_TEST_BASE_URL=http://localhost \
        "$container" \
        php vendor/bin/phpunit -c phpunit.integration.xml --do-not-cache-result || rc=1

    return "$rc"
}

down() {
    compose "$1" down -v
    rm -f "$(info_xml_for "$1")"
}

ls_versions() {
    local v state
    for v in "${VERSIONS[@]}"; do
        # A missing container makes `docker inspect` print a blank line to
        # stdout before it fails, so check the trimmed result rather than
        # relying on `||` (that would append "stopped" after the blank line).
        # The trailing `|| true` keeps `set -e` from treating that failure
        # (under `pipefail`) as fatal.
        state="$(docker inspect -f '{{.State.Status}}' "folderprot-nc$v-app" 2> /dev/null | tr -d '[:space:]')" || true
        [ -z "$state" ] && state="stopped"
        printf 'NC %-4s port %-6s %s\n' "$v" "$(port_for "$v")" "$state"
    done
}

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
    up)
        [ $# -eq 1 ] || { echo "usage: $0 up <version>" >&2; exit 2; }
        port_for "$1" > /dev/null
        up "$1"
        ;;
    test)
        [ $# -eq 1 ] || { echo "usage: $0 test <version>" >&2; exit 2; }
        port_for "$1" > /dev/null
        test_version "$1"
        ;;
    down)
        if [ "${1:-}" = "--all" ]; then
            for v in "${VERSIONS[@]}"; do down "$v"; done
        else
            [ $# -eq 1 ] || { echo "usage: $0 down <version>|--all" >&2; exit 2; }
            down "$1"
        fi
        ;;
    ls) ls_versions ;;
    *) echo "usage: $0 {up|test|down} <version> | down --all | ls" >&2; exit 2 ;;
esac
