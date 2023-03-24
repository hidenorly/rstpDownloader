#!/bin/bash

echo installing rtspDownload service to Ubuntu-like system.
echo Please note that sudo execution is required.

mkdir /opt/rtspdownloader
cp *.rb /opt/rtspdownloader
cp rtsp_downloader.service /etc/systemd/system

mkdir /var/opt/rtspdownloader
cp config.json /var/opt/rtspdownloader

systemctl enable rtsp_downloader

echo "To configure the config, do vim /var/opt/rtspdownloader/config.json"
echo "When configuration is changed, do sudo systemctl restart rtsp_downloader"
echo ""
echo "To uninstall the service, do sudo systemctl disable rtsp_downloader"
echo "Then you can do rm -rf /opt/rtspdownloader.rb, rm -rf /var/opt/rtspdownloader"
