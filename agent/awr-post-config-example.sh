#!/bin/bash
# Post-script hook for TLS certificate renewal on the Docker reverse proxy.
# Reads certificate metadata from the DC1_POST_SCRIPT_DATA environment variable
# (base64-encoded JSON), extracts the certificate and key file paths, then
# generates a new nginx configuration that:
#   - Redirects all HTTP (port 80) traffic to HTTPS
#   - Serves HTTPS (port 443) for docker.stroehmi.casa using the renewed TLS cert
# Finally, restarts the Docker container "proxy" to apply the new configuration.
DATA=$(echo $DC1_POST_SCRIPT_DATA | base64 -d)
echo $DATA >> /tmp/tlm.log
FOLDER=$(echo $DATA | jq -r .certfolder)
CERT="$FOLDER/$(echo $DATA | jq -r .files[0])"
KEY="$FOLDER/$(echo $DATA | jq -r .files[1])"
CONF="${1:-/usr/local/docker/server/data/nginx/nginx.conf}"

cat > "$CONF" <<EOF
events {
}

http {
        resolver 127.0.0.11 valid=30s ipv6=off;
        server {
                listen 80 default_server;
                listen [::]:80 default_server;
                server_name _;
                return 301 https://\$host\$request_uri;           
        }

        server {
                listen 443 ssl;
                listen [::]:443 ssl;
                server_name docker.stroehmi.casa;
                ssl_certificate $CERT;
                ssl_certificate_key $KEY;
                ssl_protocols TLSv1.2 TLSv1.3;
                ssl_prefer_server_ciphers on;
                root /www;
                index index.html;
                location / {
                        try_files \$uri \$uri/ =404;
                }
        }
}
EOF

docker restart proxy