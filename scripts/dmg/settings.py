app = defines["app"]
assets = defines["assets"]

files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
format = "UDZO"
background = f"{assets}/background.png"
window_rect = ((200, 140), (660, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    "Confluo.app": (165, 170),
    "Applications": (495, 170),
}
hide_extensions = ["Confluo.app"]
