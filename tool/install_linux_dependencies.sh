#!/usr/bin/env bash
# Ubuntu 24.04 CI dependencies. Run with bash, as the runner user (not root).
set -euo pipefail

packages=(
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
  libmpv-dev libsecret-1-dev libjsoncpp-dev
)
suites=(noble noble-updates noble-backports noble-security)
# These mirrors use independent DNS zones. Switching between *.ubuntu.com
# hosts alone cannot recover from an outage of Ubuntu's authoritative DNS.
mirrors=(
  https://archive.ubuntu.com/ubuntu
  https://mirrors.edge.kernel.org/ubuntu
  https://mirror.math.princeton.edu/pub/ubuntu
)

apt_dir=$(mktemp -d /tmp/hedone-apt.XXXXXX)
trap 'sudo rm -rf -- "$apt_dir"' EXIT
# APT drops download privileges to _apt, which must be able to read the source.
chmod 755 "$apt_dir"

attempt=0
for mirror in "${mirrors[@]}"; do
  echo "Checking Ubuntu mirror: $mirror"
  reachable=true
  for suite in "${suites[@]}"; do
    if ! curl --ipv4 --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' \
      --connect-timeout 5 --max-time 15 --output /dev/null \
      "$mirror/dists/$suite/InRelease"; then
      echo "::warning::Cannot fetch $suite from $mirror; trying the next mirror."
      reachable=false
      break
    fi
  done
  if [[ "$reachable" != true ]]; then
    continue
  fi

  attempt=$((attempt + 1))
  # Use an isolated source and fresh indexes for BOTH update and install.
  # This bypasses the hosted mirror+file list and unrelated third-party repos.
  cat > "$apt_dir/ubuntu.sources" <<EOF
Types: deb
URIs: $mirror
Suites: ${suites[*]}
Components: main restricted universe multiverse
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  mkdir -p "$apt_dir/lists-$attempt/partial"
  apt_options=(
    -o "Dir::Etc::sourcelist=$apt_dir/ubuntu.sources"
    -o Dir::Etc::sourceparts=-
    -o "Dir::State::lists=$apt_dir/lists-$attempt"
    -o Acquire::ForceIPv4=true
    -o Acquire::Retries=1
    -o Acquire::http::Timeout=20
    -o Acquire::https::Timeout=20
    -o APT::Update::Error-Mode=any
  )
  # A successful HTTP probe alone is insufficient: APT must verify signatures
  # and fetch the complete indexes, then successfully install every dependency.
  if ! sudo timeout --kill-after=10s 120s apt-get "${apt_options[@]}" update; then
    echo "::warning::APT index update failed for $mirror; trying the next mirror."
    continue
  fi
  if sudo env DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" \
    install -y --no-install-recommends "${packages[@]}"; then
    echo "Linux build dependencies installed successfully from $mirror"
    exit 0
  fi
  echo "::warning::Dependency installation failed for $mirror; trying the next mirror."
done

echo '::error::All Ubuntu mirrors failed. Linux build dependencies were not installed.'
exit 1
