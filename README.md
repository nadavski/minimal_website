sudo install -d -m 0755 /opt/nocturne-atelier
sudo tar --no-same-owner -xzf /tmp/prod.tar.gz -C /opt/nocturne-atelier
cd /opt/nocturne-atelier
sudo chmod 0755 deploy.sh
sudo ./deploy.sh
