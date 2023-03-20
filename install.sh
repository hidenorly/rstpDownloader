#!/bin/bash

echo installing rstpDownload service to Ubuntu-like system.
echo Please note that sudo execution is required.

mkdir /opt/rstpdownloader
cp *.rb /opt/rstpdownloader
cp rstp_downloader.service /etc/systemd/system

mkdir /var/opt/rstpdownloader
cp config.json /var/opt/rstpdownloader

systemctl enable rstp_downloader

echo "To configure the config, do vim /var/opt/rstpdownloader/config.json"
echo "When configuration is changed, do sudo systemctl restart rstp_downloader"
echo ""
echo "To uninstall the service, do sudo systemctl disable rstp_downloader"
echo "Then you can do rm -rf /opt/rstpdownloader.rb, rm -rf /var/opt/rstpdownloader"
