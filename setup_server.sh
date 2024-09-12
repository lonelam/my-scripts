#!/bin/bash

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please run 'sudo ./setup_server.sh'"
   exit 1
fi

# Update package lists
apt-get update

# Install required packages
apt-get install -y curl jq nginx certbot python3-certbot-nginx

# Install ZeroTier One if desired
read -p "Do you want to install and configure ZeroTier One? (y/n): " install_zerotier
if [[ "$install_zerotier" =~ ^[Yy]$ ]]; then
    read -p "Enter your ZeroTier Network ID: " zerotier_network_id
    curl -s https://install.zerotier.com | bash
    zerotier-cli join "$zerotier_network_id"
    echo "ZeroTier One installed and joined network $zerotier_network_id"
fi

# Update DNS records on Porkbun
read -p "Do you want to update DNS records on Porkbun? (y/n): " update_dns
if [[ "$update_dns" =~ ^[Yy]$ ]]; then
    read -p "Enter your Porkbun API key: " porkbun_api_key
    read -s -p "Enter your Porkbun API secret: " porkbun_api_secret
    echo

    # Ensure 'jq' is installed
    if ! command -v jq &> /dev/null; then
        echo "Installing jq for JSON parsing..."
        apt-get install -y jq
    fi

    # Domains to update
    domains=(
        "aiweb.laizn.com"
        "files.laizn.com"
        "laizn.com"
        "aiproxy.laizn.com"
        "nas.laizn.com"
        "aiweb-admin.laizn.com"
    )

    # Get the public IP address
    public_ip=$(curl -s https://api.ipify.org)
    echo "Detected public IP address: $public_ip"

    # Base domain
    base_domain="laizn.com"
    porkbun_api_base="https://porkbun.com/api/json/v3"

    # Functions for Porkbun API interaction
    get_dns_records() {
        local domain=$1
        curl -s -X POST "$porkbun_api_base/dns/retrieve/$domain" \
        -H 'Content-Type: application/json' \
        -d '{
            "apikey": "'"$porkbun_api_key"'",
            "secretapikey": "'"$porkbun_api_secret"'"
        }'
    }

    create_dns_record() {
        local domain=$1
        local type=$2
        local host=$3
        local content=$4
        local ttl=$5
        curl -s -X POST "$porkbun_api_base/dns/create/$domain" \
        -H 'Content-Type: application/json' \
        -d '{
            "apikey": "'"$porkbun_api_key"'",
            "secretapikey": "'"$porkbun_api_secret"'",
            "type": "'"$type"'",
            "name": "'"$host"'",
            "content": "'"$content"'",
            "ttl": "'"$ttl"'"
        }'
    }

    delete_dns_record() {
        local domain=$1
        local record_id=$2
        curl -s -X POST "$porkbun_api_base/dns/delete/$domain/$record_id" \
        -H 'Content-Type: application/json' \
        -d '{
            "apikey": "'"$porkbun_api_key"'",
            "secretapikey": "'"$porkbun_api_secret"'"
        }'
    }

    # Update DNS records for each domain
    for fqdn in "${domains[@]}"; do
        if [[ "$fqdn" == "$base_domain" ]]; then
            host="@"
        else
            host="${fqdn%.$base_domain}"
        fi

        echo "Processing domain: $fqdn (host: $host)"

        # Get existing DNS records
        dns_records=$(get_dns_records "$base_domain")

        # Delete existing A records for the host
        records=$(echo "$dns_records" | jq -r '.records[] | @base64')
        for record in $records; do
            _jq() {
                echo "$record" | base64 --decode | jq -r "$1"
            }
            record_id=$(_jq '.id')
            record_type=$(_jq '.type')
            record_name=$(_jq '.name')
            if [[ "$record_type" == "A" && "$record_name" == "$host" ]]; then
                echo "Found existing A record (ID: $record_id) for $fqdn. Deleting..."
                delete_dns_record "$base_domain" "$record_id"
            fi
        done

        # Create a new A record
        echo "Creating new A record for $fqdn pointing to $public_ip"
        create_dns_record "$base_domain" "A" "$host" "$public_ip" "300"
    done
fi

