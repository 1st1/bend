#!/bin/bash
# Runs as root inside the disposable guest, once per boot until provisioning succeeds.
set -euo pipefail
dir=/Library/BendTestVM
exec >>"$dir/setup.log" 2>&1
trap 'echo "Provisioning failed at line $LINENO" > "$dir/failed"' ERR
rm -f "$dir/failed"
if [[ -e "$dir/ready" ]]; then exit 0; fi
echo "Preparing test desktop"
if [[ ! -f "$dir/password" ]]; then
  (umask 077; /usr/bin/openssl rand -hex 24 > "$dir/password")
fi
password=$(cat "$dir/password")
if ! id admin >/dev/null 2>&1; then
  sysadminctl -addUser admin -fullName 'Bend Tests' -password "$password" -admin
fi
id admin
# A partially provisioned guest may already have discarded its setup password.
if ! dscl . -authonly admin "$password"; then
  dscl . -passwd /Users/admin "$password"
  dscl . -authonly admin "$password"
fi
createhomedir -c -u admin
install -d -o admin -g staff -m 700 /Users/admin/.ssh
install -o admin -g staff -m 600 "$dir/client.pub" /Users/admin/.ssh/authorized_keys
# On a headless Tahoe first boot sysadminctl can return success while reporting
# SACSetAutoLoginPassword error:22 and leaving loginwindow without a kcpassword.
# Write loginwindow's NUL-padded, 11-byte XOR format for this disposable account.
(
  umask 077
  printf '%s' "$password" | /usr/bin/perl -0777 -ne '
    my $key = pack("C*", 0x7d,0x89,0x52,0x23,0xd2,0xbc,0xdd,0xea,0xa3,0xb9,0x1f);
    $_ .= "\0" x (11 - length($_) % 11);
    print $_ ^ ($key x (length($_) / 11));
  ' > "$dir/kcpassword"
)
install -o root -g wheel -m 600 "$dir/kcpassword" /etc/kcpassword
rm "$dir/kcpassword"
defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string admin
test -s /etc/kcpassword
touch /var/db/.AppleSetupDone
launchctl enable system/com.openssh.sshd
if ! launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
  launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist
fi
pmset -a sleep 0
if [[ ! -x /Library/Developer/CommandLineTools/usr/bin/swift || -e "$dir/installing-clt" ]]; then
  echo "Looking up Command Line Tools offered by Apple for this guest"
  touch "$dir/installing-clt"
  hint=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  touch "$hint"
  trap 'rm -f "$hint"' EXIT
  for attempt in {1..6}; do
    listing=$(LC_ALL=C softwareupdate --list 2>&1) || true
    label=$(sed -nE 's/^[[:space:]*-]*Label:[[:space:]]*(Command Line Tools for Xcode[- ][0-9].*)$/\1/p' \
      <<<"$listing" | sort -V | tail -1)
    [[ -z "$label" ]] || break
    sleep 10
  done
  if [[ -z "$label" ]]; then
    echo "$listing"
    echo "Apple Software Update offered no Command Line Tools for this guest" > "$dir/failed"
    exit 1
  fi
  echo "Installing $label in the baseline"
  softwareupdate --install "$label" --verbose
  rm "$dir/installing-clt"
fi
xcode-select --switch /Library/Developer/CommandLineTools
xcrun swift --version
xcrun --sdk macosx --show-sdk-version
touch "$dir/ready"
rm -f "$dir/password"
echo "Restarting into the provisioned desktop"
shutdown -r now
