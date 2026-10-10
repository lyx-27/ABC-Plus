#!/bin/zsh
# Double-click to remove ABC+. Keeps your downloaded models, settings and learned words.
# To delete those too, run in Terminal: ./uninstall.sh --purge
cd "${0:A:h}"
clear
echo "ABC+ uninstaller"
echo "----------------"
./uninstall.sh
echo
read -k 1 "?Press any key to close this window..."
echo
