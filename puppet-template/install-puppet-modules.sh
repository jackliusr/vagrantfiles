#!/bin/bash 
mkdir -p /etc/puppet/modules;

# template to check if a module is installed, install module
if [ ! -d /etc/puppet/modules/elasticsearch ] ; then
  puppet module install elasticsearch-elasticsearch --version 0.4.0
fi 

