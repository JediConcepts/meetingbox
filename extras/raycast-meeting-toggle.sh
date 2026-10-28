#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Meeting toggle
# @raycast.mode compact
# @raycast.icon 🎙
# @raycast.packageName meetingbox
# Bind a hotkey to this in Raycast. First press records, second press writes the minutes.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
exec meetingbox
