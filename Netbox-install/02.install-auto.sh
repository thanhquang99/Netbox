#!/bin/bash
LOGFILE="log-install-netbox.txt"
exec > >(tee -i $LOGFILE)
exec 2>&1

USERFILE="user.txt"
# Prompt user to enter PostgreSQL username and password
read -p "Enter the PostgreSQL username: " POSTGRES_USERNAME
read -sp "Enter the PostgreSQL password: " POSTGRES_PASSWORD
echo ""
read -p "Enter the Netbox useradmin: " NETBOX_USERNAME
read -p "Enter the Netbox Mail: " NETBOX_MAIL
read -sp "Enter the Netbox useradmin password: " NETBOX_PASSWORD
echo ""

IP=$(hostname -I | awk '{print $1}')
read -p "Enter the Domain Netbox : " Domain_Netbox
echo ""
read -p "Use Let's Encrypt (certbot) for SSL? (y/n): " USE_CERTBOT
echo ""
ALLOWED_HOSTS="'$IP','$Domain_Netbox'"

# Write user details to file
echo "PostgreSQL Username: $POSTGRES_USERNAME" > $USERFILE
echo "PostgreSQL Password: $POSTGRES_PASSWORD" >> $USERFILE
echo "https://$Domain_Netbox" >> $USERFILE
echo "Netbox Admin Username: $NETBOX_USERNAME" >> $USERFILE
echo "Netbox Admin Mail: $NETBOX_MAIL" >> $USERFILE
echo "Netbox Admin Password: $NETBOX_PASSWORD" >> $USERFILE

# Function to install PostgreSQL
function install-sql {
    if ! dpkg -l | grep -q "postgresql"; then
        echo "PostgreSQL is not installed. Installing PostgreSQL..."
        
        # Install PostgreSQL
        sudo apt update
        sudo apt install -y postgresql postgresql-contrib
        
        # Check installation status
        if dpkg -l | grep -q "postgresql"; then
            echo "PostgreSQL has been successfully installed."
        else
            echo "Error: Failed to install PostgreSQL."
            exit 1
        fi
    else
        echo "PostgreSQL is already installed."
    fi
}

# Function to create PostgreSQL user and database
function create-user-sql {
    # Create database, user, and grant permissions
    sudo -i -u postgres psql <<EOF
CREATE DATABASE netbox;
CREATE USER $POSTGRES_USERNAME WITH PASSWORD '$POSTGRES_PASSWORD';
ALTER DATABASE netbox OWNER TO $POSTGRES_USERNAME;
GRANT ALL PRIVILEGES ON DATABASE netbox TO $POSTGRES_USERNAME;
EOF
    # Check if the process was successful
    if [ $? -eq 0 ]; then
        echo "Database, user, and permissions have been successfully created."
    else
        echo "Error: Failed to create database, user, and permissions."
    fi
}

# Function to install Redis
function install-redis {
    if ! dpkg -l | grep -q "redis-server"; then
        echo "Redis is not installed. Installing Redis..."
        
        # Install Redis
        sudo apt install -y redis-server

        # Check installation status
        if dpkg -l | grep -q "redis-server"; then
            echo "Redis has been successfully installed."
        else
            echo "Error: Failed to install Redis."
            exit 1
        fi
    else
        echo "Redis is already installed."
    fi
}

# Function to configure UFW
function configure-ufw {
    sudo ufw allow 8000/tcp
    sudo ufw allow 8001/tcp
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
}

# Function to install Python
function install-python {
    sudo apt install -y python3 python3-pip python3-venv python3-dev build-essential libxml2-dev libxslt1-dev libffi-dev libpq-dev libssl-dev zlib1g-dev
}