# Instructions for uploading SSH keys
echo "To upload your SSH keys to the server, run the following commands from your local machine:"
echo "scp ~/.ssh/id_rsa* user@your_server_ip:~/.ssh/"
echo "Then, on the server, run:"
echo "cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys"

# Create necessary directories
mkdir -p /www/aiweb
mkdir -p /www/private

# Copy Nginx configuration files
echo "Copying Nginx configuration files..."
cp ./nginx_configs/aiproxy.laizn.com.conf /etc/nginx/sites-available/aiproxy.laizn.com
cp ./nginx_configs/aiweb.laizn.com.conf /etc/nginx/sites-available/aiweb.laizn.com
cp ./nginx_configs/files.laizn.com.conf /etc/nginx/sites-available/files.laizn.com
cp ./nginx_configs/nas.laizn.com.conf /etc/nginx/sites-available/nas.laizn.com

# Ensure the .htpasswd file exists for nas.laizn.com
echo "Setting up basic authentication for nas.laizn.com..."
read -p "Enter username for nas.laizn.com: " nas_username
read -s -p "Enter password for nas.laizn.com: " nas_password
echo
# Create htpasswd file
echo "$nas_username:$(openssl passwd -apr1 $nas_password)" > /etc/nginx/.htpasswd

# Enable Nginx sites
ln -sf /etc/nginx/sites-available/aiproxy.laizn.com /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/aiweb.laizn.com /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/files.laizn.com /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/nas.laizn.com /etc/nginx/sites-enabled/

# Test Nginx configuration and reload
nginx -t && systemctl reload nginx

# Obtain SSL certificates with Certbot
echo "Obtaining SSL certificates with Certbot..."
certbot --nginx -d aiproxy.laizn.com --non-interactive --agree-tos -m laizenan@gmail.com --redirect
certbot --nginx -d aiweb.laizn.com --non-interactive --agree-tos -m laizenan@gmail.com --redirect
certbot --nginx -d files.laizn.com --non-interactive --agree-tos -m laizenan@gmail.com --redirect
certbot --nginx -d nas.laizn.com --non-interactive --agree-tos -m laizenan@gmail.com --redirect

echo "Setup complete!"
#!/bin/bash

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please run 'sudo ./setup_server.sh'"
   exit 1
fi

# Update package lists
apt-get update

# Install required packages
apt-get install -y curl jq nginx certbot python3-certbot-nginx

# Install ZeroTier One if desired
read -p "Do you want to install and configure ZeroTier One? (y/n): " install_zerotier
if [[ "$install_zerotier" =~ ^[Yy]$ ]]; then
    read -p "Enter your ZeroTier Network ID: " zerotier_network_id
    curl -s https://install.zerotier.com | bash
    zerotier-cli join "$zerotier_network_id"
    echo "ZeroTier One installed and joined network $zerotier_network_id"
fi

