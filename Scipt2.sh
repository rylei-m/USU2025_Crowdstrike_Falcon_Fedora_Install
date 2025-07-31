#!/bin/bash

VERSION="1.8.0"

print_usage() {
    cat <<EOF

Usage: $0 [-h|--help]

Installs and configures the CrowdStrike Falcon Sensor for Linux.
Version: $VERSION

Run with environment variables documented separately.
EOF
}

# Help flag
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    print_usage
    exit 0
fi

main() {
    if [ "$GET_ACCESS_TOKEN" = "true" ]; then
        get_oauth_token
        echo "$cs_falcon_oauth_token"
        exit 0
    fi

    if [ "${FALCON_DOWNLOAD_ONLY}" = "true" ]; then
        echo -n 'Downloading Falcon Sensor ... '
        local download_destination
        download_destination=$(cs_sensor_download_only)
        echo '[ Ok ]'
        echo "Falcon Sensor downloaded to: $download_destination"
        exit 0
    fi

    echo -n 'Check if Falcon Sensor is running ... '
    cs_sensor_is_running
    echo '[ Not present ]'

    echo -n 'Falcon Sensor Install  ... '
    cs_sensor_install
    echo '[ Ok ]'

    if [ -z "$FALCON_INSTALL_ONLY" ] || [ "$FALCON_INSTALL_ONLY" = "false" ]; then
        echo -n 'Falcon Sensor Register ... '
        cs_sensor_register
        echo '[ Ok ]'
        echo -n 'Falcon Sensor Restart  ... '
        cs_sensor_restart
        echo '[ Ok ]'
    fi

    if [ "$PREP_GOLDEN_IMAGE" = "true" ]; then
        echo -n 'Prepping Golden Image  ... '
        cs_golden_image_prep
        echo '[ Ok ]'
        echo 'Falcon Sensor is ready for golden image creation.'
    else
        echo 'Falcon Sensor installed successfully.'
    fi
}

cs_sensor_is_running() {
    if pgrep -u root falcon-sensor >/dev/null 2>&1; then
        echo "sensor is already running... exiting"
        exit 0
    fi
}

cs_sensor_restart() {
    if type systemctl >/dev/null 2>&1; then
        systemctl restart falcon-sensor
    elif type service >/dev/null 2>&1; then
        service falcon-sensor restart
    else
        die "Could not restart falcon sensor"
    fi
}

cs_sensor_install() {
    local tempdir package_name
    tempdir=$(mktemp -d)

    tempdir_cleanup() { rm -rf "$tempdir"; }
    trap tempdir_cleanup EXIT

    get_oauth_token

    # Fedora workaround: pretend it's RHEL 9 for installer lookup
    if [ "$os_name" = "Fedora" ]; then
        cs_os_name="*RHEL*"
        cs_os_version="9"
    fi

    package_name=$(cs_sensor_download "$tempdir")
    os_install_package "$package_name"
    tempdir_cleanup
}

cs_sensor_download_only() {
    local destination_dir
    destination_dir="${FALCON_DOWNLOAD_PATH:-$PWD}"
    get_oauth_token
    cs_sensor_download "$destination_dir"
}

os_install_package() {
    local pkg="$1"
    check_package_manager_lock

    rpm_install_package() {
        local pkg="$1"
        cs_falcon_gpg_import
        if type dnf >/dev/null 2>&1; then
            dnf install -q -y "$pkg" || rpm -ivh --nodeps "$pkg"
        elif type yum >/dev/null 2>&1; then
            yum install -q -y "$pkg" || rpm -ivh --nodeps "$pkg"
        elif type zypper >/dev/null 2>&1; then
            zypper --quiet install -y "$pkg" || rpm -ivh --nodeps "$pkg"
        else
            rpm -ivh --nodeps "$pkg"
        fi
    }

    case "${os_name}" in
        Amazon | CentOS* | Oracle | RHEL | Rocky | AlmaLinux | SLES | Fedora)
            rpm_install_package "$pkg"
            ;;
        Debian | Ubuntu)
            DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "$pkg" >/dev/null
            ;;
        *)
            die "Unrecognized OS: ${os_name}"
            ;;
    esac
}

cs_golden_image_prep() {
    local wait_time=60
    local sleep_interval=5
    local aid

    get_aid() {
        /opt/CrowdStrike/falconctl -g --aid | awk -F '"' '{print $2}'
    }

    aid=$(get_aid)
    while [ -z "$aid" ]; do
        if [ "$wait_time" -le 0 ]; then
            echo '[ Failed ]'
            die "Failed to retrieve existing AID. Please check the sensor status."
        fi
        sleep "$sleep_interval"
        wait_time=$((wait_time - sleep_interval))
        aid=$(get_aid)
    done

    /opt/CrowdStrike/falconctl -d -f --aid >/dev/null

    if [ -n "$cs_falcon_token" ]; then
        /opt/CrowdStrike/falconctl -s -f --provisioning-token="$cs_falcon_token" >/dev/null
    fi
}

check_package_manager_lock() {
    lock_file="/var/lib/rpm/.rpm.lock"
    lock_type="RPM"
    local timeout=300 interval=5 elapsed=0

    if type dpkg >/dev/null 2>&1; then
        lock_file="/var/lib/dpkg/lock"
        lock_type="DPKG"
    fi

    while lsof -w "$lock_file" >/dev/null 2>&1; do
        if [ $elapsed -eq 0 ]; then
            echo ""
            echo "Package manager is locked. Waiting up to ${timeout} seconds for lock to be released..."
        fi
        if [ $elapsed -ge $timeout ]; then
            echo "Timed out waiting for ${lock_type} lock to be released after ${timeout} seconds."
            lsof -w "$lock_file" || true
            die "Installation aborted due to package manager lock timeout."
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo "Retrying again in ${interval} seconds..."
    done
}

cs_falcon_gpg_import() {
    tempfile=$(mktemp)
    cat >"$tempfile" <<EOF
-----BEGIN PGP PUBLIC KEY BLOCK-----
<REDACTED FOR BREVITY>
-----END PGP PUBLIC KEY BLOCK-----
EOF
    rpm --import "$tempfile"
    rm "$tempfile"
}

die() {
    echo "Fatal error: $*" >&2
    exit 1
}

# Script entry point
main "$@"