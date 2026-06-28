#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Project 'Pelinstaller'                                                        #
#                                                                                    #
# Copyright (C) 2018 - 2024, Vilhelm Prytz, <vilhelm@prytznet.se>                    #
# Copyright (C) 2021 - 2024, Matthew Jacob, <git@matthew.network>                      #
#                                                                                    #
#   This program is free software: you can redistribute it and/or modify             #
#   it under the terms of the GNU General Public License as published by             #
#   the Free Software Foundation, either version 3 of the License, or                #
#   (at your option) any later version.                                              #
#                                                                                    #
#   This program is distributed in the hope that it will be useful,                  #
#   but WITHOUT ANY WARRANTY; without even the implied warranty of                   #
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                    #
#   GNU General Public License for more details.                                     #
#                                                                                    #
#   You should have received a copy of the GNU General Public License                #
#   along with this program.  If not, see <https://www.gnu.org/licenses/>.           #
#                                                                                    #
# https://github.com/ratx0x0/Pelinstaller-26.04/blob/Production/LICENSE.md  #
#                                                                                    #
# This script is not associated with the official Pelican Project.                   #
# https://github.com/ratx0x0/Pelinstaller-26.04                             #
#                                                                                    #
######################################################################################

# Check if script is loaded, load if not or fail otherwise.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE"/lib/lib.sh)
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

# ------------------ Variables ----------------- #

# Domain name / IP
export FQDN=""

# Panel source: "release" (official, default) or "custom" (GitHub repo + branch)
export PANEL_SOURCE="release"
export PANEL_REPO=""
export PANEL_BRANCH=""

# Email (only used for Let's Encrypt)
export email=""

# Assume SSL, will fetch different config if true
export ASSUME_SSL=false
export CONFIGURE_LETSENCRYPT=false

# Firewall
export CONFIGURE_FIREWALL=false

# ------------ User input functions ------------ #

ask_panel_source() {
  output "By default the latest official Pelican release is installed."
  echo -e -n "* Install the Panel from a custom GitHub repo + branch instead (for testing)? (y/N): "
  read -r CONFIRM_CUSTOM_SOURCE

  if [[ "$CONFIRM_CUSTOM_SOURCE" =~ [Yy] ]]; then
    PANEL_SOURCE="custom"
    required_input PANEL_REPO "GitHub owner/repo (e.g. kazaminosuke/pelican-dev-panel): " "Repository (owner/repo) cannot be empty"
    required_input PANEL_BRANCH "Branch name (e.g. fix-plugin-install-stale-sushi): " "Branch cannot be empty"
  fi
}

ask_letsencrypt() {
  if [ "$CONFIGURE_UFW" == false ] && [ "$CONFIGURE_FIREWALL_CMD" == false ]; then
    warning "Let's Encrypt requires port 80/443 to be opened! You have opted out of the automatic firewall configuration; use this at your own risk (if port 80/443 is closed, the script will fail)!"
  fi

  echo -e -n "* Do you want to automatically configure HTTPS using Let's Encrypt? (y/N): "
  read -r CONFIRM_SSL

  if [[ "$CONFIRM_SSL" =~ [Yy] ]]; then
    CONFIGURE_LETSENCRYPT=true
    ASSUME_SSL=false
  fi
}

ask_assume_ssl() {
  output "Let's Encrypt is not going to be automatically configured by this script (user opted out)."
  output "You can 'assume' Let's Encrypt, which means the script will download a nginx configuration that is configured to use a Let's Encrypt certificate but the script won't obtain the certificate for you."
  output "If you assume SSL and do not obtain the certificate, your installation will not work."
  echo -n "* Assume SSL or not? (y/N): "
  read -r ASSUME_SSL_INPUT

  [[ "$ASSUME_SSL_INPUT" =~ [Yy] ]] && ASSUME_SSL=true
  true
}

check_FQDN_SSL() {
  if [[ $(invalid_ip "$FQDN") == 1 && $FQDN != 'localhost' ]]; then
    SSL_AVAILABLE=true
  else
    warning "* Let's Encrypt will not be available for IP addresses."
    output "To use Let's Encrypt, you must use a valid domain name."
  fi
}

