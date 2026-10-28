#!/bin/bash
# Paste this into a Shortcuts "Run Shell Script" action, shell /bin/bash.
# Then set a keyboard shortcut in the shortcut details pane and tick Pin in Menu Bar.
#
# Shortcuts hands the script a bare PATH, so it has to be rebuilt here or
# meetingbox will not find ffmpeg, fm or the transcriber.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
meetingbox
