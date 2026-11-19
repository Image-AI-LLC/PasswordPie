#!/bin/bash
# Makes the KeePassXC merge fixtures. Usage: make-merge-fixtures.sh <KeyFiles fixture dir> <output dir>
set -euo pipefail
R="$1"; S="$2"
rm -rf "$S"; mkdir -p "$S"; cd "$S"
cp "$R/any.kdbx" base.kdbx; cp "$R/any.key" any.key
kp() { local cmd="$1"; shift; keepassxc-cli "$cmd" -q -k any.key "$@"; }
printf 'first key\n' > deploy.pem; printf 'second key, changed on B\n' > deploy2.pem; printf '{"b":true}\n' > b.json
printf 'pie-test\nbank-0\n' | kp add -u ada --url https://bank.example -p base.kdbx 'Bank'
printf 'pie-test\nmail-0\n' | kp add -u ada -p base.kdbx 'Mail'
echo pie-test | kp mkdir base.kdbx 'Work'
printf 'pie-test\ndeploy-0\n' | kp add -u deploy -p base.kdbx 'Work/Deploy'
echo pie-test | kp attachment-import base.kdbx 'Work/Deploy' deploy.pem deploy.pem
printf 'pie-test\nold-0\n' | kp add -u ada -p base.kdbx 'Old account'
cp base.kdbx mac-a.kdbx; cp base.kdbx mac-b.kdbx
sleep 1.2
# Mac A: changes Bank, adds a key, deletes Old account for good.
printf 'pie-test\nbank-a\n' | kp edit -p mac-a.kdbx 'Bank'
printf 'pie-test\nkey-a\n' | kp add -u a -p mac-a.kdbx 'Key from A'
echo pie-test | kp rm mac-a.kdbx 'Old account'
echo pie-test | kp rm mac-a.kdbx 'Recycle Bin/Old account'
sleep 1.2
# Mac B, later: changes Bank too, adds a key with an attachment, replaces Deploy's attachment, moves Mail to Work.
printf 'pie-test\nbank-b\n' | kp edit -p mac-b.kdbx 'Bank'
printf 'pie-test\nkey-b\n' | kp add -u b -p mac-b.kdbx 'Key from B'
echo pie-test | kp attachment-import mac-b.kdbx 'Key from B' b.json b.json
echo pie-test | kp attachment-import -f mac-b.kdbx 'Work/Deploy' deploy.pem deploy2.pem
echo pie-test | kp mv mac-b.kdbx 'Mail' 'Work'
sleep 1.2
# Mac A again, after B.
printf 'pie-test\nexample-a\n' | kp edit -p mac-a.kdbx 'Example any'
cp mac-a.kdbx merged-by-keepassxc.kdbx
echo pie-test | keepassxc-cli merge -q -s -k any.key merged-by-keepassxc.kdbx mac-b.kdbx
rm -f base.kdbx deploy.pem deploy2.pem b.json
echo "--- merged by KeePassXC:"; echo pie-test | kp ls -R -f merged-by-keepassxc.kdbx
