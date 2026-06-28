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

RM_PANEL="${RM_PANEL:-true}"
RM_WINGS="${RM_WINGS:-true}"

# ---------- Uninstallation functions ---------- #

rm_panel_files() {
  output "Removing panel files..."
  rm -rf /var/www/pelican /usr/local/bin/composer
  [ "$OS" != "centos" ] && unlink /etc/nginx/sites-enabled/pelican.conf
  [ "$OS" != "centos" ] && rm -f /etc/nginx/sites-available/pelican.conf
  [ "$OS" != "centos" ] && ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  [ "$OS" == "centos" ] && rm -f /etc/nginx/conf.d/pelican.conf
  systemctl restart nginx
  success "Removed panel files."
}

rm_docker_containers() {
  output "Removing docker containers and images..."

  docker system prune -a -f

  success "Removed docker containers and images."
}

rm_wings_files() {
  output "Removing wings files..."

  # stop and remove wings service
  systemctl disable --now wings
  rm -rf /etc/systemd/system/wings.service

  rm -rf /etc/pelican /usr/local/bin/wings /var/lib/pelican
  success "Removed wings files."
}

rm_services() {
  output "Removing services..."
  systemctl disable --now pelican-queue
  rm -rf /etc/systemd/system/pelican-queue.service
  systemctl disable --now pteroq
  rm -rf /etc/systemd/system/pteroq.service
  case "$OS" in
  ubuntu | debian)
    systemctl disable --now redis-server
    ;;
  centos)
    systemctl disable --now redis
    systemctl disable --now php-fpm
    rm -rf /etc/php-fpm.d/www-pelican.conf
    ;;
  esac
  success "Removed services."
}

rm_cron() {
  output "Removing cron jobs..."
  crontab -l | grep -vF "* * * * * php /var/www/pelican/artisan schedule:run >> /dev/null 2>&1" | crontab -
  success "Removed cron jobs."
}

# Database details captured from the panel .env *before* any files are removed
# (rm_panel_files deletes /var/www/pelican, including the .env and any in-tree
# SQLite file, so we must read it up-front).
DB_CONNECTION=""
DB_DATABASE_VALUE=""

# Read a single KEY=value from an env file, trimming whitespace and quotes.
read_env_value() {
  local key="$1" file="$2" line value
  line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 || true)
  value="${line#*=}"
  # strip surrounding whitespace
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  # strip a single pair of surrounding quotes
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s' "$value"
}

detect_database() {
  local env_file="/var/www/pelican/.env"
  if [ ! -f "$env_file" ]; then
    warning "Panel .env not found ($env_file); cannot determine the database type."
    return 0
  fi
  DB_CONNECTION=$(read_env_value "DB_CONNECTION" "$env_file")
  DB_DATABASE_VALUE=$(read_env_value "DB_DATABASE" "$env_file")
}

rm_database_sqlite() {
  output "Removing SQLite database..."

  local sqlite_file="$DB_DATABASE_VALUE"
  [ -z "$sqlite_file" ] && sqlite_file="/var/www/pelican/database/database.sqlite"

  if [ -f "$sqlite_file" ]; then
    rm -f "$sqlite_file"
    success "Removed SQLite database file ($sqlite_file)."
  else
    # In a default install the file lives under /var/www/pelican and is already
    # gone after rm_panel_files removed the directory tree.
    output "SQLite database file not found ($sqlite_file); removed together with the panel files."
  fi
}

