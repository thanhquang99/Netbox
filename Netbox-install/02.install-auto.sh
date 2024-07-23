#!/bin/bash
# Prompt user to enter PostgreSQL username and password
read -p "Enter the PostgreSQL username: " POSTGRES_USERNAME
read -sp "Enter the PostgreSQL password: " POSTGRES_PASSWORD
read -p "Enter the Netbox useradmin: " NETBOX_USERNAME
read -p "Enter the Netbox Mail: " NETBOX_MAIL
read -sp "Enter the Netbox useradmin password: " NETBOX_PASSWORD
echo ""
# Prompt user to enter ALLOWED_HOSTS
read -p "Enter ALLOWED_HOSTS (comma separated, enclosed in single quotes, e.g., 'localhost', '127.0.0.1'): " ALLOWED_HOSTS
Nginx_HOSTS=$(echo "$ALLOWED_HOSTS" | sed "s/'//g")

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
        sudo wget https://github.com/netbox-community/netbox/archive/refs/tags/v3.7.8.tar.gz -P /tmp
        sudo tar -xzf /tmp/v3.7.8.tar.gz -C /opt
        sudo ln -s /opt/netbox-3.7.8/ /opt/netbox
        sudo adduser --system --group netbox
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
    # Generate secret key
    secret_key=$(python3 /opt/netbox/netbox/generate_secret_key.py)
	cd /opt/netbox/netbox/netbox
	cp configuration_example.py configuration.py
    # Replace content in the configuration file
	sed -i "s/^ALLOWED_HOSTS = \[\]$/ALLOWED_HOSTS = [$ALLOWED_HOSTS]/g" configuration.py
	sed -i "s/'USER': ''/'USER': '$POSTGRES_USERNAME'/g" configuration.py
	sed -i "0,/'PASSWORD': ''/s/'PASSWORD': ''/'PASSWORD': '$POSTGRES_PASSWORD'/g" configuration.py
	sed -i "s/SECRET_KEY = ''/SECRET_KEY = '\/$secret_key'/g" configuration.py
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

# Function to install Nginx
function install-nginx {
    # Install Nginx
    sudo apt install -y nginx
	cp /opt/netbox/contrib/nginx.conf /etc/nginx/sites-available/netbox.conf
    # Edit Nginx main configuration file
    sudo sed -i '/http {/a \ \ server_names_hash_bucket_size 64;' /etc/nginx/nginx.conf

    # Create virtual host configuration file for Netbox
    sudo tee /etc/nginx/sites-available/netbox.conf > /dev/null <<EOF
server {
    listen 80;
    server_name ${Nginx_HOSTS};
    access_log /var/log/nginx/netbox.access.log;
    error_log /var/log/nginx/netbox.error.log;

    client_max_body_size 25m;

    location /static/ {
        alias /opt/netbox/netbox/static/;
    }

    location / {
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_pass http://127.0.0.1:8001;
    }
}
EOF
	# Áp dụng cấu hình
	rm /etc/nginx/sites-enabled/default
	ln -s /etc/nginx/sites-available/netbox.conf /etc/nginx/sites-enabled/netbox.conf
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
