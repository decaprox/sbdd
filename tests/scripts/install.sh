#!/bin/bash
#
# LICENSE UPL 1.0
#
# Copyright (c) 1982-2018 Oracle and/or its affiliates. All rights reserved.
#
# Since: January, 2018
# Author: gerald.venzl@oracle.com
# Description: Updates Oracle Linux to the latest version
#
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS HEADER.
#

echo 'INSTALLER: Started up'

# get up to date
dnf upgrade -y

echo 'INSTALLER: System updated'

# install kernel headers
dnf install -y kernel-uek-devel-$(uname -r)

echo 'INSTALLER: Kernel headers installed'

# Modify grub to enable kgdb and setup the serial console for debugging
sudo sed -i \
     's/^GRUB_CMDLINE_LINUX=\"/&kgdboc=ttyS0,115200 earlyprintk=serial,ttyS0,115200 /' \
     /etc/default/grub
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
#sudo systemctl reboot

echo "INSTALLER: rebooting"

# fix locale warning
echo LANG=en_US.utf-8 >> /etc/environment
echo LC_ALL=en_US.utf-8 >> /etc/environment

echo 'INSTALLER: Locale set'
