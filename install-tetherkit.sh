#!/bin/sh
# Installs a built tetherkit-cli binary root-owned (it runs as root, so it must not be user-writable).
# Usage: sudo ./install-tetherkit.sh /path/to/tetherkit-cli
set -e
SRC="${1:?usage: sudo $0 /path/to/tetherkit-cli}"
install -d -o root -g wheel -m 755 /usr/local/libexec/tetherkit
install -o root -g wheel -m 755 "$SRC" /usr/local/libexec/tetherkit/tetherkit-cli
echo "installed:"
ls -l /usr/local/libexec/tetherkit/tetherkit-cli
