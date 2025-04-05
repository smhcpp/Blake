# Blake

A vim-like compositor written in Zig based on zig-wlroots.

**Note:** This project is currently non-functional and has many bugs.

## Table of Contents
- [Install](#install)
- [Planned Features](#planned-features)

## Install

Clone the repository and run `zig build` in the `blake` folder:

```
git clone <repository_url>
cd blake
zig build
```
## Planned Features

- [ ] **Efficient Workspace Removal:** Remove workspaces in an efficient manner.
- [ ] **Default Layout Loading:** Load layouts with a default version that works if there is an error.
- [ ] **Background Options:** Support for a background, which can be a ghostty terminal using libghostty, an image, or nothing—based on user preference.
- [ ] **Command Bar Plugin:** Initially, a small command bar will be included for demonstration, which will later become a plugin.
- [ ] **Layout Commands:** Add the possibility of including commands in `layout.json` (which will be renamed to `layout.conf`).
- [ ] **Layout Manager:** Load different layout schemes and policies.
- [ ] **Plugin Manager:** Load various plugins related to the compositor.
- [ ] **Dual Modes:** Implement both app mode and normal mode.
- [ ] **Keymap Manager:** Enable keymapping in different modes, including the option to have separate keymaps for each application in normal mode.
- [ ] **Animation Manager:** Allow users to choose which animations to include in their compositor.
- [ ] **Command Mode:** Change many behaviors of the compositor via simple commands instead of modifying many files.
  - *Example:* Add items to the status bar (like a Bluetooth manager) and set options for live changes versus saved changes.
  - *Example:* Add keyboards and set keyboard change keys.

Enjoy exploring Blake, and stay tuned for updates!
