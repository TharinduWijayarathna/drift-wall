#!/bin/bash
# Double-click to build Driftwall.app and dist/Driftwall.dmg.
exec "$(dirname "$0")/scripts/build-dmg.sh"
