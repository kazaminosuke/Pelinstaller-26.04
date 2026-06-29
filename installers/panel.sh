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
FQDN="${FQDN:-localhost}"

# Assume SSL, will fetch different config if true
ASSUME_SSL="${ASSUME_SSL:-false}"
CONFIGURE_LETSENCRYPT="${CONFIGURE_LETSENCRYPT:-false}"

# Firewall
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-false}"

# Email is only used to obtain a Let's Encrypt certificate
email="${email:-}"

if [[ "${CONFIGURE_LETSENCRYPT}" == true && -z "${email}" ]]; then
  error "Email is required to configure Let's Encrypt"
  exit 1
fi

# Panel source: "release" (official, default) or "custom" (GitHub repo + branch).
# Defaults preserve the existing official-release behaviour.
PANEL_SOURCE="${PANEL_SOURCE:-release}"
PANEL_REPO="${PANEL_REPO:-}"
PANEL_BRANCH="${PANEL_BRANCH:-}"

if [[ "${PANEL_SOURCE}" == "custom" && ( -z "${PANEL_REPO}" || -z "${PANEL_BRANCH}" ) ]]; then
  error "Custom panel source requires both a repository (owner/repo) and a branch"
  exit 1
fi

# Panel language written to APP_LOCALE in .env. Chosen interactively from the
# languages bundled with the downloaded source (see ask_language); defaults to
# "en" so the existing non-interactive behaviour is preserved.
APP_LOCALE="${APP_LOCALE:-en}"

# --------- Main installation functions -------- #

install_composer() {
  output "Installing composer.."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  success "Composer installed!"
}

ptdl_dl() {
  output "Downloading Pelican Panel files .. "
  mkdir -p /var/www/pelican/storage/framework/cache/data/{9c,9c/a8,8a,8a/69}
  cd /var/www/pelican || exit

  if [ "$PANEL_SOURCE" == "custom" ]; then
    output "Using custom source: $PANEL_REPO (branch: $PANEL_BRANCH)"
    curl -Lo panel.tar.gz "https://github.com/${PANEL_REPO}/archive/refs/heads/${PANEL_BRANCH}.tar.gz"
    # GitHub branch archives wrap everything in a {repo}-{branch}/ top-level
    # folder, so strip it to land the files directly in /var/www/pelican
    tar -xzf panel.tar.gz --strip-components=1
  else
    curl -Lo panel.tar.gz "$PANEL_DL_URL"
    tar -xzvf panel.tar.gz
  fi

  chmod -R 755 storage/* bootstrap/cache/

  cp .env.example .env

  success "Downloaded Pelican Panel files!"
}

install_composer_deps() {
  output "Installing composer dependencies.."
  [ "$OS" == "rocky" ] || [ "$OS" == "almalinux" ] && export PATH=/usr/local/bin:$PATH
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
  success "Installed composer dependencies!"
}

install_nodejs() {
  command -v node >/dev/null 2>&1 && return 0

  output "Installing Node.js (needed to build frontend assets).."
  case "$OS" in
  ubuntu | debian)
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    install_packages "nodejs"
    ;;
  rocky | almalinux)
    curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
    install_packages "nodejs"
    ;;
  esac
}

# Official releases ship the compiled frontend in public/build. Raw branch
# archives usually don't, so build the assets (vite) only when they're missing.
build_frontend() {
  cd /var/www/pelican || exit

  if [ -d public/build ] && [ -n "$(ls -A public/build 2>/dev/null)" ]; then
    output "Compiled frontend assets already present, skipping build."
    return 0
  fi

  output "Compiled frontend assets not found, building them (this can take a while).."

  install_nodejs

  # package.json exposes "build" (vite build) which outputs to public/build
  npm install
  npm run build

  success "Frontend assets built!"
}

# Ask which language the panel should use (APP_LOCALE). The list is built from
# the lang/ directory of the downloaded source so it tracks whatever languages
# the panel currently ships, with no list to maintain here.
ask_language() {
  cd /var/www/pelican || exit

  local langs=() d
  for d in lang/*/; do
    [ -d "$d" ] || continue
    d="${d#lang/}"
    langs+=("${d%/}")
  done

  # If enumeration fails for any reason, keep the default and continue.
  if [ "${#langs[@]}" -eq 0 ]; then
    warning "Could not enumerate languages from lang/; keeping default APP_LOCALE=$APP_LOCALE"
    return 0
  fi

  output "Available panel languages: ${langs[*]}"

  local choice=""
  while true; do
    echo -n "* Select panel language (APP_LOCALE) [default: en, press enter to skip]: "
    read -r choice || choice=""
    # Default / skip -> keep "en" (preserves existing behaviour)
    [ -z "$choice" ] && { APP_LOCALE="en"; break; }
    if array_contains_element "$choice" "${langs[@]}"; then
      APP_LOCALE="$choice"
      break
    fi
    error "Invalid language: $choice"
  done

  output "Panel language set to: $APP_LOCALE"
}

