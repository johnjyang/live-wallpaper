#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
agent="$HOME/Library/LaunchAgents/com.local.live-wallpaper.plist"
if launchctl print "gui/$(id -u)/com.local.live-wallpaper" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/com.local.live-wallpaper"
fi
ditto --norsrc --noextattr "$HOME/Library/Caches/com.local.LiveWallpaper/build/Live Wallpaper.app" "$HOME/Applications/Live Wallpaper.app"
codesign --verify --strict "$HOME/Applications/Live Wallpaper.app"
python3 - <<'PY'
from pathlib import Path
import plistlib
home = Path.home()
agent = home/'Library/LaunchAgents/com.local.live-wallpaper.plist'
agent.parent.mkdir(parents=True, exist_ok=True)
if agent.exists() and plistlib.loads(agent.read_bytes()).get('Label') != 'com.local.live-wallpaper':
    raise RuntimeError('Refusing to overwrite a different launch agent')
logs = home/'Library/Logs/LiveWallpaper'
logs.mkdir(parents=True, exist_ok=True)
agent.write_bytes(plistlib.dumps({
    'Label':'com.local.live-wallpaper',
    'ProgramArguments':[str(home/'Applications/Live Wallpaper.app/Contents/MacOS/LiveWallpaper')],
    'RunAtLoad':True, 'KeepAlive':{'Crashed':True}, 'ThrottleInterval':15,
    'ProcessType':'Interactive',
    'StandardOutPath':str(logs/'stdout.log'), 'StandardErrorPath':str(logs/'stderr.log')
}))
PY
launchctl bootstrap "gui/$(id -u)" "$agent"