# Function to download and install Netbox
function install-netbox {
    # Install wget if not installed
    sudo apt install -y wget

    # Check if /opt/netbox directory exists
    if [ ! -d "/opt/netbox" ]; then
        # Download and install Netbox
        sudo wget https://github.com/netbox-community/netbox/archive/refs/tags/$(curl -s https://api.github.com/repos/netbox-community/netbox/releases/latest | grep 'tag_name' | cut -d\" -f4).tar.gz -P /tmp
        sudo mkdir -p /opt/netbox
        sudo tar -xzf /tmp/$(curl -s https://api.github.com/repos/netbox-community/netbox/releases/latest | grep 'tag_name' | cut -d\" -f4).tar.gz -C /opt/netbox --strip-components=1

        sudo adduser --system --group netbox
        
        mkdir -p /opt/netbox/netbox/media/
        sudo chown --recursive netbox /opt/netbox/netbox/media/
        sudo chown --recursive netbox /opt/netbox/netbox/reports/
        sudo chown --recursive netbox /opt/netbox/netbox/scripts/

        # Check if the process was successful
        if [ $? -eq 0 ]; then
            echo "Netbox has been successfully installed."
        else
            echo "Error: Failed to install Netbox."
            exit 1
        fi
    else
        echo "Netbox is already installed."
    fi
}

# Function to configure Netbox
function configure-netbox {
    cd /opt/netbox/netbox/netbox
    cp configuration_example.py configuration.py
    # Generate secret key
    Secret_key=$(python3 /opt/netbox/netbox/generate_secret_key.py)
    CONF="/opt/netbox/netbox/netbox/configuration.py"

# Safety check
if [ ! -f "$CONF" ]; then
  echo "ERROR: configuration.py not found at $CONF" >&2
  exit 1
fi

# Generate API token pepper
API_PEPPER_RAW=$(python3 /opt/netbox/netbox/generate_secret_key.py)

# Convert to safe Python literal (JSON string)
PEPPER_LITERAL=$(python3 - <<EOF
import json
print(json.dumps("$API_PEPPER_RAW"))
EOF
)

# Remove single-line empty definition: API_TOKEN_PEPPERS = {}
sed -i "/^API_TOKEN_PEPPERS\s*=\s*{}$/d" "$CONF"

# Remove multi-line definition if exists
sed -i "/^API_TOKEN_PEPPERS\s*=\s*{/,/^}/d" "$CONF"

# Append correct definition
cat >> "$CONF" <<EOF

# Define cryptographic peppers for API tokens
API_TOKEN_PEPPERS = {
    1: $PEPPER_LITERAL,
}
EOF

    # Replace content in the configuration file
    sed -i "s/^ALLOWED_HOSTS = \[\]$/ALLOWED_HOSTS = [$ALLOWED_HOSTS]/g" configuration.py
    sed -i "s/'USER': ''/'USER': '$POSTGRES_USERNAME'/g" configuration.py
    sed -i "0,/'PASSWORD': ''/s/'PASSWORD': ''/'PASSWORD': '$POSTGRES_PASSWORD'/g" configuration.py
    sed -i "s/SECRET_KEY = ''/SECRET_KEY = '$Secret_key'/g" configuration.py
    sed -i "s/TIME_ZONE = 'UTC'/TIME_ZONE = 'Asia\/Ho_Chi_Minh'/g" configuration.py

    /opt/netbox/upgrade.sh
    source /opt/netbox/venv/bin/activate
    cd /opt/netbox/netbox
    # Create Superuser
    DJANGO_SUPERUSER_PASSWORD=$NETBOX_PASSWORD python3 /opt/netbox/netbox/manage.py createsuperuser --no-input --username $NETBOX_USERNAME --email $NETBOX_MAIL
    # Create a symbolic link for cron job
    ln -s /opt/netbox/contrib/netbox-housekeeping.sh /etc/cron.daily
    # Start Netbox Server
    #python3 manage.py runserver 0.0.0.0:8000 --insecure
    #deactivate
    # Create daemon for Netbox
    cp /opt/netbox/contrib/gunicorn.py /opt/netbox/gunicorn.py
    cp -v /opt/netbox/contrib/*.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl start netbox netbox-rq
    systemctl enable netbox netbox-rq
}

# Function to install Nginx (supports certbot if requested)
function install-nginx {
    # Install Nginx
    sudo apt install -y nginx
    cd ~

    # Ensure UFW allows HTTP/HTTPS (configure-ufw already called but ensure here)
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp

    if [[ "$USE_CERTBOT" =~ ^[Yy]$ && -n "$Domain_Netbox" ]]; then
        echo "Configuring Nginx for certbot (Let's Encrypt) for domain: $Domain_Netbox"

        # Create a basic HTTP serverblock so certbot can perform HTTP-01 challenge
        sudo tee /etc/nginx/sites-available/netbox.conf > /dev/null <<EOF
server {
    listen 80;
    server_name $Domain_Netbox;

    client_max_body_size 25m;

    location /static/ {
        alias /opt/netbox/netbox/static/;
    }

    location / {
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
}
EOF
        rm -f /etc/nginx/sites-enabled/default
        ln -sf /etc/nginx/sites-available/netbox.conf /etc/nginx/sites-enabled/netbox.conf
        sudo mkdir -p /var/www/html
        sudo chown -R www-data:www-data /var/www/html
        sudo systemctl restart nginx

        # Install certbot and nginx plugin
        sudo apt update
        sudo apt install -y certbot python3-certbot-nginx

        # Obtain/renew certificate and let certbot edit nginx conf and enable HTTPS + redirect
        if sudo certbot --nginx -d "$Domain_Netbox" --non-interactive --agree-tos -m "$NETBOX_MAIL" --redirect; then
            echo "Certbot obtained certificate and configured Nginx."
            sudo systemctl reload nginx
            cd ~
            return
        else
            echo "Certbot failed or domain not reachable for HTTP challenge. Falling back to self-signed certificate."
        fi
    else
        if [[ "$USE_CERTBOT" =~ ^[Yy]$ && -z "$Domain_Netbox" ]]; then
            echo "Let's Encrypt requested but no Domain_Netbox provided. Will use self-signed certificate."
        else
            echo "Using self-signed certificate for Nginx."
        fi
    fi

    # Self-signed certificate generation (fallback)
    openssl genrsa -out CA.key 2048
    openssl req -x509 -sha256 -new -nodes -days 3650 -key CA.key -out CA.pem -subj "/CN=Local CA"
    openssl genrsa -out localhost.key 2048
    openssl req -new -key localhost.key -out localhost.csr -subj "/CN=${Domain_Netbox:-localhost}"
    sudo tee localhost.ext > /dev/null <<EOF
authorityKeyIdentifier = keyid,issuer
basicConstraints = CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${Domain_Netbox:-localhost}
IP.1 = $IP
EOF
    openssl x509 -req -in localhost.csr -CA CA.pem -CAkey CA.key -CAcreateserial -days 365 -sha256 -extfile localhost.ext -out localhost.crt
    sudo mkdir -p /etc/nginx/ssl-certificate
    sudo mv localhost.crt localhost.key /etc/nginx/ssl-certificate

    # Edit Nginx main configuration file
    sudo sed -i '/http {/a \ \ server_names_hash_bucket_size 64;' /etc/nginx/nginx.conf

    # Create virtual host configuration file for Netbox (self-signed)
    sudo tee /etc/nginx/sites-available/netbox.conf > /dev/null <<EOF
server {
        listen 80;
        server_name $IP,$Domain_Netbox;
        return 301 https://\$host\$request_uri;
}   

server {
    listen 443 ssl;
    server_name $IP,$Domain_Netbox;

    client_max_body_size 25m;
    # SSL Configuration
    ssl_certificate     /etc/nginx/ssl-certificate/localhost.crt;
    ssl_certificate_key /etc/nginx/ssl-certificate/localhost.key;
    # Log
    access_log /var/log/nginx/netbox.access.log;
    error_log /var/log/nginx/netbox.error.log;
    
    location /static/ {
        alias /opt/netbox/netbox/static/;
    }

    location / {
        # Remove these lines if using uWSGI instead of Gunicorn
        proxy_pass http://127.0.0.1:8001;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    # Apply configuration
    rm -rf /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/netbox.conf /etc/nginx/sites-enabled/netbox.conf
    # Restart Nginx service to apply changes
    sudo systemctl start nginx
    sudo systemctl restart nginx
    sudo systemctl enable nginx
    cd ~
}


# Run the functions
install-sql
create-user-sql
install-redis
configure-ufw
install-python
install-netbox
configure-netbox
install-nginx