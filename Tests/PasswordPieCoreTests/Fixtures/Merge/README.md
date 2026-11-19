# KeePassXC merge fixtures

Two copies of one KDBX 4 database that were changed apart, and the merge KeePassXC 2.8.0 made of them. Everything in
them was written by `keepassxc-cli`: `make.sh <KeyFiles folder> <output folder>` is the script that made them, starting
from `../KeyFiles/any.kdbx`. Password `pie-test`, key file `../KeyFiles/any.key`.

| File | What happened to it |
|---|---|
| `mac-a.kdbx` | Bank's password changed to `bank-a`. `Key from A` added. `Old account` deleted for good (it is in `DeletedObjects`). After everything on B: `Example any` changed |
| `mac-b.kdbx` | Later than A's change to Bank: Bank's password changed to `bank-b`. `Key from B` added, with the attachment `b.json`. Deploy's attachment `deploy.pem` replaced. Mail moved into Work |
| `merged-by-keepassxc.kdbx` | `mac-a.kdbx` after `keepassxc-cli merge -s mac-a.kdbx mac-b.kdbx` |

`KeePassXCMergeTests` merges B into A with PasswordPie and compares the result with KeePassXC's, item by item. The one
difference is on purpose: `keepassxc-cli merge` does not apply deletions (its default merge mode, "keep newer"), so
`Old account` comes back in its file. PasswordPie applies them, as KeePassXC's Synchronize mode and KeePass 2 do.

While merging, KeePassXC printed "History entry of Deploy … contains conflicting changes - conflict resolution may lose
data!": Deploy has two different versions with the same time in its history (it was made and given an attachment within
one second), and KeePassXC keeps one version per time. PasswordPie keeps both.
