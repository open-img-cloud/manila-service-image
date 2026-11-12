#!/usr/bin/env bash
# DIB build hook called by the build-dib-image reusable workflow.
# Receives: $1 = output dir, $2 = version (OpenStack series, e.g. "2026.2").
# Must produce: $1/manila-service-image-${version}-amd64.qcow2
#
# Builds the service image of the Manila "generic" driver (NFS + CIFS) from
# openstack/manila-image-elements, the same element set as upstream's
# `manila-image-create` default build (`tox -e buildimage`, used by the
# upstream gate and by tarballs.opendev.org).
#
# We call `disk-image-create` directly instead of `bin/manila-image-create`
# because the wrapper insists on the `qemu-system` metapackage on Ubuntu
# hosts (every QEMU architecture, only needed for its own dependency check)
# and bakes the password "manila" into the image by default. To stay in sync
# with upstream, the script reads the element list from the wrapper and
# fails if it no longer matches ours.
#
# Container expected: ubuntu:24.04 (debootstrap for the ubuntu-minimal
# element), privileged, as root. See release.yml.

set -euo pipefail

OUT_DIR="${1:?usage: dib-build.sh <output-dir> <version>}"
VERSION="${2:?usage: dib-build.sh <output-dir> <version>}"

# --- Defaults (edit here: the reusable workflow does not forward env) -----
# manila-image-elements has no stable branches (branchless, master only,
# last tag 1.3.0 in 2017). Pin a reviewed commit for reproducible builds;
# bump it by hand when upstream changes (git ls-remote ... refs/heads/master).
MIE_REF="${MIE_REF:-ff7320c0fd003c60db9955f7b54d4d76605ad7b4}"   # master, 2026-09-06
MIE_REPO="${MIE_REPO:-https://opendev.org/openstack/manila-image-elements.git}"
MANILA_IMG_OS_VER="${MANILA_IMG_OS_VER:-jammy}"   # upstream gate default; noble untested upstream
MANILA_IMG_ARCH="${MANILA_IMG_ARCH:-amd64}"
MANILA_USER="${MANILA_USER:-manila}"   # fetch-public-ssh-keys.sh hardcodes "manila"
DHCP_TIMEOUT="${DHCP_TIMEOUT:-300}"

# Expected element list, mirrored from bin/manila-image-create (share proto
# "default" = NFS + CIFS, distro ubuntu).
OUR_REQUIRED=( manila-ssh vm manila-ubuntu-minimal dhcp-all-interfaces )
OUR_OPTIONAL=( ubuntu-nfs ubuntu-cifs )

if [[ ! "$VERSION" =~ ^[0-9]{4}\.[0-9]+$ ]]; then
  echo "::error::version '$VERSION' is not an OpenStack series (YYYY.N)" >&2
  exit 1
fi
if [[ "$MANILA_USER" != "manila" ]]; then
  echo "::error::MANILA_USER must stay 'manila': the manila-ssh element fetches the SSH key for that user only" >&2
  exit 1
fi

echo "[dib-build] out_dir=$OUT_DIR version=$VERSION mie_ref=$MIE_REF release=$MANILA_IMG_OS_VER arch=$MANILA_IMG_ARCH"

# --- Build prerequisites (Ubuntu container, running as root) --------------
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  qemu-utils git kpartx debootstrap python3-venv python3-pip \
  ca-certificates jq curl xz-utils e2fsprogs dosfstools sudo gdisk util-linux

# --- Upper-constraints for diskimage-builder, per series ------------------
# The series only selects the constraints (diskimage-builder version) and
# labels the image; the guest content comes from the pinned MIE_REF.
UC_BASE="https://opendev.org/openstack/requirements/raw/branch"
UPPER_CONSTRAINTS_URL="${UPPER_CONSTRAINTS_URL:-}"
if [[ -z "$UPPER_CONSTRAINTS_URL" ]]; then
  for ref in "stable/${VERSION}" "unmaintained/${VERSION}" "master"; do
    if curl -fsSI "${UC_BASE}/${ref}/upper-constraints.txt" >/dev/null 2>&1; then
      UPPER_CONSTRAINTS_URL="${UC_BASE}/${ref}/upper-constraints.txt"
      break
    fi
  done
  if [[ -z "$UPPER_CONSTRAINTS_URL" ]]; then
    echo "::error::no upper-constraints found for ${VERSION}" >&2
    exit 1
  fi
