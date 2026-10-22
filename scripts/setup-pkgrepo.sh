#!/bin/sh
# Configure the signed Veyra v1 APK repository (x86_64).
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run as root' >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo 'Only x86_64 is supported' >&2; exit 1; }
root="${VEYRA_ROOT:-/}"
case "$root" in
  /*) ;;
  *) echo 'VEYRA_ROOT must be an absolute path' >&2; exit 1 ;;
esac
[ -f "$root/etc/alpine-release" ] || { echo 'Alpine root not found' >&2; exit 1; }
[ -d "$root/etc/apk" ] || { echo 'APK configuration not found' >&2; exit 1; }
repo_url='https://raw.githubusercontent.com/angyedz/veyra-pkgrepo/main/stable/v1'
repo="@veyra $repo_url"
mkdir -p "$root/etc/apk/keys"
# Trust anchor is embedded in the distribution source; never trust a
# remotely downloaded replacement key without explicit review.
tmp=$(mktemp)
repo_tmp=''
cleanup() {
  rm -f "$tmp"
  [ -z "$repo_tmp" ] || rm -f "$repo_tmp"
}
trap cleanup 0 HUP INT TERM
cat > "$tmp" <<'VEYRA_PUBLIC_KEY'
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEArdUDsMMIjUSA28/ymlgf
TiPvxMkVcUVksoLRG40gnofnjAjwgkE+W8aso/5+RK+OgPtOz9hfE8TcqMPCLIO6
CNbjdWQIUsNfCdnbVq3TTspVLP3AVRwzzbVydSlfzYMqz+a/ZE6NkT7Pk2pW2O+J
Uphy4qUTZEB11AVXQdZc5QLT+GDbYF5Z2K1P6Rw77zLy9Q574KlEFNlMK+u5PiG2
T4h4qEoXqis2hx5K4RCc+qSbZ/BwTVXqpzHSiwcThfcHvx26IdgC32o3faDFrDVq
FQmoNbLyXPJA/VuzV+UQM7FQPGihVprDKtDtI0JlVH+m4Zxl/DkHAl7Dv+AMSJms
X+aJCBQbE6BcJECNsFh6qptNWibOSkMLf03NyIZxY5nGZNQuo74iEzJRrZFE62HY
az5cb7q1t2zgG43GQtZLfLHMh4MMY4QPw+vIvJz0pbiYW4U0xagKGnQKdmfusFCy
BSQnfbaKQcG/BIsg3OUozTpMfvmFdLFGRFYOCJmtyb3Ko6Hz1SsgDnCFfolizdJH
VZIRQmWQ/MJeyr0HF7TSim4GL8j2yvXoZDN7SUVHo50Fwy4p4VRqFNdQSkmL5L8/
czauIBWyn2/dtVUrOTrf+GFFW5XNmozY3riFmwvZyAVnNOiXVP+uBKu2QfG0dO9p
w+JQKUZ4vw4yfZ0/zfTykccCAwEAAQ==
-----END PUBLIC KEY-----
VEYRA_PUBLIC_KEY
if [ -e "$root/etc/apk/keys/veyra.rsa.pub" ] && ! cmp -s "$tmp" "$root/etc/apk/keys/veyra.rsa.pub"; then
  echo 'Existing Veyra signing key differs; refusing to overwrite' >&2
  exit 1
fi
install -m 644 "$tmp" "$root/etc/apk/keys/veyra.rsa.pub"
touch "$root/etc/apk/repositories"
repo_tmp=$(mktemp "$root/etc/apk/repositories.XXXXXX")
repo_written=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "$repo_url"|"$repo")
      if [ "$repo_written" -eq 0 ]; then
        printf '%s\n' "$repo" >> "$repo_tmp"
        repo_written=1
      fi
      ;;
    *) printf '%s\n' "$line" >> "$repo_tmp" ;;
  esac
done < "$root/etc/apk/repositories"
if [ "$repo_written" -eq 0 ]; then
  printf '%s\n' "$repo" >> "$repo_tmp"
fi
chmod 644 "$repo_tmp"
mv -f "$repo_tmp" "$root/etc/apk/repositories"
repo_tmp=''
echo "Configured signed Veyra APK repository (@veyra): $repo_url"
