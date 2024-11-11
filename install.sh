#!/bin/bash
# should be run as root and only on Ubuntu or Debian versions!
echo "Welcome to the MediacMS installation!";

if [ `id -u` -ne 0 ]
  then echo "Please run as root"
  exit
fi

while true; do
    read -p "
This script will attempt to perform a system update, install required dependencies, install and configure PostgreSQL, NGINX, Redis and a few other utilities.
It is expected to run on a new system **with no running instances of any these services**. Make sure you check the script before you continue. Then enter yes or no
" yn
    case $yn in
        [Yy]* ) echo "OK!"; break;;
        [Nn]* ) echo "Have a great day"; exit;;
        * ) echo "Please answer yes or no.";;
    esac
done

echo 'Performing system update and dependency installation, this will take a few minutes'
apt-get update && apt-get -y upgrade && apt-get install python3.12-venv python3.12-dev virtualenv redis-server postgresql nginx git gcc vim unzip imagemagick python3-certbot-nginx certbot wget xz-utils -y

# Install ffmpeg
echo "Installing ffmpeg"
apt-get install ffmpeg -y

read -p "Enter portal URL, or press enter for localhost : " FRONTEND_HOST
read -p "Enter portal name, or press enter for 'MediaCMS : " PORTAL_NAME

[ -z "$PORTAL_NAME" ] && PORTAL_NAME='MediaCMS'
[ -z "$FRONTEND_HOST" ] && FRONTEND_HOST='localhost'

echo 'Creating database to be used in MediaCMS'

su -c "psql -c \"CREATE DATABASE mediacms\"" postgres
su -c "psql -c \"CREATE USER mediacms WITH ENCRYPTED PASSWORD 'mediacms'\"" postgres
su -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE mediacms TO mediacms\"" postgres

echo 'Creating python virtualenv on /home/mediacms.io'

cd /home/mediacms.io
virtualenv . --python=python3
source /home/mediacms.io/bin/activate
cd mediacms
pip install -r requirements.txt

SECRET_KEY=`python -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())'`

# Remove http or https prefix
FRONTEND_HOST=`echo "$FRONTEND_HOST" | sed -r 's/http:\/\///g'`
FRONTEND_HOST=`echo "$FRONTEND_HOST" | sed -r 's/https:\/\///g'`

sed -i s/localhost/$FRONTEND_HOST/g deploy/local_install/mediacms.io

FRONTEND_HOST_HTTP_PREFIX='http://'$FRONTEND_HOST

echo 'FRONTEND_HOST='\'"$FRONTEND_HOST_HTTP_PREFIX"\' >> cms/local_settings.py
echo 'PORTAL_NAME='\'"$PORTAL_NAME"\' >> cms/local_settings.py
echo "SSL_FRONTEND_HOST = FRONTEND_HOST.replace('http', 'https')" >> cms/local_settings.py

echo 'SECRET_KEY='\'"$SECRET_KEY"\' >> cms/local_settings.py
echo "LOCAL_INSTALL = True" >> cms/local_settings.py

mkdir logs
mkdir pids
python manage.py migrate
python manage.py loaddata fixtures/encoding_profiles.json
python manage.py loaddata fixtures/categories.json
python manage.py collectstatic --noinput

ADMIN_PASS=`python -c "import secrets;chars = 'abcdefghijklmnopqrstuvwxyz0123456789';print(''.join(secrets.choice(chars) for i in range(10)))"`
echo "from users.models import User; User.objects.create_superuser('admin', 'admin@example.com', '$ADMIN_PASS')" | python manage.py shell

echo "from django.contrib.sites.models import Site; Site.objects.update(name='$FRONTEND_HOST', domain='$FRONTEND_HOST')" | python manage.py shell

chown -R www-data. /home/mediacms.io/
cp deploy/local_install/celery_long.service /etc/systemd/system/celery_long.service && systemctl enable celery_long && systemctl start celery_long
cp deploy/local_install/celery_short.service /etc/systemd/system/celery_short.service && systemctl enable celery_short && systemctl start celery_short
cp deploy/local_install/celery_beat.service /etc/systemd/system/celery_beat.service && systemctl enable celery_beat && systemctl start celery_beat
cp deploy/local_install/mediacms.service /etc/systemd/system/mediacms.service && systemctl enable mediacms.service && systemctl start mediacms.service

mkdir -p /etc/letsencrypt/live/mediacms.io/
mkdir -p /etc/letsencrypt/live/$FRONTEND_HOST
mkdir -p /etc/nginx/sites-enabled
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/dhparams/
rm -rf /etc/nginx/conf.d/default.conf
rm -rf /etc/nginx/sites-enabled/default
cp deploy/local_install/mediacms.io_fullchain.pem /etc/letsencrypt/live/$FRONTEND_HOST/fullchain.pem
cp deploy/local_install/mediacms.io_privkey.pem /etc/letsencrypt/live/$FRONTEND_HOST/privkey.pem
cp deploy/local_install/dhparams.pem /etc/nginx/dhparams/dhparams.pem
cp deploy/local_install/mediacms.io /etc/nginx/sites-available/mediacms.io
ln -s /etc/nginx/sites-available/mediacms.io /etc/nginx/sites-enabled/mediacms.io
cp deploy/local_install/uwsgi_params /etc/nginx/sites-enabled/uwsgi_params
cp deploy/local_install/nginx.conf /etc/nginx/
systemctl stop nginx
systemctl start nginx

# Attempt to get a valid certificate for specified domain
if [ "$FRONTEND_HOST" != "localhost" ]; then
    echo 'Attempting to get a valid certificate for specified URL $FRONTEND_HOST'
    certbot --nginx -n --agree-tos --register-unsafely-without-email -d $FRONTEND_HOST
    systemctl restart nginx
else
    echo "Will not call certbot utility to update SSL certificate for URL 'localhost', using default SSL certificate"
fi

# Generate individual DH params
if [ "$FRONTEND_HOST" != "localhost" ]; then
    openssl dhparam -out /etc/nginx/dhparams/dhparams.pem 4096
    systemctl restart nginx
else
    echo "Will not generate new DH params for URL 'localhost', using default DH params"
fi

# Bento4 utility installation, for HLS
cd /home/mediacms.io/mediacms
wget http://zebulon.bok.net/Bento4/binaries/Bento4-SDK-1-6-0-637.x86_64-unknown-linux.zip
unzip Bento4-SDK-1-6-0-637.x86_64-unknown-linux.zip
mkdir /home/mediacms.io/mediacms/media_files/hls

# Set default owner
chown -R www-data. /home/mediacms.io/

echo 'MediaCMS installation completed, open browser on http://'"$FRONTEND_HOST"' and login with user admin and password '"$ADMIN_PASS"'