fi
echo "[dib-build] upper_constraints=$UPPER_CONSTRAINTS_URL"

# --- manila-image-elements at the pinned ref ------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git init -q "$work/mie"
git -C "$work/mie" fetch -q --depth 1 "$MIE_REPO" "$MIE_REF"
git -C "$work/mie" checkout -q FETCH_HEAD
echo "[dib-build] manila-image-elements $(git -C "$work/mie" rev-parse HEAD)"

# Drift guard: upstream's wrapper must still use the same elements.
wrapper="$work/mie/bin/manila-image-create"
# shellcheck disable=SC2016  # literal $MANILA_IMG_OS from upstream's source
up_required=$(sed -nE 's/^\s*REQUIRED_ELEMENTS="(.*)"/\1/p' "$wrapper" \
  | sed 's/\$MANILA_IMG_OS/manila-ubuntu-minimal/')
if [[ "$up_required" != "${OUR_REQUIRED[*]}" ]]; then
  echo "::error::upstream REQUIRED_ELEMENTS changed: '$up_required' (expected '${OUR_REQUIRED[*]}'); review dib-build.sh" >&2
  exit 1
fi
# shellcheck disable=SC2016  # literal line from upstream's source
if ! grep -qF 'OPTIONAL_ELEMENTS="$OPTIONAL_ELEMENTS ${MANILA_DISTRO}-nfs ${MANILA_DISTRO}-cifs"' "$wrapper"; then
  echo "::error::upstream default (NFS + CIFS) element set changed; review dib-build.sh" >&2
  exit 1
fi

# --- diskimage-builder in a venv ------------------------------------------
python3 -m venv "$work/venv"
# shellcheck source=/dev/null
. "$work/venv/bin/activate"
pip install --upgrade pip
pip install -c "$UPPER_CONSTRAINTS_URL" diskimage-builder
echo "[dib-build] $(disk-image-create --version 2>&1 | tail -n1)"

# --- Environment, as set by manila-image-create ----------------------------
export ELEMENTS_PATH="$work/mie/elements"
export DIB_DEFAULT_INSTALLTYPE=package
export DIB_RELEASE="$MANILA_IMG_OS_VER"
export DIB_MANILA_USER_USERNAME="$MANILA_USER"
# No password: key-only access with the Nova keypair Manila creates
# (manila_service_keypair_name). Upstream's default image ships the
# password "manila", which a public image must not do.
export DIB_MANILA_USER_PASSWORD=""
export DIB_MANILA_USER_AUTHORIZED_KEYS=""
export DIB_DHCP_TIMEOUT="$DHCP_TIMEOUT"

# Same debootstrap workaround as octavia-amphora: minbase lacks gpgv, which
# the in-chroot `apt-get update` needs.
export DIB_DEBOOTSTRAP_EXTRA_ARGS='--include=gpgv,gnupg2,ca-certificates'
rm -rf "$HOME/.cache/image-create" || true

cd "$work"
CMD=( disk-image-create -t qcow2 -a "$MANILA_IMG_ARCH" -o manila-service-image
      "${OUR_OPTIONAL[@]}" "${OUR_REQUIRED[@]}" )
echo "[dib-build] running: ${CMD[*]}"
"${CMD[@]}"

# --- Hand the qcow2 to the workflow ----------------------------------------
final="${OUT_DIR}/manila-service-image-${VERSION}-${MANILA_IMG_ARCH}.qcow2"
mv manila-service-image.qcow2 "$final"
echo "[dib-build] produced $final"
ls -lh "$final"
