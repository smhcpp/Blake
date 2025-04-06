# Blake

A vim-like compositor written in Zig based on zig-wlroots.

**Note:** This project is currently non-functional and has many bugs.

## Table of Contents
- [Install](#install)
- [Planned Features](#planned-features)

## Compile

Clone the repository and run `zig build` in the `blake` folder:

```
git clone <repository_url>
cd blake
zig build
```
## Planned Features

- [ ] **Efficient Workspace Removal:** Remove workspaces in an efficient manner.
- [ ] **Default Config Loading:** Load configs with a default version that works if there is an error when loading user defined config.
- [ ] **Background Options:** Support for a background, which can be a ghostty terminal using libghostty, an image, or nothing—based on user preference.
- [ ] **Command Bar Plugin:** Minimal command bar to run different commands in command mode.
- [ ] **Layout Commands:** Add the possibility of including commands in `configs.conf`. 
- [ ] **Layout Manager:** Load different layout schemes with different policies (like resize polocies which is specific to each layout).
- [ ] **Plugin Manager:** Load various plugins related to the compositor.
- [ ] **Modal Capability:** Implement app mode(insert), normal mode and command mode.
- [ ] **Keymap Manager:** Enable keymapping in different modes, including the option to have separate keymaps for each application.
- [ ] **Animation Manager:** Allow users to choose which animations to include in their compositor.
- [ ] **Command Mode:** Change many behaviors of the compositor via simple commands instead of modifying many files.
  - *Example:* Add items to the status bar (like a Bluetooth manager) and set options for live changes versus saved changes.
  - *Example:* Add keyboards and set keyboard change keys.

Enjoy exploring Blake, and stay tuned for updates!
