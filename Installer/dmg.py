# The disk image's layout, for dmgbuild (https://github.com/dmgbuild/dmgbuild),
# which writes the Finder's own layout file directly: no Finder to script and no
# window opening mid-build. build.sh passes the paths in with -D.
#
# One thing in it: Open yab, which installs yab and opens it. No shortcut
# to Applications to drag onto, dragged anywhere, Open yab still does the
# same, and then goes to the Trash.
#
# The size and the icon's place are the ones Installer/background.swift draws
# around, and the size is how Installer/Open/Handoff.swift recognizes this
# window, change one, change them all.

import os.path

launcher = defines["launcher"]
name = os.path.basename(launcher)

format = "UDZO"
files = [launcher]
icon = defines["icon"]                  # the mounted volume wears the app's icon
background = defines["background"]

# 640 x 400 of content under a title bar of about 32.
window_rect = ((200, 140), (640, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    name: (320, 170),
}
