#!/usr/bin/env bash
#
# One-file installer for Apache, MariaDB, PHP, phpMyAdmin,
# FreeRADIUS and daloRADIUS on Ubuntu.
#
# Usage:
#   chmod +x install.sh
#   sudo ./install.sh
#
# Designed for a clean Ubuntu server with internet access.
# Review before running on a production or existing server.

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/radius-stack-install.log"
DB_NAME="radius"
DB_USER="radius"
DB_PASS="$(openssl rand -hex 24 2>/dev/null || true)"
DALORADIUS_DIR="/var/www/daloradius"
FR_DIR="/etc/freeradius/3.0"

trap 'echo "Installation failed on line $LINENO. See '"$LOG_FILE"'.";
      exit 1' ERR

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this script as root: sudo bash install.sh"
    exit 1
fi

mkdir -p /var/log
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Starting RADIUS stack installation ==="
echo "This can take several minutes."

if [[ -z "$DB_PASS" ]]; then
    echo "Could not generate a database password."
    exit 1
fi

# Avoid accidentally overwriting an existing daloRADIUS installation.
if [[ -e "$DALORADIUS_DIR" ]]; then
    echo "A directory already exists at $DALORADIUS_DIR."
    echo "Back it up and remove/rename it before running this installer."
    exit 1
fi

# 1. Update package lists and enable Universe.
apt-get update
apt-get install -y software-properties-common ca-certificates curl git unzip openssl
add-apt-repository -y universe
apt-get update

# 2. Install web server, database, PHP and required extensions.
apt-get install -y \
    apache2 \
    mariadb-server \
    mariadb-client \
    php \
    libapache2-mod-php \
    php-cli \
    php-common \
    php-mysql \
    php-gd \
    php-curl \
    php-mbstring \
    php-xml \
    php-zip \
    php-ldap \
    php-intl \
    php-bcmath \
    php-gmp \
    php-pear \
    php-mail \
    php-mail-mime \
    php-net-smtp

# 3. Install phpMyAdmin from Ubuntu packages.
# MariaDB is MySQL-compatible and is used here as the database server.
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
apt-get install -y phpmyadmin

# 4. Install FreeRADIUS and its SQL driver.
apt-get install -y freeradius freeradius-mysql freeradius-utils

if [[ ! -d "$FR_DIR" ]]; then
    echo "Expected FreeRADIUS configuration directory not found: $FR_DIR"
    echo "This installer currently targets Ubuntu packages providing FreeRADIUS 3.x."
    exit 1
fi

# 5. Start MariaDB and create the RADIUS database/user.
systemctl enable --now mariadb

mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# 6. Download daloRADIUS source.
git clone --depth 1 https://github.com/lirantal/daloradius.git "$DALORADIUS_DIR"

# 7. Import the SQL schema files included in the daloRADIUS repository.
DB_DIR="$DALORADIUS_DIR/contrib/db"
for SQL_FILE in \
    "$DB_DIR/fr3-mariadb-freeradius.sql" \
    "$DB_DIR/mariadb-daloradius.sql" \
    "$DB_DIR/mariadb-daloradius-dictionaries.sql"
do
    if [[ ! -f "$SQL_FILE" ]]; then
        echo "Required SQL file not found: $SQL_FILE"
        echo "The upstream repository layout may have changed."
        exit 1
    fi
    mariadb "$DB_NAME" < "$SQL_FILE"
done

# Import optional SQL migration files, if the repository provides them.
if [[ -d "$DB_DIR/migrations" ]]; then
    while IFS= read -r -d '' SQL_FILE; do
        echo "Applying migration: $(basename "$SQL_FILE")"
        mariadb "$DB_NAME" < "$SQL_FILE"
    done < <(find "$DB_DIR/migrations" -maxdepth 1 -type f -name '*.sql' -print0 | sort -z)
fi

# 8. Configure FreeRADIUS SQL module.
SQL_CONF="$FR_DIR/mods-available/sql"
if [[ ! -f "$SQL_CONF" ]]; then
    echo "FreeRADIUS SQL module configuration not found: $SQL_CONF"
    exit 1
fi

# Update the standard FreeRADIUS 3 SQL module settings.
python3 - "$SQL_CONF" "$DB_USER" "$DB_PASS" "$DB_NAME" <<'PY'
import re, sys
path, user, password, database = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = f.read()

def set_value(text, key, value):
    # Match either commented or uncommented standard setting lines.
    pattern = rf'(?m)^[ \t]*#?[ \t]*{re.escape(key)}[ \t]*=.*$'
    replacement = f'\t{key} = "{value}"'
    new, count = re.subn(pattern, lambda _: replacement, text, count=1)
    if count == 0:
        raise SystemExit(f"Could not find the {key} setting in {path}")
    return new

for key, value in {
    "dialect": "mysql",
    "server": "localhost",
    "port": "3306",
    "login": user,
    "password": password,
    "radius_db": database,
}.items():
    data = set_value(data, key, value)

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY

ln -sfn "$FR_DIR/mods-available/sql" "$FR_DIR/mods-enabled/sql"

