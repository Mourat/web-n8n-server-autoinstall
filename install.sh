#!/bin/bash

set -e

echo "Enter your main domain (e.g. tomated.app):"
read DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]' | tr -d '
')

# Check for non-ASCII characters
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
  echo "❌ Error: Non-ASCII domain detected. Please enter the domain in Punycode."
  exit 1
fi
N8N_DOMAIN="n8n.$DOMAIN"

if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | bash
fi

if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
  echo "Installing Docker Compose..."
  sudo curl -L "https://github.com/docker/compose/releases/download/v2.20.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
fi

mkdir -p nginx/conf.d nginx/certs n8n_data

echo "Generating docker-compose.yml..."
cat > docker-compose.yml <<EOF
version: '3.8'

services:
  mysql:
    image: mysql:8
    container_name: mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wpuser
      MYSQL_PASSWORD: wppassword
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - internal

  wordpress:
    image: wordpress:latest
    container_name: wordpress
    restart: always
    environment:
      WORDPRESS_DB_HOST: mysql:3306
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_USER: wpuser
      WORDPRESS_DB_PASSWORD: wppassword
    volumes:
      - wordpress_data:/var/www/html
    networks:
      - internal

  php:
    image: php:8.2-fpm
    container_name: php
    restart: always
    volumes:
      - wordpress_data:/var/www/html
    networks:
      - internal

  n8n:
    image: n8nio/n8n
    container_name: n8n
    restart: always
    environment:
      - DB_TYPE=sqlite
      - N8N_HOST=$N8N_DOMAIN
      - WEBHOOK_URL=https://$N8N_DOMAIN/
    ports:
      - "5678:5678"
    volumes:
      - ./n8n_data:/home/node/.n8n
    networks:
      - internal

  redis:
    image: redis:alpine
    container_name: redis
    restart: always
    networks:
      - internal

  nginx:
    image: nginx:latest
    container_name: nginx
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./nginx/certs:/etc/nginx/certs
      - ./nginx/www:/var/www/certbot
      - wordpress_data:/var/www/html
    depends_on:
      - wordpress
      - php
      - n8n
    networks:
      - internal
      - external

networks:
  internal:
  external:

volumes:
  mysql_data:
  wordpress_data:
EOF

echo "Generating nginx configuration files..."

# Temporary config for Certbot HTTP challenge
cat > nginx/conf.d/challenge-only.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN $N8N_DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 404;
    }
}
EOF

# Full config will be added after successful cert generation

echo "Starting nginx to obtain SSL certificates..."
docker compose up -d nginx

sleep 5

echo "Requesting SSL certificates from Let's Encrypt..."
docker run --rm \
  -v $(pwd)/nginx/certs:/etc/letsencrypt \
  -v $(pwd)/nginx/www:/var/www/certbot \
  certbot/certbot certonly \
  --webroot \
  --webroot-path=/var/www/certbot \
  --agree-tos \
  --no-eff-email \
  --email admin@$DOMAIN \
  -d $DOMAIN -d $N8N_DOMAIN

# Replace temporary config with full HTTPS-enabled config
echo "Creating full nginx configuration files..."
rm -f nginx/conf.d/challenge-only.conf

cat > nginx/conf.d/wordpress.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/certs/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/live/$DOMAIN/privkey.pem;

    root /var/www/html;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass php:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

cat > nginx/conf.d/n8n.conf <<EOF
server {
    listen 80;
    server_name $N8N_DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $N8N_DOMAIN;

    ssl_certificate /etc/nginx/certs/live/$N8N_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/live/$N8N_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://n8n:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

docker compose restart nginx

echo "Creating auto-renewal script ssl_renew.sh..."
cat > ssl_renew.sh <<RENEW
#!/bin/bash

set -a
source "\$(dirname "\$0")/.env"
set +a

DOMAIN="$DOMAIN"
N8N_DOMAIN="$N8N_DOMAIN"

BOT_TOKEN="\${TELEGRAM_BOT_TOKEN}"
CHAT_ID="\${TELEGRAM_CHAT_ID}"

OUTPUT=\$(docker run --rm \
  -v \$(pwd)/nginx/certs:/etc/letsencrypt \
  -v \$(pwd)/nginx/www:/var/www/certbot \
  certbot/certbot renew \
  --webroot --webroot-path=/var/www/certbot 2>&1)

if echo "\$OUTPUT" | grep -q "renewal failed"; then
  curl -s -X POST https://api.telegram.org/bot\$BOT_TOKEN/sendMessage \
    -d chat_id=\$CHAT_ID \
    -d text="❌ SSL certificate renewal failed for \$DOMAIN and \$N8N_DOMAIN.\n\n\$OUTPUT"
fi

docker compose exec nginx nginx -s reload
RENEW
chmod +x ssl_renew.sh

(crontab -l 2>/dev/null; echo "0 3 * * * $(pwd)/ssl_renew.sh >> /var/log/ssl_renew.log 2>&1") | crontab -

echo "Creating postcheck.sh for verification..."
cat > postcheck.sh <<POST
#!/bin/bash

set -e

N8N_DOMAIN="n8n.$DOMAIN"

echo "🔍 Checking running containers..."
docker compose ps | grep "Exit" && echo "❌ Some containers have exited unexpectedly." || echo "✅ All containers are running."

echo "🔍 Checking HTTP access..."
if curl -s --head http://$DOMAIN | head -n 1 | grep -q "200\|301"; then
  echo "✅ WordPress is reachable at http://$DOMAIN"
else
  echo "❌ WordPress is NOT reachable at http://$DOMAIN"
fi

if curl -s --head http://$N8N_DOMAIN | head -n 1 | grep -q "200\|301"; then
  echo "✅ n8n is reachable at http://$N8N_DOMAIN"
else
  echo "❌ n8n is NOT reachable at http://$N8N_DOMAIN"
fi

echo "🔍 Checking SSL certificates..."
echo | openssl s_client -connect $DOMAIN:443 -servername $DOMAIN 2>/dev/null | openssl x509 -noout -dates || echo "❌ SSL certificate check failed for $DOMAIN"
echo | openssl s_client -connect $N8N_DOMAIN:443 -servername $N8N_DOMAIN 2>/dev/null | openssl x509 -noout -dates || echo "❌ SSL certificate check failed for $N8N_DOMAIN"

echo "🔍 Checking MySQL connectivity..."
docker exec mysql mysql -uwpuser -pwppassword -e "SHOW DATABASES;" 2>/dev/null | grep -q wordpress && \
  echo "✅ MySQL is running and database 'wordpress' exists." || \
  echo "❌ MySQL check failed. Unable to connect or database missing."

echo "✅ Post-installation check complete."
POST
chmod +x postcheck.sh

./postcheck.sh

echo "Done! Your sites are available at:"
echo "  - https://$DOMAIN"
echo "  - https://$N8N_DOMAIN"