main() {
  # check if we can detect an already existing installation
  if [ -d "/var/www/pelican" ]; then
    warning "The script has detected that you already have Pelican panel on your system! You cannot run the script multiple times, it will fail!"
    echo -e -n "* Are you sure you want to proceed? (y/N): "
    read -r CONFIRM_PROCEED
    if [[ ! "$CONFIRM_PROCEED" =~ [Yy] ]]; then
      error "Installation aborted!"
      exit 1
    fi
  fi

  welcome "panel"

  check_os_x86_64

  # The database, admin account and Eggs are configured later through the web
  # installer, so the CLI only needs the details required to deploy the panel.

  # Choose where the Panel source is fetched from (official release vs custom branch)
  ask_panel_source

  print_brake 72

  # set FQDN
  while [ -z "$FQDN" ]; do
    echo -n "* Set the FQDN of this panel (panel.example.com): "
    read -r FQDN
    [ -z "$FQDN" ] && error "FQDN cannot be empty"
  done

  # Check if SSL is available
  check_FQDN_SSL

  # Ask if firewall is needed
  ask_firewall CONFIGURE_FIREWALL

  # Only ask about SSL if it is available
  if [ "$SSL_AVAILABLE" == true ]; then
    # Ask if letsencrypt is needed
    ask_letsencrypt
    # If it's already true, this should be a no-brainer
    [ "$CONFIGURE_LETSENCRYPT" == false ] && ask_assume_ssl
  fi

  # Let's Encrypt needs an email address to register the certificate
  if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
    email_input email "Provide the email address to configure Let's Encrypt: " "Email cannot be empty or invalid"
  fi

  # verify FQDN if user has selected to assume SSL or configure Let's Encrypt
  [ "$CONFIGURE_LETSENCRYPT" == true ] || [ "$ASSUME_SSL" == true ] && bash <(curl -s "$GITHUB_URL"/lib/verify-fqdn.sh) "$FQDN"

  # summary
  summary

  # confirm installation
  echo -e -n "\n* Initial configuration completed. Continue with installation? (y/N): "
  read -r CONFIRM
  if [[ "$CONFIRM" =~ [Yy] ]]; then
    run_installer "panel"
  else
    error "Installation aborted."
    exit 1
  fi
}

summary() {
  print_brake 62
  output "Pelican panel $PELICAN_PANEL_VERSION with nginx on $OS"
  if [ "$PANEL_SOURCE" == "custom" ]; then
    output "Panel source: $PANEL_REPO @ $PANEL_BRANCH (custom branch)"
  else
    output "Panel source: official release"
  fi
  output "Hostname/FQDN: $FQDN"
  output "Configure Firewall? $CONFIGURE_FIREWALL"
  output "Configure Let's Encrypt? $CONFIGURE_LETSENCRYPT"
  output "Assume SSL? $ASSUME_SSL"
  output ""
  output "Database, admin account and Eggs are configured afterwards"
  output "through the web installer at http://$FQDN/installer"
  print_brake 62
}

goodbye() {
  local scheme="http"
  { [ "$ASSUME_SSL" == true ] || [ "$CONFIGURE_LETSENCRYPT" == true ]; } && scheme="https"

  print_brake 62
  output "Panel installation completed"
  output ""

  output "To finish the setup, open the web installer in your browser and"
  output "complete the database, admin account and Eggs configuration:"
  output ""
  output "    ${scheme}://${FQDN}/installer"
  output ""

  [ "$ASSUME_SSL" == true ] && [ "$CONFIGURE_LETSENCRYPT" == false ] && output "You have opted in to use SSL, but not via Let's Encrypt automatically. Your panel will not work until SSL has been configured."

  output "Installation is using nginx on $OS"
  output "Thank you for using this script."
  [ "$CONFIGURE_FIREWALL" == false ] && echo -e "* ${COLOR_RED}Note${COLOR_NC}: If you haven't configured the firewall: 80/443 (HTTP/HTTPS) is required to be open!"
  print_brake 62
}

# run script
main
goodbye
