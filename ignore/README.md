# ignore

This folder holds four's plugin, ready built for the norns. It holds nothing else.

| File | For |
|---|---|
| `plugins/armv7l/FourStretch.so` | A norns with the 32-bit system, such as a shield on a Raspberry Pi 4. |
| `plugins/aarch64/FourStretch.so` | The same file, for a norns whose kernel is 64-bit. |

The name of the folder is a norns rule. When SuperCollider starts, it skips any folder
named `ignore` in a script. So these files never run from here. When the norns starts,
four copies the plugin into SuperCollider's own plugin folder, and it runs from there.

The plugin is compiled code, so you cannot read it here. Its source code is in
[ugen/](../ugen/README.md), and you can build the same file yourself with
`ugen/build_norns.sh` on a norns.
