# Blake
vim like compositor written in zig based on zig-wlroots.

This is non functional at the moment and has a lot of bugs. It is suppose to support the following
functionalities in the future:
-[] workspace removal done efficiently
-[] loading layouts must have a default version so that if there is an error the default one should work.
-[] think about background. either some form of ghostty terminal with libghostty or just a picture or nothing
as the user wants.
-[] command bar should be a plugin in the end but just for the show case we should write a small one.
-[] adding possibility of having commands in layout.json and changing its name to layout.conf
-[] layout manager: loading different layout schemes and polocies.
-[] plugin manager: loading different plugins related to the compositor
-[] two different modes: app mode and normal mode
-[] keymap manager: enable keymapping in different modes (like having the ability to add different keymaps for normal mode for each application separately)
-[] animation manager: enable animation inclusion specifically (users should be able to choose what animation they want in their compositor)
-[] command mode: be able to change many behaviors of compositor just by a simple command rather than changing a whole lot of files
For example: being able to add items on the status bar (like bluetooth manager and ...), set for live changes, and setw for changes that user want to save. 
Another example: adding keyboards and setting keyboard change keys.

