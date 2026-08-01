SR(1)

# NAME

sr - control Spaces Renamer from the command line

# SYNOPSIS

*sr* *status*

*sr* *renamer*

*sr* *settings*

*sr* *profile list*

*sr* *profile switch* _UUID_

*sr* *naming* _MODE_

*sr* *space* _UUID_ *name* _NAME_

*sr* *help*

# DESCRIPTION

*sr* opens Spaces Renamer deeplinks and reads status written by the running
Spaces Renamer app. The app installs symlinks for the command and this manual
page under _$HOME/.local_ when it launches.

# COMMANDS

*status*
	Print the active profile, naming mode, and known Spaces as JSON.

*renamer*
	Open or close the Space renaming popover.

*settings*
	Open the Settings window.

*profile list*
	Print profiles and current state as JSON.

*profile switch* _UUID_
	Activate the profile identified by _UUID_.

*naming* _MODE_
	Set the naming mode. _MODE_ is *manual*, *applications*, or
	*yabaiLabels*.

*space* _UUID_ *name* _NAME_
	Set the manual name for a Space. Quote _NAME_ when it contains spaces.

*help*
	Print a short usage summary.

# FILES

_$HOME/.local/bin/sr_
	Symlink to the command bundled in SpacesRenamer.app.

_$HOME/.local/share/man/man1/sr.1_
	Symlink to this manual page in SpacesRenamer.app.

_/tmp/spaces-renamer-status-$UID.json_
	Status exchanged with the running app.

# ENVIRONMENT

*PATH*
	Should include _$HOME/.local/bin_ to find *sr*.

*MANPATH*
	May need to include _$HOME/.local/share/man_ to find *sr*(1), depending on
	the shell and man configuration.

# SEE ALSO

*open*(1), *yabai*(1)
