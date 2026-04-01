# Stage 1: SSL Certificate Generation
FROM nginx:alpine AS ssl

# Install OpenSSL and generate self-signed SSL certificate
RUN apk add --no-cache openssl \
    && openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/cert.key \
    -out /etc/nginx/cert.crt \
    -subj "/C=TH/ST=Bangkok/L=Bangkok/O=IT/CN=www.cmu.ac.th"

# Stage 2: Composer Dependencies
FROM php:8.4-fpm-alpine3.20 AS composer

ARG WITH_POSTGRES=false

# Install build dependencies for PHP extensions
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
    libzip-dev \
    libpng-dev \
    ${WITH_POSTGRES:+postgresql-dev} \
    ; \
    # Install PHP extensions
    docker-php-ext-install -j$(nproc) \
    mysqli \
    pdo_mysql \
    ${WITH_POSTGRES:+pdo_pgsql} \
    zip \
    gd \
    ; \
    # Clean up build dependencies
    apk del .build-deps

# Install runtime dependencies for extensions
RUN apk add --no-cache \
    libpng \
    libzip \
    ${WITH_POSTGRES:+libpq postgresql-client}

# Install Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

WORKDIR /app

# Copy composer files and install PHP dependencies
COPY composer.json composer.lock ./
RUN composer install \
    --no-interaction \
    --no-plugins \
    --no-scripts \
    --prefer-dist \
    --no-dev \
    --optimize-autoloader \
    && composer clear-cache \
    && rm -rf /root/.composer

# Stage 3: Frontend Dependencies
FROM node:22-alpine AS frontend-deps

WORKDIR /app

# Copy package files and install dependencies
COPY package.json pnpm-lock.yaml ./
RUN npm install -g pnpm \
    && pnpm install --frozen-lockfile \
    && pnpm store prune

# Stage 4: Frontend Builder
FROM frontend-deps AS frontend-builder

WORKDIR /app

# Copy vendor directory for Ziggy support
COPY --from=composer /app/vendor ./vendor

# Copy source code and build frontend
COPY . .
ENV APP_NAME="OOU Navigation" \
    VITE_APP_NAME="OOU Navigation" \
    NODE_ENV=production

RUN pnpm run build:ssr \
    && pnpm prune --prod \
    && rm -rf /tmp/* ~/.npm

# Stage 5: PHP Application
FROM php:8.4-fpm-alpine3.20 AS php

ARG WITH_POSTGRES=false
ENV TZ=Asia/Bangkok

# Install runtime dependencies
RUN set -eux; \
    apk add --no-cache \
    nginx \
    supervisor \
    libzip \
    libpng \
    curl \
    ${WITH_POSTGRES:+libpq postgresql-client} \
    ; \
    # Clean up package cache
    rm -rf /var/cache/apk/* /tmp/*

# Copy PHP extensions and configuration from composer stage
COPY --from=composer /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=composer /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

# Create log directories
RUN mkdir -p \
    /var/log/nginx \
    /var/log/php-fpm \
    /var/log/supervisor \
    /var/log/cron \
    /var/log/laravel \
    && chown -R www-data:www-data /var/log/laravel

WORKDIR /var/www/html

# Copy built assets and SSL certificates first
COPY --from=composer /app/vendor ./vendor
COPY --from=frontend-builder /app/public/build ./public/build
COPY --from=ssl /etc/nginx/cert.* /etc/nginx/

# Copy application code (excluding node_modules and build artifacts)
COPY --chown=www-data:www-data . .

# Copy configuration files
COPY ./docker/nginx/default.conf /etc/nginx/http.d/
COPY ./docker/php/zz-docker.conf /usr/local/etc/php-fpm.d/zz-docker.conf
COPY ./docker/php/upload.ini /usr/local/etc/php/conf.d/upload.ini
COPY docker/app.ini /etc/supervisor.d/
COPY ./docker/start.sh /start.sh

# Set permissions and configure cron
RUN chmod +x /start.sh \
    && chown -R www-data:www-data storage bootstrap/cache \
    && echo "* * * * * php /var/www/html/artisan schedule:run >> /dev/null 2>&1" > /etc/crontabs/root \
    && rm -rf /tmp/* /var/cache/apk/* \
    && rm -rf tests/ \
    && rm -rf node_modules/ \
    && rm -rf .git/ \
    && rm -rf storage/logs/*.log

# Health check
HEALTHCHECK --start-period=60s --interval=30s --timeout=10s --retries=3 \
    CMD curl -k -f https://127.0.0.1/up || exit 1

CMD ["/start.sh"]
