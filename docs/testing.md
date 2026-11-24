# Manual testing

Automated tests cover the settings, the injection handshake and the hook's label
path on a fake layer tree. They cannot see what Mission Control paints. Run this
checklist before a release and after any change to `spaces-renamer/spacesRenamer.m`.

## Setup

```sh
make build-all
make install
```

Injection needs macOS 14 or newer, Apple silicon, SIP disabled with full
restrictions off, `boot-args` containing `-arm64e_preview_abi`, and Library
Validation disabled for the host. The app validates the boot argument; the
Diagnostics pane lists the rest.

## Checklist

1. Open Mission Control once. Every named Space shows its name, and no label
   flashes "Desktop N" before the name appears.
2. Reduce Transparency in System Settings, then open Mission Control. Labels stay
   readable and legible against the blur.
3. Increase Contrast. Labels stay readable.
4. Rename a Space to an emoji only. The emoji shows, at full width.
5. Rename a Space to spaces only. The label shows the name, not a blank bar.
6. Clear a Space's name. WindowManager's own "Desktop N" returns.
7. Leave some Spaces unnamed beside named ones. Unnamed labels show
   "Desktop N"; nothing is hidden.
8. Open a full-screen app, then open Mission Control. Its label shows the app
   name; desktop labels keep their names.
9. Connect a second display, and check both:
   - displays with separate Spaces show "Desktop 1" on each;
   - displays that share spaces (`defaults read com.apple.spaces spans-displays`
     is 1) number across, and the second display's names follow.
10. Rename a Space while Mission Control is open. The visible bar updates without
    closing Mission Control.
11. Rearrange Spaces in Mission Control, then reopen it. Names follow their
    Spaces.
12. Turn off "Displays have separate Spaces", log out and back in, and repeat 9.

## Legacy host

macOS 26 and earlier draw the Spaces bar in Dock rather than WindowManager. The
hook takes the older label path there, which reads the layout the app publishes.
Test 1, 6, 7 and 11 on a 26 machine before a release that claims support for it.