# Prepare the panel so the web installer can run
configure() {
  output "Preparing panel.."

  # Apply the chosen panel language to .env (replace existing key or append)
  if grep -qE '^APP_LOCALE=' .env; then
    sed -i "s|^APP_LOCALE=.*|APP_LOCALE=${APP_LOCALE}|" .env
  else
    echo "APP_LOCALE=${APP_LOCALE}" >>.env
  fi

  # This reproduces the non-interactive initialization that Pelican's
  # `php artisan p:environment:setup` (AppSettingsCommand) performs, but by
  # calling each sub-command directly so we never depend on that wrapper. That
  # command does exactly: copy .env (already handled in ptdl_dl), generate the
  # APP_KEY, create the storage symlink, and cache Filament components/icons.
  # Database setup, the admin account and Egg imports are intentionally left to
  # the web installer at http://<FQDN>/installer

  # Generate the application encryption key so the panel can boot (--force
  # answers the production confirmation prompt non-interactively)
  php artisan key:generate --force

  # Create the public/storage -> storage/app/public symlink
  php artisan storage:link --no-interaction

  # Cache Filament components & icons (admin UI performance)
  php artisan filament:optimize --no-interaction

  success "Panel prepared!"
}

# Set proper directory permissions for distro
set_folder_permissions() {
  # if os is ubuntu or debian, set permissions
  case "$OS" in
  ubuntu | debian)
    chown -R www-data:www-data ./
    ;;
  rocky | almalinux)
    chown -R nginx:nginx ./
    ;;
  esac
}

insert_cronjob() {
  output "Installing cronjob.. "

  local web_user
  case "$OS" in
  ubuntu | debian)
    web_user="www-data"
    ;;
  rocky | almalinux)
    web_user="nginx"
    ;;
  esac

  (crontab -u "$web_user" -l 2>/dev/null || true) | {
    cat
    echo "* * * * * php /var/www/pelican/artisan schedule:run >> /dev/null 2>&1"
  } | crontab -u "$web_user" -

  success "Cronjob installed!"
}

install_pelican_queue() {
  output "Installing pelican-queue service.."

  local web_user
  case "$OS" in
  ubuntu | debian)
    web_user="www-data"
    ;;
  rocky | almalinux)
    web_user="nginx"
    ;;
  esac

  php /var/www/pelican/artisan p:environment:queue-service --user="$web_user" --group="$web_user" --overwrite

  systemctl daemon-reload
  systemctl enable pelican-queue.service
  systemctl start pelican-queue

  success "Installed pelican-queue!"
}

# -------- OS specific install functions ------- #

enable_services() {
  case "$OS" in
  ubuntu | debian)
    systemctl enable redis-server
    systemctl start redis-server
    ;;
  rocky | almalinux)
    systemctl enable redis
    systemctl start redis
    ;;
  esac
  systemctl enable nginx
}

selinux_allow() {
  setsebool -P httpd_can_network_connect 1 || true # these commands can fail OK
  setsebool -P httpd_execmem 1 || true
  setsebool -P httpd_unified 1 || true
}

php_fpm_conf() {
  curl -o /etc/php-fpm.d/www-pelican.conf "$GITHUB_URL"/configs/www-pelican.conf

  systemctl enable php-fpm
  systemctl start php-fpm
}

ubuntu_dep() {
  # Install deps for adding repos
  install_packages "software-properties-common apt-transport-https ca-certificates gnupg lsb-release"

  # Add Ubuntu universe repo
  add-apt-repository universe -y

  # Add sury repo for PHP 8.5 (packages.sury.org supports Ubuntu 26.04 / resolute)
  curl -o /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
}

debian_dep() {
  # Install deps for adding repos
  install_packages "dirmngr ca-certificates apt-transport-https lsb-release"

  # Install PHP 8.5 using sury's repo
  curl -o /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
}

alma_rocky_dep() {
  # SELinux tools
  install_packages "policycoreutils selinux-policy selinux-policy-targeted \
    setroubleshoot-server setools setools-console mcstrans"

  # add remi repo (php8.5)
  install_packages "epel-release http://rpms.remirepo.net/enterprise/remi-release-$OS_VER_MAJOR.rpm"
  dnf module enable -y php:remi-8.5
}

