#!/bin/sh
set -eu

repo="${SKILL_INSTALL_REPO:-Teamon9161/skill}"
version="${SKILL_VERSION:-latest}"
install_dir="${SKILL_INSTALL_DIR:-$HOME/.local/bin}"
current_version="${1:-${SKILL_CURRENT_VERSION:-}}"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

download() {
    url="$1"
    out="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url"
    else
        echo "missing required command: curl or wget" >&2
        exit 1
    fi
}

sha256_file() {
    file="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        echo "missing required command: sha256sum or shasum" >&2
        exit 1
    fi
}

case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="macos" ;;
    *)
        echo "unsupported OS: $(uname -s)" >&2
        exit 1
        ;;
esac

case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    arm64 | aarch64) arch="aarch64" ;;
    *)
        echo "unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

if [ "$version" = "latest" ] && [ -n "$current_version" ]; then
    latest_tag=""
    if command -v curl >/dev/null 2>&1; then
        latest_tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
            -H "User-Agent: skill-updater" \
            | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' | head -1) || true
    elif command -v wget >/dev/null 2>&1; then
        latest_tag=$(wget -qO- "https://api.github.com/repos/$repo/releases/latest" \
            | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' | head -1) || true
    fi
    if [ -n "$latest_tag" ]; then
        latest_version="${latest_tag#v}"
        if [ "$current_version" = "$latest_version" ]; then
            echo "skill $current_version is already up to date"
            exit 0
        fi
        echo "Updating skill $current_version -> $latest_version..."
    fi
fi

archive="skill-$arch-$os.tar.gz"
if [ "$version" = "latest" ]; then
    base_url="https://github.com/$repo/releases/latest/download"
else
    case "$version" in
        v*) tag="$version" ;;
        *) tag="v$version" ;;
    esac
    base_url="https://github.com/$repo/releases/download/$tag"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

download "$base_url/$archive" "$tmp_dir/$archive"
download "$base_url/checksums.txt" "$tmp_dir/checksums.txt"

expected="$(awk -v file="$archive" '$2 == file { print $1 }' "$tmp_dir/checksums.txt")"
if [ -z "$expected" ]; then
    echo "checksum not found for $archive" >&2
    exit 1
fi

actual="$(sha256_file "$tmp_dir/$archive")"
if [ "$actual" != "$expected" ]; then
    echo "checksum mismatch for $archive" >&2
    exit 1
fi

need_cmd tar
mkdir -p "$install_dir"
tar -xzf "$tmp_dir/$archive" -C "$tmp_dir"

if command -v install >/dev/null 2>&1; then
    install -m 755 "$tmp_dir/skill" "$install_dir/skill"
else
    cp "$tmp_dir/skill" "$install_dir/skill"
    chmod 755 "$install_dir/skill"
fi

case ":$PATH:" in
    *":$install_dir:"*) ;;
    *)
        echo "Installed skill to $install_dir, but that directory is not in PATH."
        echo "Add this to your shell profile:"
        echo "  export PATH=\"$install_dir:\$PATH\""
        ;;
esac

echo "skill installed to $install_dir/skill"
