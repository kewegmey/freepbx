#!/usr/bin/bash
# Installs freepbx 13 on centos 7

# Array of dependencies
deps=(mariadb-server mariadb php php-mysql php-mbstring httpd ncurses-devel sendmail sendmail-cf sox newt-devel libxml2-devel libtiff-devel audiofile-devel gtk2-devel subversion kernel-devel git php-process crontabs cronie cronie-anacron wget vim php-xml uuid-devel sqlite-devel net-tools gnutls-devel php-pear unixODBC mysql-connector-odbc)


# Freepbx actually checks to see if selinux is enabled...working on a way to get it running w/o disabling'

# Pause for user to understand this will disable selinux and restart their machine.  
echo 'This script will now disable selinux and restart your machine.  Press any key to continue. Then rerun this script once your machine is back up. ctrl-c if you dont want that.'
read -n 1 -s


# If selinux is not disabled modify configs to disable then restart to take effect.  
# When the system reboots and the user runs this script again this will be skipped.  
# The freepbx install script checks selinux.
if [[ $( getenforce ) != "Disabled" ]]; then
  sed -i 's/\(^SELINUX=\).*/\SELINUX=disabled/' /etc/sysconfig/selinux
  sed -i 's/\(^SELINUX=\).*/\SELINUX=disabled/' /etc/selinux/config
  reboot
fi

# Update and get dev tools
yum -y update
yum -y groupinstall core base "Development Tools"

# Install other dependencies for asterisk and freepbx
# Loop through deps and install
for dep in "${deps[@]}"
do
  yum install -y $dep
done

# Legacy Pear Reqs (see http://wiki.freepbx.org/display/FOP/Installing+FreePBX+13+on+CentOS+7)
pear install Console_Getopt

# Start and enable database
systemctl enable mariadb.service
systemctl start mariadb

# Database basic setup
# The lazy route, I just call the mysql_secure_install and give it answers.
# A better way may be to run the equivalent mysql commands.
SECURE_MYSQL=$(expect -c "
set timeout 10
spawn mysql_secure_installation
expect \"Enter current password for root (enter for none):\"
send \"\r\"
expect \"Change the root password?\"
send \"n\r\"
expect \"Remove anonymous users?\"
send \"y\r\"
expect \"Disallow root login remotely?\"
send \"y\r\"
expect \"Remove test database and access to it?\"
send \"y\r\"
expect \"Reload privilege tables now?\"
send \"y\r\"
expect eof
")

echo "$SECURE_MYSQL"

# Fire up apache
systemctl enable httpd.service
systemctl start httpd.service

# Add asterisk user
adduser asterisk -M -c "Asterisk User"

# Download sources

# Download Asterisk sources
cd /usr/src
wget http://downloads.asterisk.org/pub/telephony/libpri/libpri-current.tar.gz
wget http://downloads.asterisk.org/pub/telephony/asterisk/asterisk-13-current.tar.gz
wget -O jansson.tar.gz https://github.com/akheron/jansson/archive/v2.7.tar.gz
wget http://www.pjsip.org/release/2.4/pjproject-2.4.tar.bz2


# Compile and install pjproject
# This is the 'new' sip library and is nicer for most uses than chan_sip
cd /usr/src
tar -xjvf pjproject-2.4.tar.bz2
rm -f pjproject-2.4.tar.bz2
cd pjproject-2.4
CFLAGS='-DPJ_HAS_IPV6=1' ./configure --prefix=/usr --enable-shared --disable-sound\
  --disable-resample --disable-video --disable-opencore-amr --libdir=/usr/lib64
make dep
make
make install

# Compile and Install jansson
# Json library for C 
cd /usr/src
tar vxfz jansson.tar.gz
rm -f jansson.tar.gz
cd jansson-*
autoreconf -i
./configure --libdir=/usr/lib64
make
make install 

# Compile and Install Asterisk
# Open Source Communications Software - the core of freepbx, does all the work
cd /usr/src
tar xvfz asterisk-13-current.tar.gz
rm -f asterisk-13-current.tar.gz
cd asterisk-*
contrib/scripts/install_prereq install
./configure --libdir=/usr/lib64
contrib/scripts/get_mp3_source.sh
# menuselect for user customization
make menuselect

make
make install
make config
ldconfig
# Make sure asterisk is down since we will be managing it later with freepbx
systemctl disable asterisk

# Soundfiles
# Prerecoreded voice files/sounds and g722 support for HD audio.
cd /var/lib/asterisk/sounds
wget http://downloads.asterisk.org/pub/telephony/sounds/asterisk-core-sounds-en-wav-current.tar.gz
wget http://downloads.asterisk.org/pub/telephony/sounds/asterisk-extra-sounds-en-wav-current.tar.gz
tar xvf asterisk-core-sounds-en-wav-current.tar.gz
rm -f asterisk-core-sounds-en-wav-current.tar.gz
tar xfz asterisk-extra-sounds-en-wav-current.tar.gz
rm -f asterisk-extra-sounds-en-wav-current.tar.gz
# Wideband Audio download
wget http://downloads.asterisk.org/pub/telephony/sounds/asterisk-core-sounds-en-g722-current.tar.gz
wget http://downloads.asterisk.org/pub/telephony/sounds/asterisk-extra-sounds-en-g722-current.tar.gz
tar xfz asterisk-extra-sounds-en-g722-current.tar.gz
rm -f asterisk-extra-sounds-en-g722-current.tar.gz
tar xfz asterisk-core-sounds-en-g722-current.tar.gz
rm -f asterisk-core-sounds-en-g722-current.tar.gz

# Permissions
# Make sure asterisk owns everyhting it needs to own.
chown asterisk. /var/run/asterisk
chown -R asterisk. /etc/asterisk
chown -R asterisk. /var/{lib,log,spool}/asterisk
chown -R asterisk. /usr/lib64/asterisk
chown -R asterisk. /var/www/

# Tweak apache configs
# Increase PHP upload size, run appache as the asterisk user, and change security setting. 
sed -i 's/\(^upload_max_filesize = \).*/\120M/' /etc/php.ini
sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/httpd/conf/httpd.conf
sed -i 's/AllowOverride None/AllowOverride All/' /etc/httpd/conf/httpd.conf
systemctl restart httpd.service

# Download and install freepbx
# Freepbx is really just a PHP app that runs a bunch of commands in asterisk.  
cd /usr/src
wget http://mirror.freepbx.org/modules/packages/freepbx/freepbx-13.0-latest.tgz
tar xfz freepbx-13.0-latest.tgz
rm -f freepbx-13.0-latest.tgz
cd freepbx
./start_asterisk start
./install -n

# Dat service
# create systemd unit that manages the whole system.  
echo "
[Unit]
Description=FreePBX VoIP Server
After=mariadb.service
 
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/fwconsole start
ExecStop=/usr/sbin/fwconsole stop
 
[Install]
WantedBy=multi-user.target" > /etc/systemd/system/freepbx.service

systemctl enable freepbx.service
systemctl start freepbx.service

echo "Freepbx install complete.  You may want to restart the asterisk core before trying to do anyhting.  OR just reboot your machine."  

# done
 
