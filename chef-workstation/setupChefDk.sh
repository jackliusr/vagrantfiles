#!/usr/bin/env bash
echo 'starting provisioning'
apt-get update
PKG_OK=$(dpkg-query -W --showformat='${Status}\n' chefdk|grep "install ok installed")
if [ "" == "$PKG_OK" ]; then
	dpkg -i /vagrant/chefdk_0.6.2-1_amd64.deb
else
	echo "chefdk was installed"
fi 


PKG_OK=$(dpkg-query -W --showformat='${Status}\n' vim|grep "install ok installed")
if [ "" == "$PKG_OK" ]; then
	apt-get install -y vim
else
	echo "vim was installed"
fi 
exit 0