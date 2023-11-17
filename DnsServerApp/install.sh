#!/usr/bin/env bash
set -euo pipefail

dotnet_dir='/opt/dotnet'
dotnet_version='7.0'
dns_tar='DnsServerPortable.tar.gz'

if [ -d '/etc/dns/config' ]; then
  dns_root='/etc/dns'
else
  dns_root='/opt/technitium/dns'
fi
dns_tar_absolute="$dns_root/$dns_tar"
dns_url="https://download.technitium.com/dns/$dns_tar"

die() {
  echo
  echo >&2 "$@"
  exit 1
}

[ "$OSTYPE" = 'linux-gnu' ] || die 'This installer only supports Linux.'
[ "$UID" = 0 ] || die 'This installer must be run as root.'
[ -r /etc/os-release ] || die 'This installer only supports Linux distros with systemd.'
. /etc/os-release
case "$ID_LIKE" in
  *rhel*|*debian*) ;;
  *) die "Currently unsupported Linux distro: $PRETTY_NAME. Patches are always welcome!" ;;
esac

mkdir -p "$dns_root"
exec &> >(tee "$dns_root"/install.log)

cat <<'BANNER'
===========================================================================

 _______ _______ _______ _     _ __   _ _____ _______ _____ _     _ _______
    |    |______ |       |_____| | \  |   |      |      |   |     | |  |  |
    |    |______ |_____  |     | |  \_| __|__    |    __|__ |_____| |  |  |

                          ______  __   _ _______
                          |     \ | \  | |______
                          |_____/ |  \_| ______|

===========================================================================

                             Server Installer
BANNER

has_dotnet_runtime() {
  local match="Microsoft.AspNetCore.App $dotnet_version."

  [[ "$(dotnet --list-runtimes 2>/dev/null)" =~ "$match" ]]
}

install_dotnet_generic() {
  curl -fsSL https://dot.net/v1/dotnet-install.sh \
  | bash -s --                  \
    -c "$dotnet_version"        \
    --runtime aspnetcore        \
    --no-path                   \
    --install-dir "$dotnet_dir" \
    --verbose

  [ -f '/usr/bin/dotnet' ] || ln -sf "$dotnet_dir"/dotnet /usr/bin/dotnet

  if ! has_dotnet_runtime; then
    die 'Failed to install ASP.NET Core Runtime. Please try again.'
  fi
}

install_dotnet() {
  local has_dotnet
  local dotnet_action

  if has_dotnet_runtime; then
    has_dotnet='yes'
  else
    has_dotnet='no'
  fi

  echo ''
  if [[ ! -d "$dotnet_dir" && "$has_dotnet" = "yes" ]]; then
    echo 'ASP.NET Core Runtime is already installed.'
    return
  fi

  if [[ -d "$dotnet_dir" && "$has_dotnet" = "yes" ]]; then
    echo 'Updating ASP.NET Core Runtime...'
    dotnet_action='updated'
  else
    echo 'Installing ASP.NET Core Runtime...'
    dotnet_action='installed'
  fi

  case "$ID_LIKE" in
    *rhel*)   dnf install -y aspnetcore-runtime-"$dotnet_version" ;;
    *debian*) apt install -y aspnetcore-runtime-"$dotnet_version" ;; 
    # Generally not recommended as this prevents security updates
    *) install_dotnet_generic ;;
  esac

  echo "ASP.NET Core Runtime $dotnet_action successfully!"
}

install_technitium() {
  echo ''
  echo 'Downloading Technitium DNS Server...'

  if ! curl -fsSo "$dns_tar_absolute" "$dns_url"; then
    die "Failed to download Technitium DNS Server from: $dns_url"
  fi

  if [ -d "$dns_root" ]; then
    echo 'Updating Technitium DNS Server...'
  else
    echo 'Installing Technitium DNS Server...'
  fi

  tar xf "$dns_tar_absolute" -C "$dns_root"
}

install_technitium_service() {
  local service=/etc/systemd/system/dns.service

  if [ -f "$service" ]; then
    echo 'Restarting systemd service...'
    systemctl restart dns.service
  else
    echo 'Configuring systemd service...'
    ln -sf "$dns_root"/systemd.service "$service"
    systemctl daemon-reload
    systemctl enable --now dns.service
  fi
}

# $1 - section, create if missing
# $2 - key
# $3 - value
# $4 - file
add_or_replace_line() {
  local section="$1"
  local key="$2"
  local value="$3"
  local file="$4"

  if ! grep -q "^[[:space:]]*\[$section\]" "$file" 2>/dev/null; then
    echo "[$section]" >> "$file"
  fi

  if grep -q "^[[:space:]]*$key[[:space:]]*=" "$file" 2>/dev/null; then
    sed -i "s|^[[:space:]]*$key[[:space:]]*=.*|# &\n$key=$value|" "$file"
  else
    sed -i "/^\[$section\]/a $key=$value" "$file"
  fi
}

# $1 - prefix, delete all present
# $2 - line to add
# $3 - file
add_unique_line() {
  local prefix="$1"
  local line="$2"
  local file="$3"

  sed -i "s/^[[:space:]]*$prefix/# &/" "$file"
  echo "$line" >> "$file"
}

configure_local_resolver_debian() {
  add_or_replace_setting 'main' 'dns' 'default' /etc/NetworkManager/NetworkManager.conf
  add_unique_line 'nameserver' 'nameserver 127.0.0.1' /etc/resolv.conf
}

conn_for_device() {
  local device="$1"
  nmcli dev show "$device" 2>/dev/null \
    | awk -F: '/GENERAL.CONNECTION/{sub(/^[[:space:]]+/,"",$2);print$2}'
}

configure_local_resolver_rhel() {
  local device=eth0
  local conn=$(conn_for_device "$device")
  if [ -z "$conn" ]; then
    die "Failed to configure local resolver: $device was not detected."
  fi

  nmcli con modify "$conn" \
    ipv4.ignore-auto-dns yes \
    ipv4.dns '127.0.0.1'
}

disable_systemd_resolver() {
  local conflict='systemd-resolved.service'

  if systemctl is-enabled "$conflict" &>/dev/null; then
    echo 'Disabling systemd-resolved service...'
    systemctl disable "$conflict"
  fi

  if systemctl is-active "$conflict" &>/dev/null; then
    echo 'Stopping systemd-resolved service...'
    systemctl stop "$conflict"
  fi
}

configure_local_resolver() {
  echo 'Configuring local resolver...'
  case "$ID_LIKE" in
    *debian*) configure_local_resolver_debian ;;
    *rhel*)   configure_local_resolver_rhel   ;;
  esac
}


install_dotnet
install_technitium
install_technitium_service
disable_systemd_resolver
configure_local_resolver

cat <<SUCCESS
🍾   Technitium DNS Server was installed successfully!

🖥️    Open http://$HOSTNAME:5380/ to access the web console.

🙏   Donate! Make a contribution by becoming a Patron: https://www.patreon.com/technitium

SUCCESS