dep_install() {
  output "Installing dependencies for $OS $OS_VER..."

  # Update repos before installing
  update_repos

  [ "$CONFIGURE_FIREWALL" == true ] && install_firewall && firewall_ports

  case "$OS" in
  ubuntu | debian)
    [ "$OS" == "ubuntu" ] && ubuntu_dep
    [ "$OS" == "debian" ] && debian_dep

    update_repos

    # Install dependencies
    install_packages "php8.5 php8.5-{cli,common,gd,intl,sqlite3,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
      nginx \
      redis-server \
      zip unzip tar \
      git cron"

    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"

    ;;
  rocky | almalinux)
    alma_rocky_dep

    # Install dependencies
    install_packages "php php-{common,fpm,cli,json,intl,mysqlnd,mcrypt,gd,mbstring,pdo,zip,bcmath,dom,opcache,posix} \
      nginx \
      redis \
      zip unzip tar \
      git cronie"

    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"

    # Allow nginx
    selinux_allow

    # Create config for php fpm
    php_fpm_conf
    ;;
  esac

  enable_services

  success "Dependencies installed!"
}

# --------------- Other functions -------------- #

firewall_ports() {
  output "Opening ports: 22 (SSH), 80 (HTTP) and 443 (HTTPS)"

  firewall_allow_ports "22 80 443"

  success "Firewall ports opened!"
}

letsencrypt() {
  FAILED=false

  output "Configuring Let's Encrypt..."

  # Obtain certificate
  certbot --nginx --redirect --no-eff-email --email "$email" -d "$FQDN" || FAILED=true

  # Check if it succeded
  if [ ! -d "/etc/letsencrypt/live/$FQDN/" ] || [ "$FAILED" == true ]; then
    warning "The process of obtaining a Let's Encrypt certificate failed!"
    echo -n "* Still assume SSL? (y/N): "
    read -r CONFIGURE_SSL

    if [[ "$CONFIGURE_SSL" =~ [Yy] ]]; then
      ASSUME_SSL=true
      CONFIGURE_LETSENCRYPT=false
      configure_nginx
    else
      ASSUME_SSL=false
      CONFIGURE_LETSENCRYPT=false
    fi
  else
    success "The process of obtaining a Let's Encrypt certificate succeeded!"
  fi
}

# ------ Webserver configuration functions ----- #

configure_nginx() {
  output "Configuring nginx .."

  if [ "$ASSUME_SSL" == true ] && [ "$CONFIGURE_LETSENCRYPT" == false ]; then
    DL_FILE="nginx_ssl.conf"
  else
    DL_FILE="nginx.conf"
  fi

  case "$OS" in
  ubuntu | debian)
    PHP_SOCKET="/run/php/php8.5-fpm.sock"
    CONFIG_PATH_AVAIL="/etc/nginx/sites-available"
    CONFIG_PATH_ENABL="/etc/nginx/sites-enabled"
    ;;
  rocky | almalinux)
    PHP_SOCKET="/var/run/php-fpm/pelican.sock"
    CONFIG_PATH_AVAIL="/etc/nginx/conf.d"
    CONFIG_PATH_ENABL="$CONFIG_PATH_AVAIL"
    ;;
  esac

  rm -rf "$CONFIG_PATH_ENABL"/default

  curl -o "$CONFIG_PATH_AVAIL"/pelican.conf "$GITHUB_URL"/configs/$DL_FILE

  sed -i -e "s@<domain>@${FQDN}@g" "$CONFIG_PATH_AVAIL"/pelican.conf

  sed -i -e "s@<php_socket>@${PHP_SOCKET}@g" "$CONFIG_PATH_AVAIL"/pelican.conf

  case "$OS" in
  ubuntu | debian)
    ln -sf "$CONFIG_PATH_AVAIL"/pelican.conf "$CONFIG_PATH_ENABL"/pelican.conf
    ;;
  esac

  if [ "$ASSUME_SSL" == false ] && [ "$CONFIGURE_LETSENCRYPT" == false ]; then
    systemctl restart nginx
  fi

  success "Nginx configured!"
}

# --------------- Main functions --------------- #

perform_install() {
  output "Starting installation.. this might take a while!"
  dep_install
  install_composer
  ptdl_dl
  ask_language
  install_composer_deps
  build_frontend
  configure
  insert_cronjob
  install_pelican_queue
  configure_nginx
  [ "$CONFIGURE_LETSENCRYPT" == true ] && letsencrypt
  set_folder_permissions

  local scheme="http"
  { [ "$ASSUME_SSL" == true ] || [ "$CONFIGURE_LETSENCRYPT" == true ]; } && scheme="https"
  success "Base installation complete!"
  output "Open ${scheme}://${FQDN}/installer in your browser to finish setup (database, admin account and Eggs)."
  return 0
}

# ------------------- Install ------------------ #

perform_install
