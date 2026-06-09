#!/bin/zsh
set -euo pipefail

cd -- "$(dirname "$0")"

echo "Setting up Rekordbox History Viewer..."

if ! command -v node >/dev/null 2>&1; then
  echo ""
  echo "Node.js is required. Install the LTS version from https://nodejs.org, then double-click this file again."
  read -r "?Press Return to close."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "Python 3 is required. Install it from https://www.python.org/downloads/, then double-click this file again."
  read -r "?Press Return to close."
  exit 1
fi

if [ ! -d node_modules ]; then
  npm install
fi

if [ ! -x .venv-rekordbox/bin/python ]; then
  npm run setup:python
fi

npm run build
npm start
