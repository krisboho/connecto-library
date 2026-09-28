#!/bin/sh
# Installs the plugins into KO_HOME and runs KOReader headless once.
set -e
export KO_HOME=/kohome/koreader
export SDL_VIDEODRIVER=dummy
export SDL_AUDIODRIVER=dummy
mkdir -p "$KO_HOME/plugins" "$KO_HOME/settings" /kohome/books
rm -rf "$KO_HOME/plugins/shelfsync.koplugin" "$KO_HOME/plugins/shelfsynctest.koplugin"
cp -r /plugin-src/shelfsync.koplugin /plugin-src/shelfsynctest.koplugin "$KO_HOME/plugins/"
cd /kohome/books
exec timeout 180 koreader /kohome/books
