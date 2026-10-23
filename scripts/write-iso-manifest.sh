#!/bin/sh
# Write source and exact APK package versions for one built Veyra ISO.
set -eu

iso=${1:?usage: sh scripts/write-iso-manifest.sh ISO OUTPUT}
output=${2:?usage: sh scripts/write-iso-manifest.sh ISO OUTPUT}
[ -f "$iso" ] || { echo "ISO not found: $iso" >&2; exit 1; }

source_commit=${VEYRA_SOURCE_COMMIT:-unknown}
aports_commit=${VEYRA_APORTS_REVISION:-unknown}
appcenter_commit=${VEYRA_APPCENTER_REVISION:-unknown}
update_commit=${VEYRA_UPDATE_REVISION:-unknown}
glenv_commit=${VEYRA_GLENV_REVISION:-unknown}
veyra_version=${VEYRA_VERSION:-0.1.0-alpha.1+local}
alpine_version=${VEYRA_ALPINE_VERSION:-3.22}
arch=${VEYRA_ARCH:-x86_64}

validate_revision() {
    value=$1
    label=$2
    case "$value" in
        unknown) ;;
        *[!0-9a-f]*|'') echo "Invalid $label revision: $value" >&2; exit 1 ;;
        *) [ "${#value}" -eq 40 ] || { echo "Invalid $label revision length" >&2; exit 1; } ;;
    esac
}
validate_revision "$source_commit" 'Veyra source'
validate_revision "$aports_commit" 'Alpine aports'
validate_revision "$appcenter_commit" 'Veyra AppCenter'
validate_revision "$update_commit" 'Veyra updater package'
validate_revision "$glenv_commit" 'glenv'
case "$veyra_version" in ''|*[!A-Za-z0-9.+-]*) echo 'Invalid Veyra version' >&2; exit 1 ;; esac
case "$alpine_version" in 3.[0-9]*) ;; *) echo 'Invalid Alpine version' >&2; exit 1 ;; esac
[ "$arch" = x86_64 ] || { echo "Unsupported ISO architecture: $arch" >&2; exit 1; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
index="$tmpdir/APKINDEX.tar.gz"
xorriso -osirrox on -indev "$iso" \
    -extract "/apks/$arch/APKINDEX.tar.gz" "$index" >/dev/null
[ -s "$index" ] || { echo 'ISO has no embedded APK package index' >&2; exit 1; }

awk_packages="$tmpdir/packages.tsv"
if ! tar -xOzf "$index" APKINDEX | awk '
    BEGIN { RS=""; FS="\n" }
    {
        name = ""
        version = ""
        for (i = 1; i <= NF; i++) {
            if (substr($i, 1, 2) == "P:") name = substr($i, 3)
            if (substr($i, 1, 2) == "V:") version = substr($i, 3)
        }
        if (name != "" && version != "") print name "\t" version
    }
    END { if (NR == 0) exit 1 }
' | LC_ALL=C sort -u > "$awk_packages"; then
    echo 'Could not read package names and versions from the ISO index' >&2
    exit 1
fi
[ -s "$awk_packages" ] || { echo 'ISO package index is empty' >&2; exit 1; }

iso_name=$(basename "$iso")
sha256=$(sha256sum "$iso" | awk '{print $1}')
sha512=$(sha512sum "$iso" | awk '{print $1}')
package_count=$(wc -l < "$awk_packages" | tr -d '[:space:]')
manifest_tmp="$tmpdir/manifest"
{
    printf 'format=veyra-iso-manifest-v2\n'
    printf 'iso_file=%s\n' "$iso_name"
    printf 'iso_sha256=%s\n' "$sha256"
    printf 'iso_sha512=%s\n' "$sha512"
    printf 'veyra_version=%s\n' "$veyra_version"
    printf 'veyra_source_commit=%s\n' "$source_commit"
    printf 'alpine_release=%s\n' "$alpine_version"
    printf 'alpine_aports_commit=%s\n' "$aports_commit"
    printf 'architecture=%s\n' "$arch"
    printf 'appcenter_source_commit=%s\n' "$appcenter_commit"
    printf 'veyra_update_source_commit=%s\n' "$update_commit"
    printf 'glenv_source_commit=%s\n' "$glenv_commit"
    printf 'package_count=%s\n' "$package_count"
    printf '\npackage\tversion\n'
    cat "$awk_packages"
} > "$manifest_tmp"
mkdir -p "$(dirname "$output")"
mv "$manifest_tmp" "$output"
echo "ISO source/package manifest written: $output ($package_count packages)"