# Enable SQL-backed authorization/accounting in the default site.
# These are standard FreeRADIUS 3 site configuration directives.
for SITE in "$FR_DIR/sites-available/default" "$FR_DIR/sites-available/inner-tunnel"; do
    if [[ -f "$SITE" ]]; then
        # Uncomment the SQL references where present; leave other settings intact.
        sed -i -E 's/^[[:space:]]*#[[:space:]]*(sql)([[:space:]]*(\{|$))/        \1\2/' "$SITE"
    fi
done

# 9. Configure daloRADIUS application database settings.
CONFIG_DIR="$DALORADIUS_DIR/app/common/includes"
SAMPLE_CONFIG="$CONFIG_DIR/daloradius.conf.php.sample"
LIVE_CONFIG="$CONFIG_DIR/daloradius.conf.php"

if [[ ! -f "$SAMPLE_CONFIG" ]]; then
    echo "daloRADIUS sample configuration not found: $SAMPLE_CONFIG"
    echo "The upstream repository layout may have changed."
    exit 1
fi

cp "$SAMPLE_CONFIG" "$LIVE_CONFIG"

python3 - "$LIVE_CONFIG" "$DB_USER" "$DB_PASS" "$DB_NAME" <<'PY'
import re, sys
path, user, password, database = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = f.read()

settings = {
    "CONFIG_DB_ENGINE": "mysqli",
    "CONFIG_DB_HOST": "127.0.0.1",
    "CONFIG_DB_PORT": "3306",
    "CONFIG_DB_USER": user,
    "CONFIG_DB_PASS": password,
    "CONFIG_DB_NAME": database,
}

for key, value in settings.items():
    pattern = rf"(?m)^(\s*\$configValues\['{re.escape(key)}'\]\s*=\s*)[^;]*;"
    data, count = re.subn(
        pattern,
        lambda m: m.group(1) + "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "';",
        data,
        count=1,
    )
    if count == 0:
        raise SystemExit(f"Could not find daloRADIUS setting {key} in {path}")

with open(path, "w", encoding="utf-8") as f:
    f.write(data)
PY

# 10. Set up application writable directories and Apache virtual hosts.
mkdir -p /var/log/apache2/daloradius/users /var/log/apache2/daloradius/operators
mkdir -p "$DALORADIUS_DIR/var/log" "$DALORADIUS_DIR/var/backup"
chown -R www-data:www-data "$DALORADIUS_DIR/var" /var/log/apache2/daloradius
chmod -R 750 "$DALORADIUS_DIR/var"
chown root:www-data "$LIVE_CONFIG"
chmod 640 "$LIVE_CONFIG"

# Separate user portal (port 80) and administrator portal (port 8000).
if ! grep -qE '^[[:space:]]*Listen[[:space:]]+8000([[:space:]]|$)' /etc/apache2/ports.conf; then
    echo 'Listen 8000' >> /etc/apache2/ports.conf
fi

cat > /etc/apache2/sites-available/daloradius-users.conf <<'APACHE'
<VirtualHost *:80>
    DocumentRoot /var/www/daloradius/app/users
    <Directory /var/www/daloradius/app/users>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    <Directory /var/www/daloradius>
        Require all denied
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/daloradius/users/error.log
    CustomLog ${APACHE_LOG_DIR}/daloradius/users/access.log combined
</VirtualHost>
APACHE

cat > /etc/apache2/sites-available/daloradius-operators.conf <<'APACHE'
<VirtualHost *:8000>
    DocumentRoot /var/www/daloradius/app/operators
    <Directory /var/www/daloradius/app/operators>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    <Directory /var/www/daloradius>
        Require all denied
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/daloradius/operators/error.log
    CustomLog ${APACHE_LOG_DIR}/daloradius/operators/access.log combined
</VirtualHost>
APACHE

a2enmod rewrite
a2enconf phpmyadmin
a2ensite daloradius-users.conf daloradius-operators.conf

# Save credentials securely for the server administrator.
cat > /root/radius-stack-credentials.txt <<EOF
Database: ${DB_NAME}
Database user: ${DB_USER}
Database password: ${DB_PASS}
EOF
chmod 600 /root/radius-stack-credentials.txt

# Validate configuration before restarting services.
freeradius -XC
apache2ctl configtest

systemctl enable apache2 mariadb freeradius
systemctl restart mariadb
systemctl restart freeradius
systemctl restart apache2

SERVER_IP="$(hostname -I | awk '{print $1}')"

echo
echo "=== Installation steps completed ==="
echo "Server IP: ${SERVER_IP:-SERVER-IP}"
echo "daloRADIUS user portal: http://${SERVER_IP:-SERVER-IP}/"
echo "daloRADIUS operator portal: http://${SERVER_IP:-SERVER-IP}:8000/"
echo "phpMyAdmin: http://${SERVER_IP:-SERVER-IP}/phpmyadmin"
echo "FreeRADIUS authentication: UDP 1812"
echo "FreeRADIUS accounting: UDP 1813"
echo
echo "Database credentials: /root/radius-stack-credentials.txt"
echo "Full installation log: ${LOG_FILE}"
echo
echo "IMPORTANT:"
echo "- Configure a firewall to allow only trusted access to ports 80 and 8000."
echo "- Allow UDP 1812 and 1813 only from authorized RADIUS clients."
echo "- Change the daloRADIUS default administrator password immediately."
echo "- Secure phpMyAdmin and use HTTPS before exposing this server to the internet."
echo "- This installer expects a clean Ubuntu server and FreeRADIUS 3.x packages."
