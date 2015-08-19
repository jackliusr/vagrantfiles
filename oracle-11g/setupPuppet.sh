#!/usr/bin/env bash
echo 'starting provisioning'
rpm -ivh https://yum.puppetlabs.com/puppetlabs-release-el-6.noarch.rpm
yum install puppet -y
exit 0