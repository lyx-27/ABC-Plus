#!/bin/zsh
# Double-click to install ABC+. Opens in Terminal and runs install.sh with the default model.
cd "${0:A:h}"
clear
echo "ABC+ installer"
echo "--------------"
echo "This installs the ABC+ input method and downloads the language model (about 1.6 GB)."
echo "It runs entirely on your Mac."
echo
if ./install.sh; then
  echo
  echo "Done. Open System Settings > Keyboard > Input Sources if ABC+ is not in the input menu yet."
else
  echo
  echo "The installation did not finish. Read the message above, fix it, and double-click this file again."
fi
echo
read -k 1 "?Press any key to close this window..."
echo
