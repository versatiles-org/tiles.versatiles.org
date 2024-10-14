set -e

cd "$(dirname "$0")"



# Init Debian
    apt-get update
    apt-get install -y --no-install-recommends wget



# Install VersaTiles
    # Detect architecture
    ARCH=$(uname -m)
    [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "aarch64" ] || { echo "Unsupported architecture: $ARCH"; exit 1; }

    # Detect OS and libc type
    OS=$(uname)
    if [ "$OS" = "Linux" ]; then
        OS="linux-$(ldd --version 2>&1 | grep -q "musl" && echo "musl" || echo "gnu")"
    elif [ "$OS" = "Darwin" ]; then
        OS="macos"
    else
        echo "Unsupported OS: $OS"; exit 1
    fi

    # Download and install the package
    PACKAGE_URL="https://github.com/versatiles-org/versatiles-rs/releases/latest/download/versatiles-$OS-$ARCH.tar.gz"
    wget -q "$PACKAGE_URL" -O - | tar -xzf - -C /usr/local/bin versatiles

    echo "VersaTiles installed successfully."

# Cleanup Debian
    # apt-get remove --purge -y curl
    apt-get autoremove -y
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    rm -rf /root/.cache