rm_database_mysql() {
  if ! command -v mariadb >/dev/null 2>&1; then
    warning "mariadb client not found; skipping MySQL/MariaDB removal. Drop the database and user manually."
    return 0
  fi

  output "Removing database..."
  valid_db=$(mariadb -u root -e "SELECT schema_name FROM information_schema.schemata;" | grep -v -E -- 'schema_name|information_schema|performance_schema|mysql')
  warning "Be careful! This database will be deleted!"
  if [[ "$valid_db" == *"panel"* ]]; then
    echo -n "* Database called panel has been detected. Is it the Pelican database? (y/N): "
    read -r is_panel
    if [[ "$is_panel" =~ [Yy] ]]; then
      DATABASE=panel
    else
      print_list "$valid_db"
    fi
  else
    print_list "$valid_db"
  fi
  while [ -z "$DATABASE" ] || [[ $valid_db != *"$database_input"* ]]; do
    echo -n "* Choose the panel database (to skip don't input anything): "
    read -r database_input
    if [[ -n "$database_input" ]]; then
      DATABASE="$database_input"
    else
      break
    fi
  done
  [[ -n "$DATABASE" ]] && mariadb -u root -e "DROP DATABASE $DATABASE;"
  # Exclude usernames User and root (Hope no one uses username User)
  output "Removing database user..."
  valid_users=$(mariadb -u root -e "SELECT user FROM mysql.user;" | grep -v -E -- 'user|root')
  warning "Be careful! This user will be deleted!"
  if [[ "$valid_users" == *"pelican"* ]]; then
    echo -n "* User called pelican has been detected. Is it the pelican user? (y/N): "
    read -r is_user
    if [[ "$is_user" =~ [Yy] ]]; then
      DB_USER=pelican
    else
      print_list "$valid_users"
    fi
  else
    print_list "$valid_users"
  fi
  while [ -z "$DB_USER" ] || [[ $valid_users != *"$user_input"* ]]; do
    echo -n "* Choose the panel user (to skip don't input anything): "
    read -r user_input
    if [[ -n "$user_input" ]]; then
      DB_USER=$user_input
    else
      break
    fi
  done
  [[ -n "$DB_USER" ]] && mariadb -u root -e "DROP USER $DB_USER@'127.0.0.1';"
  mariadb -u root -e "FLUSH PRIVILEGES;"
  success "Removed database and database user."
}

rm_database_pgsql() {
  if ! command -v psql >/dev/null 2>&1; then
    warning "psql client not found; skipping PostgreSQL removal. Drop the database and user manually."
    return 0
  fi

  output "Removing PostgreSQL database..."
  warning "Be careful! The selected database and user will be deleted!"

  local default_db="$DB_DATABASE_VALUE"
  [ -z "$default_db" ] && default_db="panel"

  echo -n "* Panel database name to drop (default: $default_db, leave empty to skip): "
  read -r pg_db
  [ -z "$pg_db" ] && pg_db="$default_db"

  if [[ -n "$pg_db" ]]; then
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$pg_db\";" || warning "Failed to drop database $pg_db"
  fi

  echo -n "* Panel database user to drop (default: pelican, leave empty to skip): "
  read -r pg_user
  [ -z "$pg_user" ] && pg_user="pelican"

  if [[ -n "$pg_user" ]]; then
    sudo -u postgres psql -c "DROP ROLE IF EXISTS \"$pg_user\";" || warning "Failed to drop role $pg_user"
  fi

  success "Removed PostgreSQL database and user."
}

rm_database() {
  case "$DB_CONNECTION" in
  sqlite)
    rm_database_sqlite
    ;;
  mysql | mariadb)
    rm_database_mysql
    ;;
  pgsql)
    rm_database_pgsql
    ;;
  "")
    warning "Could not determine the database type (.env missing or unreadable)."
    warning "Skipping database removal. If you used MySQL/MariaDB/PostgreSQL, drop the database and user manually."
    ;;
  *)
    warning "Unknown DB_CONNECTION '$DB_CONNECTION'; skipping automatic database removal."
    ;;
  esac
}

# --------------- Main functions --------------- #

perform_uninstall() {
  # Read DB details from .env first; rm_panel_files removes /var/www/pelican
  # (including the .env and any in-tree SQLite database) before rm_database runs.
  [ "$RM_PANEL" == true ] && detect_database
  [ "$RM_PANEL" == true ] && rm_panel_files
  [ "$RM_PANEL" == true ] && rm_cron
  [ "$RM_PANEL" == true ] && rm_database
  [ "$RM_PANEL" == true ] && rm_services
  [ "$RM_WINGS" == true ] && rm_docker_containers
  [ "$RM_WINGS" == true ] && rm_wings_files

  return 0
}

# ------------------ Uninstall ----------------- #

perform_uninstall