# Update DNS records on Porkbun
read -p "Do you want to update DNS records on Porkbun? (y/n): " update_dns
if [[ "$update_dns" =~ ^[Yy]$ ]]; then
    read -p "Enter your Porkbun API key: " porkbun_api_key
    read -s -p "Enter your Porkbun API secret: " porkbun_api_secret
    echo

    # Ensure 'jq' is installed
    if ! command -v jq &> /dev/null; then
        echo "Installing jq for JSON parsing..."
        apt-get install -y jq
    fi

    # Domains to update
    domains=(
        "aiweb.laizn.com"
        "files.laizn.com"
        "laizn.com"
        "aiproxy.laizn.com"
        "nas.laizn.com"
        "aiweb-admin.laizn.com"
    )

    # Get the public IP address
    public_ip=$(curl -s https://api.ipify.org)
    echo "Detected public IP address: $public_ip"

    # Base domain
    base_domain="laizn.com"
    porkbun_api_base="https://porkbun.com/api/json/v3"

    # Functions for Porkbun API interaction
    get_dns_records() {
        local domain=$1
        curl -s -X POST "$porkbun_api_base/dns/retrieve/$domain" \
        -H 'Content-Type: application/json' \
        -d '{
            "apikey": "'"$porkbun_api_key"'",
            "secretapikey": "'"$porkbun_api_secret"'"
        }'
    }

    create_dns_record() {
        local domain=$1
        local type=$2
        local host=$3
        local content=$4
        local ttl=$5
        curl -s -X POST "$porkbun_api_base/dns/create/$domain" \
        -H 'Content-Type: application/json' \
        -d '{
            "apikey": "'"$porkbun_api_key"'",
            "secretapikey": "'"$porkbun_api_secret"'",
            "type": "'"$type"'",
            "name": "'"$host"'",
            "content": "'"$content"'",
            "ttl": "'"$ttl"'"
        }'
    }

    delete_dns_record() {
        local domain=$1
        local record_id=$2
        curl -s -X POST "$porkbun_api_base/dns/delete/$domain/$record_id" \
        -H 'Content-Type: application/json' \
        -d '{
            "apikey": "'"$porkbun_api_key"'",
            "secretapikey": "'"$porkbun_api_secret"'"
        }'
    }

    # Update DNS records for each domain
    for fqdn in "${domains[@]}"; do
        if [[ "$fqdn" == "$base_domain" ]]; then
            host="@"
        else
            host="${fqdn%.$base_domain}"
        fi

        echo "Processing domain: $fqdn (host: $host)"

        # Get existing DNS records
        dns_records=$(get_dns_records "$base_domain")

        # Delete existing A records for the host
        records=$(echo "$dns_records" | jq -r '.records[] | @base64')
        for record in $records; do
            _jq() {
                echo "$record" | base64 --decode | jq -r "$1"
            }
            record_id=$(_jq '.id')
            record_type=$(_jq '.type')
            record_name=$(_jq '.name')
            if [[ "$record_type" == "A" && "$record_name" == "$host" ]]; then
                echo "Found existing A record (ID: $record_id) for $fqdn. Deleting..."
                delete_dns_record "$base_domain" "$record_id"
            fi
        done

        # Create a new A record
        echo "Creating new A record for $fqdn pointing to $public_ip"
        create_dns_record "$base_domain" "A" "$host" "$public_ip" "300"
    done
fi

# Instructions for uploading SSH keys
echo "To upload your SSH keys to the server, run the following commands from your local machine:"
echo "scp ~/.ssh/id_rsa* user@your_server_ip:~/.ssh/"
echo "Then, on the server, run:"
echo "cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys"

# Create necessary directories
mkdir -p /www/aiweb
mkdir -p /www/private

# Copy Nginx configuration files
echo "Copying Nginx configuration files..."
cp ./nginx_configs/aiproxy.laizn.com.conf /etc/nginx/sites-available/aiproxy.laizn.com
cp ./nginx_configs/aiweb.laizn.com.conf /etc/nginx/sites-available/aiweb.laizn.com
cp ./nginx_configs/files.laizn.com.conf /etc/nginx/sites-available/files.laizn.com
cp ./nginx_configs/nas.laizn.com.conf /etc/nginx/sites-available/nas.laizn.com

# Ensure the .htpasswd file exists for nas.laizn.com
echo "Setting up basic authentication for nas.laizn.com..."
read -p "Enter username for nas.laizn.com: " nas_username
read -s -p "Enter password for nas.laizn.com: " nas_password
echo
# Create htpasswd file
echo "$nas_username:$(openssl passwd -apr1 $nas_password)" > /etc/nginx/.htpasswd

# Enable Nginx sites
ln -sf /etc/nginx/sites-available/aiproxy.laizn.com /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/aiweb.laizn.com /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/files.laizn.com /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/nas.laizn.com /etc/nginx/sites-enabled/

# Test Nginx configuration and reload
nginx -t && systemctl reload nginx

# Obtain SSL certificates with Certbot
echo "Obtaining SSL certificates with Certbot..."
certbot --nginx -d aiproxy.laizn.com --non-interactive --agree-tos -m laizenan@gmail.com --redirect
certbot --nginx -d aiweb.laizn.com --non-interactive --agree-tos -m laizenan@gmail.com --redirect
certbot --nginx -d files.laizn.com --non-interactive --agree-tos -m laizenan@gmail.com --redirect
certbot --nginx -d nas.laizn.com --non-interactive --agree-tos -m laizenan@gmail.com --redirect

echo "Setup complete!"
