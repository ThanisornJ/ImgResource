#!/bin/sh

# Exit on error
set -e

# Wait for database to be ready (if needed)
# sleep 5

# Clear old caches first
/usr/local/bin/php /var/www/html/artisan config:clear || true
/usr/local/bin/php /var/www/html/artisan route:clear || true
/usr/local/bin/php /var/www/html/artisan view:clear || true

# Run Laravel optimizations
/usr/local/bin/php /var/www/html/artisan config:cache
/usr/local/bin/php /var/www/html/artisan route:cache
/usr/local/bin/php /var/www/html/artisan view:cache

# Start Supervisor
/usr/bin/supervisord -n -c /etc/supervisord.conf
